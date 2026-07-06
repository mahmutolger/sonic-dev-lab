# SONiC VLAN Implementation — Architecture & Workflow

## Overview

VLAN management in SONiC follows a **three-layer architecture**:

1. **Config DB (Redis)** — stores VLAN configuration
2. **vlanmgrd (cfgmgr)** — reads config, applies to Linux kernel, writes to App DB
3. **orchagent (SWSS)** — reads App DB, programs ASIC via SAI

## Workflow Diagram

```
                            CONFIG DB (Redis)
                    ┌─────────────────────────────┐
                    │  VLAN table                  │
                    │  VLAN_MEMBER table           │
                    │  (keys: Vlan100, Ethernet0)  │
                    └─────────────┬───────────────┘
                                  │ Redis notifications
                                  ▼
┌─────────────────────────────────────────────────────────────────┐
│                     vlanmgrd (cfgmgr)                            │
│                                                                 │
│  main()                                                         │
│    └─► VlanMgr(cfgDb, appDb, stateDb)                           │
│          └─► Linux: Create "Bridge" (802.1Q)                     │
│          └─► doTask(consumer) ── dispatches by table name ──┐    │
│                                                                │  │
│  ┌─────────────────────────────────────────────────────────────┘  │
│  │                                                                │
│  ├─► doVlanTask()          [VLAN table]                           │
│  │     ├─ addHostVlan()          → ip link add VlanX              │
│  │     ├─ setHostVlanAdminState() → ip link set VlanX up/down     │
│  │     ├─ setHostVlanMac()       → mac address change             │
│  │     ├─ removeHostVlan()       → ip link del VlanX              │
│  │     └─ → writes to APP_VLAN_TABLE + STATE_VLAN_TABLE           │
│  │                                                                │
│  ├─► doVlanMemberTask()    [VLAN_MEMBER table]                    │
│  │     ├─ addHostVlanMember()    → bridge vlan add + ip link set  │
│  │     ├─ removeHostVlanMember() → bridge vlan del + nomaster     │
│  │     └─ → writes to APP_VLAN_MEMBER_TABLE + STATE_VLAN_MEMBER   │
│  │                                                                │
│  ├─► doVlanPacPortTask()   [OPER_PORT table]                      │
│  │     └─ Port learn_mode propagation                             │
│  │                                                                │
│  ├─► doVlanPacFdbTask()    [OPER_FDB table]                       │
│  │     └─ Static MAC FDB entries                                  │
│  │                                                                │
│  └─► doVlanPacVlanMemberTask() [OPER_VLAN_MEMBER table]           │
│        └─ Dynamic VLAN member management                          │
│                                                                   │
└───────────────────────┬───────────────────────────────────────────┘
                        │
          ┌─────────────┴─────────────┐
          ▼                           ▼
    LINUX KERNEL                  APP DB (Redis)
    ┌─────────────────┐         ┌──────────────────────┐
    │ Bridge (802.1Q) │         │ VLAN_TABLE           │
    │ Vlan100  Vlan200│         │ VLAN_MEMBER_TABLE    │
    │ eth0  eth1  LAG │         └──────────┬───────────┘
    └─────────────────┘                    │ Redis notifications
                                           ▼
                          ┌────────────────────────────────┐
                          │      orchagent (SWSS)          │
                          │                                │
                          │  VxlanOrch / PortsOrch         │
                          │    └─► SAI API calls           │
                          │          └─► Program ASIC      │
                          │              (hardware VLAN)   │
                          └────────────────────────────────┘
```

## Redis Table Relationships

| Database | Table | Purpose |
|----------|-------|---------|
| CONFIG_DB | `VLAN` | VLAN configuration (admin_state, mtu, mac, members) |
| CONFIG_DB | `VLAN_MEMBER` | VLAN port membership (tagging_mode) |
| CONFIG_DB | `VLAN_INTERFACE` | VLAN L3 interface config |
| CONFIG_DB | `VLAN_SUB_INTERFACE` | VLAN sub-interface config |
| CONFIG_DB | `STP_VLAN` | STP per-VLAN configuration |
| APP_DB | `VLAN_TABLE` | VLAN info passed to orchagent |
| APP_DB | `VLAN_MEMBER_TABLE` | Member info passed to orchagent |
| APP_DB | `FDB_TABLE` | Static FDB entries |
| STATE_DB | `VLAN_TABLE` | VLAN state tracking |
| STATE_DB | `VLAN_MEMBER_TABLE` | Member state tracking |
| STATE_DB | `OPER_PORT` | Port operational state (monitored by vlanmgrd) |
| STATE_DB | `OPER_FDB` | FDB operational state |
| STATE_DB | `OPER_VLAN_MEMBER` | Dynamic VLAN member events |

## Source Files

| File | Role |
|------|------|
| `src/sonic-swss/cfgmgr/vlanmgrd.cpp` | Main entry point, event loop |
| `src/sonic-swss/cfgmgr/vlanmgr.h` | VlanMgr class declaration |
| `src/sonic-swss/cfgmgr/vlanmgr.cpp` | VlanMgr implementation (~1000 lines) |
| `src/sonic-swss-common/common/schema.h` | Redis table name constants |
| `src/sonic-swss/orchagent/portsorch.cpp` | ASIC-side VLAN member handling |
| `src/sonic-swss/orchagent/vxlanorch.cpp` | VXLAN tunnel VLAN handling |

## Function-by-Function Breakdown

### 1. `main()` — Entry Point (`vlanmgrd.cpp`)

```cpp
// Watches these CONFIG_DB tables:
cfg_vlan_tables = { "VLAN", "VLAN_MEMBER" }
// Watches these STATE_DB tables:
state_vlan_tables = { "OPER_PORT", "OPER_FDB", "OPER_VLAN_MEMBER" }
```

- Connects to CONFIG_DB, APPL_DB, STATE_DB (Redis)
- Initializes Warm Restart support
- Reads switch MAC from `DEVICE_METADATA` table (set by interfaces-config.service)
- Creates `VlanMgr` instance with the watched table lists
- Enters infinite `Select` event loop waiting for Redis key-space notifications

### 2. `VlanMgr::VlanMgr()` — Constructor

**Cold start:**
```bash
ip link del Bridge 2>/dev/null
ip link add Bridge up type bridge
ip link set Bridge mtu 9100
ip link set Bridge address <switch_mac>
bridge vlan del vid 1 dev Bridge self
ip link add dummy type dummy && ip link set dummy master Bridge && ip link set dummy up
ip link set Bridge down && ip link set Bridge up
ip link set Bridge type bridge vlan_filtering 1
ip link set Bridge type bridge no_linklocal_learn 1
```

- Creates Linux 802.1Q `Bridge` interface
- Sets MTU to 9100 (jumbo frames)
- Sets MAC to switch MAC address
- Removes default VLAN 1 from bridge
- Creates dummy interface enslaved to bridge (ensures bridge stays up)
- Enables VLAN filtering and disables link-local learning

**Warm restart:**
- Caches all existing VLAN and VLAN_MEMBER keys from Config DB
- Skips bridge creation if bridge already exists
- Sets warm start state to REPLAYED/RECONCILED when all keys are processed

### 3. `doTask(Consumer &consumer)` — Task Dispatcher

Routes incoming Redis notifications based on table name:

```
CFG_VLAN_TABLE_NAME        → doVlanTask()
CFG_VLAN_MEMBER_TABLE_NAME → doVlanMemberTask()
STATE_OPER_PORT_TABLE_NAME → doVlanPacPortTask()
STATE_OPER_FDB_TABLE_NAME  → doVlanPacFdbTask()
STATE_OPER_VLAN_MEMBER_TABLE_NAME → doVlanPacVlanMemberTask()
```

### 4. `doVlanTask()` — VLAN CRUD

Handles **SET** and **DEL** operations on `VLAN` config table.

**Key format**: `Vlan<id>` (e.g., `Vlan100`)

**SET flow:**
1. Validates key starts with "Vlan" prefix
2. Parses VLAN ID from key (`stoi(key.substr(4))`)
3. Checks if VLAN already exists in kernel (`isVlanStateOk` + `m_vlans`)
4. If new: calls `addHostVlan(vlan_id)` → creates Linux VlanX interface
5. Processes field attributes:
   - `admin_status` → `setHostVlanAdminState()` (ip link set VlanX up/down)
   - `mac` → `setHostVlanMac()` (MAC address change with bridge down/up)
   - `mtu` → stored but host setting is TODO
   - `members@` → `processUntaggedVlanMembers()` (bulk untagged member creation)
   - `host_ifname` → recorded for host interface name
6. Writes to `APP_VLAN_TABLE` (notifies orchagent)
7. Writes `state=ok` to `STATE_VLAN_TABLE`

**DEL flow:**
1. Calls `removeHostVlan(vlan_id)` → deletes Linux VlanX interface
2. Removes from `APP_VLAN_TABLE` and `STATE_VLAN_TABLE`

### 5. `doVlanMemberTask()` — VLAN Member CRUD

Handles **SET** and **DEL** on `VLAN_MEMBER` config table.

**Key format**: `Vlan<id>|<port>` (e.g., `Vlan100|Ethernet4`)

**SET flow:**
1. Parses key: extracts VLAN ID and port alias
2. Checks if already processed (`isVlanMemberStateOk`)
3. Checks port readiness via `isMemberStateOk()`:
   - For LAG ports: checks `STATE_LAG_TABLE`
   - For physical ports: checks `STATE_PORT_TABLE` with `state=ok`
4. Checks VLAN readiness via `isVlanStateOk()`
5. Validates `tagging_mode`: `untagged`, `tagged`, or `priority_tagged`
6. Calls `addHostVlanMember(vlan_id, port, tagging_mode)`
7. Writes to `APP_VLAN_MEMBER_TABLE`
8. Writes `state=ok` to `STATE_VLAN_MEMBER_TABLE`
9. Updates `m_PortVlanMember[port][vlan] = tagging_mode` cache

**DEL flow:**
1. Calls `removeHostVlanMember(vlan_id, port)`
2. Removes from `APP_VLAN_MEMBER_TABLE` and `STATE_VLAN_MEMBER_TABLE`
3. Clears from `m_PortVlanMember` cache

### 6. `addHostVlan(int vlan_id)` — Create Linux VLAN Interface

```bash
bridge vlan add vid <vlan_id> dev Bridge self &&
ip link add link Bridge up name Vlan<vlan_id> address <mac> type vlan id <vlan_id>
```
Also disables ARP eviction (prevents ARP cache clearing on carrier loss):
```bash
echo 0 > /proc/sys/net/ipv4/conf/Vlan<vlan_id>/arp_evict_nocarrier
```

### 7. `removeHostVlan(int vlan_id)` — Delete Linux VLAN Interface

```bash
ip link del Vlan<vlan_id> &&
bridge vlan del vid <vlan_id> dev Bridge self
```

### 8. `addHostVlanMember(int vlan_id, port, tagging_mode)` — Add Port to VLAN

```bash
ip link set <port> master Bridge &&
bridge vlan del vid 1 dev <port> &&
bridge vlan add vid <vlan_id> dev <port> [pvid untagged]
```

- Removes default VLAN 1 from port
- Adds port to specified VLAN
- For `untagged` or `priority_tagged` mode: adds `pvid untagged` flag
- Has retry logic for LAG race conditions (portchannel may be removed while being added)

### 9. `removeHostVlanMember(int vlan_id, port)` — Remove Port from VLAN

```bash
bridge vlan del vid <vlan_id> dev <port>
```
Then checks if port has any remaining VLANs — if no VLANs remain, detaches from bridge:
```bash
ip link set <port> nomaster
```
The check logic: runs `bridge vlan show dev <port>`, if output has no port reference, port is detached.

### 10. `setHostVlanAdminState(int vlan_id, status)` — VLAN Admin State

```bash
ip link set Vlan<vlan_id> <up|down>
```

### 11. `setHostVlanMac(int vlan_id, mac)` — VLAN MAC Change

1. `ip link set Bridge down` (bring down first)
2. `ip link set Vlan<vlan_id> address <mac>`
3. `ip link set Bridge address <mac>`
4. `ip link set Bridge up` (bring up to regenerate IPv6 link-local)

This ensures IPv6 link-local addresses are recalculated from the new MAC.

### 12. `setHostVlanMtu(int vlan_id, mtu)` — VLAN MTU Change

```bash
ip link set Vlan<vlan_id> mtu <mtu>
```
Returns false if kernel rejects (e.g., MTU larger than member ports).

### 13. `isMemberStateOk(alias)` — Port Readiness Check

- For LAG (`PortChannel*`): checks `STATE_LAG_TABLE` for entry
- For physical port: checks `STATE_PORT_TABLE` for entry with `state=ok`
- Returns false if port not ready → task is delayed (not erased, retried next cycle)

### 14. `isVlanStateOk(alias)` — VLAN State Check

- Checks `STATE_VLAN_TABLE` for existing VLAN entry
- Used during warm restart to skip already-created kernel VLAN interfaces

### 15. `isVlanMemberStateOk(key)` — Member State Check

- Checks `STATE_VLAN_MEMBER_TABLE` for existing member entry
- Used to skip already-processed member operations

### 16. `isVlanMacOk()` — MAC Readiness Check

- Returns true if `gMacAddress` is set (non-zero)
- If switch MAC not yet read from DEVICE_METADATA, VLAN tasks are delayed

### 17. `processUntaggedVlanMembers(vlan, members)` — Bulk Member Processing

Parses comma-separated member list (from minigraph-style config like `"Ethernet1,Ethernet2,..."`), creates individual `SET` operations with `tagging_mode=untagged` for each port, and processes them through `doTask()`.

### 18. `doVlanPacPortTask()` — Port Learn Mode Propagation

Monitors `OPER_PORT` table changes:
- **SET**: Reads `learn_mode` field, propagates to `APP_PORT_TABLE` (for orchagent)
- **DEL**: Resets learn_mode to `"hardware"`

### 19. `doVlanPacFdbTask()` — Static FDB Management

Handles static MAC forwarding entries from `OPER_FDB` table.

**Key format**: `Vlan<id>|<MAC>` (e.g., `Vlan100|00-11-22-33-44-55`)

- **SET**: Reads `port`, `discard`, `type` fields → writes to `APP_FDB_TABLE`
- **DEL**: Removes from `APP_FDB_TABLE`

### 20. `doVlanPacVlanMemberTask()` — Dynamic VLAN Membership

Handles `OPER_VLAN_MEMBER` table events:

- **SET**: 
  1. Removes existing VLAN members for the port (from `m_PortVlanMember` cache)
  2. Calls `addHostVlanMember()` with `untagged` mode
  3. Tags as `dynamic=yes` in `APP_VLAN_MEMBER_TABLE`
- **DEL**: 
  1. Calls `removeHostVlanMember()`
  2. Restores previous VLAN members from `m_PortVlanMember` cache via `addPortToVlan()`

### 21. `addPortToVlan(member, vlan, tagging_mode)` — Re-add Port to VLAN

Used during dynamic VLAN restoration. Calls `addHostVlanMember()`, writes to `APP_VLAN_MEMBER_TABLE` with `dynamic=no`, writes `state=ok` to `STATE_VLAN_MEMBER_TABLE`.

### 22. `removePortFromVlan(member, vlan)` — Remove Port from VLAN

Removes VLAN member from `APP_VLAN_MEMBER_TABLE` and `STATE_VLAN_MEMBER_TABLE`. Does NOT call kernel commands (caller handles removal).

---

## Key Design Patterns

### Producer-Consumer Model
`VlanMgr` extends `Orch` which provides a `Consumer` interface. Redis table changes arrive as `KeyOpFieldsValuesTuple` (key, operation, field-value pairs). Each operation is processed atomically and erased from the consumer queue.

### State Verification Before Action
Before acting on VLAN/VLAN_MEMBER changes, the daemon verifies:
- Switch MAC is known (`isVlanMacOk`)
- Port/LAG exists in STATE_DB (`isMemberStateOk`)
- VLAN exists in STATE_DB (`isVlanStateOk`)

If prerequisites aren't met, the task is **not erased** — it stays in the queue and gets retried on the next event loop iteration.

### Dual Write Pattern
Every configuration change is applied to **two places**:
1. **Linux kernel** via shell commands (for host networking)
2. **App DB** via Redis `ProducerStateTable` (for orchagent → ASIC programming)

This ensures the kernel forwarding path and the ASIC hardware path stay in sync.

### Warm Restart
During warm restart (SWSS docker restart without host reboot):
- Existing Config DB entries are cached in `m_vlanReplay` and `m_vlanMemberReplay`
- Already-existing kernel VLAN interfaces are detected and skipped
- Once all cached keys are processed, warm start state is set to REPLAYED/RECONCILED
- This prevents disruption to existing VLAN configurations during docker restart

---

## Orchagent Deep Dive: APPL_DB → ASIC (SAI)

This section covers how **PortsOrch** (inside orchagent, the SWSS container) picks up
VLAN configuration from APPL_DB and programs it into the ASIC via the SAI API.

### 1. APPL_DB Subscription & Notification Flow

**Orchagent registers interest in APPL_DB tables at startup** in `orchdaemon.cpp` (lines 226-243):

```cpp
// orchagent/orchdaemon.cpp:226-243
const int portsorch_base_pri = 40;

vector<table_name_with_pri_t> ports_tables = {
    { APP_PORT_TABLE_NAME,        portsorch_base_pri + 5 },
    { APP_VLAN_TABLE_NAME,        portsorch_base_pri + 2 },   // priority 42
    { APP_VLAN_MEMBER_TABLE_NAME, portsorch_base_pri     },   // priority 40
    { APP_LAG_TABLE_NAME,         portsorch_base_pri + 4 },
    { APP_LAG_MEMBER_TABLE_NAME,  portsorch_base_pri     }
};

gPortsOrch = new PortsOrch(m_applDb, m_stateDb, ports_tables, m_chassisAppDb);
```

**How it works under the hood:**

The `Orch` base class constructor (`orch.h:287`, `orch.cpp`) iterates over the
table-name list and creates one `Consumer` per table.  Each `Consumer` wraps a
`swss::ConsumerTableBase` which uses Redis keyspace notifications to subscribe
to SET/DEL operations on a hash in APPL_DB.

**Notification → task dispatch chain:**

| Step | File:Line | What happens |
|------|-----------|--------------|
| Redis notification | — | APPL_DB key written → Redis pub/sub channel fires |
| `Consumer::execute()` | `orch.cpp:561` | Pops entries from `ConsumerTableBase`, calls `addToSync()` to queue them in `m_toSync`, then calls `drain()` |
| `Consumer::drain()` | `orch.cpp:614` | If `m_toSync` is non-empty, calls `m_orch->doTask((Consumer&)*this)` |
| `PortsOrch::doTask()` | `portsorch.cpp:6606` | Priority-ordered draining loop; iterates tables in order: PORT → LAG → LAG_MEMBER → VLAN → VLAN_MEMBER |
| `PortsOrch::doTask(Consumer&)` | `portsorch.cpp:6634` | Per-table dispatcher — checks `consumer.getTableName()` and routes to the matching handler |

**Key implementation detail:** `doTask()` (no-arg) ensures table ordering so VLAN
is always processed after LAG_MEMBER.  `doTask(Consumer&)` (with arg) guards VLAN
processing behind `allPortsReady()` — it will **not** process VLAN tasks until all
physical ports are initialized (`portsorch.cpp:6655-6659`).

### 2. VLAN Dispatch — Identifying VLAN-Related APPL_DB Updates

The routing logic is a straightforward if/else chain in
`PortsOrch::doTask(Consumer&)` (`portsorch.cpp:6634-6678`):

```cpp
// portsorch.cpp:6661-6667
if (table_name == APP_VLAN_TABLE_NAME)
{
    doVlanTask(consumer);
}
else if (table_name == APP_VLAN_MEMBER_TABLE_NAME)
{
    doVlanMemberTask(consumer);
}
```

There is **no separate VlanOrch class** — VLAN handling lives inside `PortsOrch`,
which inherits from both `Orch` (`orch.h:287`) and `Subject` (observer pattern).
`PortsOrch` is declared in `portsorch.h:151`:

```cpp
class PortsOrch : public Orch, public Subject
```

### 3. Full Processing Pipeline

#### 3a. doVlanTask — VLAN creation/deletion (`portsorch.cpp:5853-5976`)

**Parsing & Validation:**

1. Iterates `consumer.m_toSync` entries — these are pending SET/DEL tuples from APPL_DB.
2. Extracts the key (e.g. `"Vlan100"`), validates it begins with `"Vlan"` (`VLAN_PREFIX`).
   Invalid keys are logged as ERROR and erased from the queue.  (`portsorch.cpp:5864-5870`)
3. Parses the numeric VLAN ID from the key: `vlan_id = stoi(key.substr(4))`.  (`portsorch.cpp:5872-5873`)
4. Reads operation type (`SET_COMMAND` or `DEL_COMMAND`).

**SET path:**

1. Extracts optional attributes: `mtu`, `mac`, `host_ifname` from the field-value pairs.  (`portsorch.cpp:5882-5899`)
2. If the VLAN doesn't exist in `m_portList`: calls **`addVlan(vlan_alias)`** to create it via SAI.  (`portsorch.cpp:5908`)
3. If MTU or MAC attributes were provided, updates the local `Port` structure and calls `gIntfsOrch->setRouterIntfsMtu()` / `setRouterIntfsMac()` if a router interface exists.  (`portsorch.cpp:5923-5940`)
4. If `host_ifname` is provided, calls **`createVlanHostIntf()`** to create a Linux host interface for the VLAN (e.g. for monitoring/netdev access).  (`portsorch.cpp:5941-5950`)
5. Erases the entry from `m_toSync` on success.  (`portsorch.cpp:5953`)

**DEL path:**

1. Looks up the VLAN in `m_portList`; if not found, warns and skips.  (`portsorch.cpp:5957-5963`)
2. Calls **`removeVlan(vlan)`** → on success, erases the entry; on failure, advances the iterator (retry later).  (`portsorch.cpp:5965-5968`)

#### 3b. doVlanMemberTask — VLAN member add/remove (`portsorch.cpp:5978-6100+`)

**Parsing & Validation:**

1. Extracts key (format: `"Vlan100:Ethernet0"`) — validates `"Vlan"` prefix and parses `vlan_id` + `port_alias`.  (`portsorch.cpp:5990-6014`)
2. Reads operation type.

**SET path:**

1. Validates `tagging_mode` is one of: `"untagged"`, `"tagged"`, `"priority_tagged"`.  (`portsorch.cpp:6050-6057`)
2. De-duplication: if the port is already a member of this VLAN, erases and continues.  (`portsorch.cpp:6059-6064`)
3. LAG deferral: if the port is still a LAG member, defers (retry later).  (`portsorch.cpp:6066-6073`)
4. Calls `addBridgePort(port)` to ensure the port has a bridge port object in SAI, then calls **`addVlanMember(vlan, port, tagging_mode)`**.  (`portsorch.cpp:6075`)

**DEL path:**

1. If the port is a member of the VLAN: calls **`removeVlanMember(vlan, port)`**, then if the bridge port refcount drops to 0, calls `removeBridgePort(port)`.  (`portsorch.cpp:6082-6090`)

#### 3c. addVlan — SAI VLAN creation (`portsorch.cpp:7547-7585`)

This is where the actual SAI call happens:

```cpp
// portsorch.cpp:7551-7558
sai_vlan_id_t vlan_id = (uint16_t)stoi(vlan_alias.substr(4));
sai_attribute_t attr;
attr.id = SAI_VLAN_ATTR_VLAN_ID;
attr.value.u16 = vlan_id;

sai_status_t status = sai_vlan_api->create_vlan(&vlan_oid, gSwitchId, 1, &attr);
```

On success, it creates a `Port` object (type `Port::VLAN`), stores the SAI OID
and VLAN ID, initialises flood control to `SAI_VLAN_FLOOD_CONTROL_TYPE_ALL`, and
updates the tracking maps (`m_portList`, `m_vlanPorts`, `saiOidToAlias`).
(`portsorch.cpp:7570-7582`)

#### 3d. removeVlan — SAI VLAN removal (`portsorch.cpp:7587-7659`)

**Guard checks before removing the SAI object:**

1. `vlan.m_fdb_count > 0` — refuse if FDB entries still reference this VLAN.  (`portsorch.cpp:7593`)
2. `m_port_ref_count[vlan.m_alias] > 0` — refuse if other objects still reference it.  (`portsorch.cpp:7599`)
3. `vlan.m_members.size() > 0` — refuse if members still exist (must remove members first).  (`portsorch.cpp:7608`)
4. `vlan.m_vnid != VNID_NONE` — refuse if a VXLAN VNI is mapped to this VLAN.  (`portsorch.cpp:7615`)
5. If a host interface exists, removes it via `removeVlanHostIntf()`.  (`portsorch.cpp:7623`)
6. If associated with STP, calls `gStpOrch->removeVlanFromStpInstance()`.  (`portsorch.cpp:7632`)

Then: `sai_vlan_api->remove_vlan(vlan.m_vlan_info.vlan_oid)` (`portsorch.cpp:7635`)
and cleans up all local tracking maps.

#### 3e. addVlanMember — SAI VLAN member creation (`portsorch.cpp:7677-7763`)

Builds a vector of SAI attributes and calls `sai_vlan_api->create_vlan_member()`:

| SAI Attribute | Value Source | Line |
|---|---|---|
| `SAI_VLAN_MEMBER_ATTR_VLAN_ID` | `vlan.m_vlan_info.vlan_oid` | 7697-7699 |
| `SAI_VLAN_MEMBER_ATTR_BRIDGE_PORT_ID` | `port.m_bridge_port_id` | 7701-7703 |
| `SAI_VLAN_MEMBER_ATTR_VLAN_TAGGING_MODE` | Mapped from string to `sai_vlan_tagging_mode_t` enum | 7706-7716 |
| `SAI_VLAN_MEMBER_ATTR_TUNNEL_TERM_BUM_TX_DROP` | Optional — set if EVPN ES is associated | 7719-7724 |

Post-creation:
- If untagged mode: calls `setPortPvid(port, vlan_id)` to set the port's default VLAN.  (`portsorch.cpp:7742-7749`)
- Updates `m_portVlanMember` map, `vlan.m_members` set, and `m_portList`.  (`portsorch.cpp:7752-7757`)
- Notifies observers: `notify(SUBJECT_TYPE_VLAN_MEMBER_CHANGE, ...)`.  (`portsorch.cpp:7759-7760`)

#### 3f. removeVlanMember — SAI VLAN member removal (`portsorch.cpp:8042-8097`)

1. Looks up the `vlan_member_id` from the local `m_portVlanMember` map (indexed by port alias + VLAN ID).  (`portsorch.cpp:8050-8057`)
2. Calls `sai_vlan_api->remove_vlan_member(vlan_member_id)`.  (`portsorch.cpp:8059`)
3. If the port was in untagged mode, restores the default PVID via `setPortPvid(port, DEFAULT_PORT_VLAN_ID)`.  (`portsorch.cpp:8079-8086`)
4. Updates local maps and notifies observers.  (`portsorch.cpp:8088-8094`)

### 4. Interactions with Other Orch Classes

| Interaction | Direction | Mechanism | File:Line |
|---|---|---|---|
| **PortsOrch → IntfsOrch** | PortsOrch calls `gIntfsOrch->setRouterIntfsMtu()` / `setRouterIntfsMac()` when VLAN MTU/MAC changes | Direct call (global pointer) | `portsorch.cpp:5929,5938` |
| **PortsOrch → StpOrch** | PortsOrch calls `gStpOrch->removeVlanFromStpInstance()` before deleting a VLAN | Direct call (global pointer) | `portsorch.cpp:7632` |
| **PortsOrch → FdbOrch** | Notifies `SUBJECT_TYPE_VLAN_MEMBER_CHANGE` when a port joins/leaves a VLAN | Observer pattern (Subject::notify) | `portsorch.cpp:7760,7919,8094` |
| **PortsOrch → MirrorOrch** | Same notification triggers mirror session cleanup if a mirror port is removed from a VLAN | Observer pattern | `mirrororch.cpp:197` |
| **EvpnMhOrch → PortsOrch** | EVPN MH orch is created early (`orchdaemon.cpp:255`) so its ES/DF state is available when PortsOrch processes VLAN members | Startup ordering | `orchdaemon.cpp:245-255` |

**Execution order dependency** (`orchdaemon.cpp:255` comment):
> "Create EvpnMhOrch early so its ES/DF state is available when PortsOrch processes bridge ports and VLAN members (fixes warm boot ordering)"

### 5. Consumer Execution Model Summary

```
APPL_DB key change
    │
    ▼
Redis keyspace notification (pub/sub)
    │
    ▼
ConsumerTableBase::pops()          ← Consumer::execute() [orch.cpp:561]
    │
    ▼
Consumer::addToSync()              ← queues entries in m_toSync [orch.h:184]
    │
    ▼
Consumer::drain()                  ← [orch.cpp:614]
    │
    ▼
Orch::doTask(Consumer&)            ← virtual dispatch
    │
    ▼
PortsOrch::doTask(Consumer&)       ← [portsorch.cpp:6634]
    │
    ├─ table == APP_VLAN_TABLE_NAME        → doVlanTask()    [line 6663]
    │                                          ├─ addVlan()          [line 5908]
    │                                          └─ removeVlan()       [line 5965]
    │
    └─ table == APP_VLAN_MEMBER_TABLE_NAME → doVlanMemberTask() [line 6667]
                                               ├─ addVlanMember()    [line 6075]
                                               └─ removeVlanMember() [line 6084]
```

### 6. Source File Reference (orchagent only)

| File | Relevant Contents |
|---|---|
| `orchagent/orchdaemon.cpp:226-243` | PortsOrch construction with VLAN table subscriptions |
| `orchagent/orch.h:106-270` | Executor, ConsumerBase, Consumer class definitions |
| `orchagent/orch.h:287-305` | Orch base class (owns consumers, getSelectables(), doTask) |
| `orchagent/orch.cpp:561-640` | Consumer::execute() + Consumer::drain() implementation |
| `orchagent/portsorch.h:151` | `class PortsOrch : public Orch, public Subject` |
| `orchagent/portsorch.h:457-462` | `addVlan()`, `removeVlan()` declarations |
| `orchagent/portsorch.h:270-274` | `addVlanMember()`, `removeVlanMember()` declarations |
| `orchagent/portsorch.h:107-111` | `VlanMemberUpdate` struct (used in observer notifications) |
| `orchagent/portsorch.cpp:6606-6632` | `doTask()` — priority-ordered table draining |
| `orchagent/portsorch.cpp:6634-6678` | `doTask(Consumer&)` — per-table dispatch |
| `orchagent/portsorch.cpp:5853-5976` | `doVlanTask()` — VLAN create/delete processing |
| `orchagent/portsorch.cpp:5978-6100+`| `doVlanMemberTask()` — VLAN member add/remove processing |
| `orchagent/portsorch.cpp:7547-7585` | `addVlan()` — SAI `create_vlan` |
| `orchagent/portsorch.cpp:7587-7659` | `removeVlan()` — SAI `remove_vlan` |
| `orchagent/portsorch.cpp:7677-7763` | `addVlanMember()` — SAI `create_vlan_member` |
| `orchagent/portsorch.cpp:8042-8097` | `removeVlanMember()` — SAI `remove_vlan_member` |
| `orchagent/portsorch.cpp:3911-3960+`| `createVlanHostIntf()` — SAI host interface for VLAN netdev |
| `orchagent/portsorch.cpp:4497-4501` | Warm-restart: adding existing VLAN data from APPL_DB |
| `orchagent/observer.h:15` | `SUBJECT_TYPE_VLAN_MEMBER_CHANGE` enum value |

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

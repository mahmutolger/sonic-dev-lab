# SONiC STP Implementation — Architecture & Workflow

## Overview

Spanning Tree Protocol (STP) in SONiC runs in its own **`stp` Docker container** (`docker-stp`),
separate from both `swss` (orchagent) and the Linux kernel's native bridge STP. This design
gives SONiC full control over the protocol engine and allows it to support three modes:

| Mode | IEEE Standard | SONiC Mode String | BPDU DMAC | SAI Hostif Trap |
|------|--------------|-------------------|-----------|-----------------|
| Classic STP | 802.1D | (legacy fallback within pvst) | `01:80:c2:00:00:00` | `SAI_HOSTIF_TRAP_TYPE_STP` |
| Rapid STP (RSTP) | 802.1w | Embedded in MSTP engine | `01:80:c2:00:00:00` | `SAI_HOSTIF_TRAP_TYPE_STP` |
| Per-VLAN STP (PVST+) | Cisco proprietary | `pvst` | `01:00:0c:cc:cc:cd` | `SAI_HOSTIF_TRAP_TYPE_PVRST` |
| Multiple STP (MSTP) | 802.1s | `mst` | `01:80:c2:00:00:00` | `SAI_HOSTIF_TRAP_TYPE_STP` |

**Key distinction**: Standard STP/RSTP/MSTP BPDUs use the IEEE STP multicast MAC
(`01:80:c2:00:00:00`) and are trapped via `SAI_HOSTIF_TRAP_TYPE_STP`. Cisco PVST+
BPDUs use a different multicast MAC (`01:00:0c:cc:cc:cd`) and require a **separate**
SAI hostif trap type: `SAI_HOSTIF_TRAP_TYPE_PVRST` (enum value `0x00000004`). Both
trap types must be configured by the SAI implementation during switch init for STP
to function correctly.

### Why a Separate Container?

- **Protocol isolation**: stpd processes raw BPDUs via `PF_PACKET` sockets — it needs
  `NET_ADMIN` and `SYS_ADMIN` capabilities, which are scoped to the `stp` container
- **Independent lifecycle**: stpd can be restarted without affecting `swss` (orchagent)
  or `syncd` (SAI programming)
- **Warm restart coordination**: `docker-stp` is ordered to shut down **before** `swss`
  (`_WARM_SHUTDOWN_BEFORE = swss`), so STP state is cleanly removed before the ASIC
  forwarding pipeline restarts
- **C/C++ hybrid**: The core protocol engine is pure C (for IEEE compliance and
  performance), while the Redis DB sync layer (`stpsync/`) and the config manager
  (`stpmgrd`) are C++

### Container Layout

```
┌─────────────────────────────────────────────────────────────────┐
│                   docker-stp                                     │
│                                                                 │
│  ┌──────────┐   IPC (AF_UNIX)   ┌───────────────────────────┐  │
│  │  stpmgrd │ ◄──────────────► │     stpd                  │  │
│  │  (C++)   │   /var/run/       │  (C + C++ main)          │  │
│  │          │   stpipc.sock     │                           │  │
│  │  Reads:  │                   │  ┌─────────┐              │  │
│  │  CONFIG   │                   │  │ stp/     │ PVST engine │  │
│  │  _DB     │                   │  │ (802.1D) │              │  │
│  │          │                   │  ├─────────┤              │  │
│  │  Writes: │                   │  │ mstp/    │ MSTP engine │  │
│  │  (none)  │                   │  │ (802.1s) │              │  │
│  └──────────┘                   │  ├─────────┤              │  │
│                                 │  │ stpsync/ │ Redis bridge│──┼──► APPL_DB
│  ┌──────────┐                   │  │ (C++)    │              │  │    (all STP
│  │  stpctl  │── IPC ───────────►│  └─────────┘              │  │     state
│  │  (debug) │   stpipc.sock     │                           │  │     tables)
│  └──────────┘                   │  Kernel enforcement:      │  │
│                                 │  /sbin/bridge vlan add/del│──┼──► Linux
│                                 └───────────────────────────┘  │    Bridge
│                                                                 │
│  BPDU path (RX):                                                │
│  ASIC ──► CPU ──► PF_PACKET socket [+BPF filter] ──► stpd     │
│    ↑ SAI_HOSTIF_TRAP_TYPE_STP (01:80:c2:00:00:00)               │
│    ↑ SAI_HOSTIF_TRAP_TYPE_PVRST (01:00:0c:cc:cc:cd)             │
│                                                                 │
│  BPDU path (TX):                                                │
│  stpd ──► PF_PACKET socket (shared TX) ──► kernel ──► ASIC ──► wire │
└─────────────────────────────────────────────────────────────────┘
```

## Four-Component Interaction Map

The STP pipeline has four components spread across two containers. This section
shows all pairwise interactions in one consolidated view.

### Component Roles

| Component | Container | Language | Role |
|-----------|-----------|----------|------|
| **stpmgrd** | docker-stp | C++ | CONFIG_DB → IPC bridge. Reads config, sends IPC to stpd. Never writes to APPL_DB. |
| **stpd** | docker-stp | C (engine) + C++ (main) | Protocol engine. BPDU processing, STP/RSTP/MSTP state machines. Decides topology. |
| **stpsync** | docker-stp (inside stpd process) | C++ | stpd → Redis bridge. Writes ALL STP state tables to APPL_DB. Also does kernel bridge enforcement via `/sbin/bridge vlan add/del`. |
| **StpOrch** | docker-swss (inside orchagent) | C++ | APPL_DB → SAI bridge. Reads STP tables from APPL_DB, programs ASIC via SAI API. |

### Pairwise Interactions

```
                    ┌──────────────────────────────────────────────┐
                    │            CONFIG_DB (Redis)                  │
                    │  STP | STP_VLAN | STP_VLAN_PORT | STP_PORT   │
                    │  STP_MST | STP_MST_INST | STP_MST_PORT       │
                    └──────────┬───────────────────────────────────┘
                               │ Redis keyspace notification
                               │ (who decides: user/CLI writes config)
                               ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ stpmgrd                                                                    │
│   Data received: CONFIG_DB table/key/op/fields via Consumer               │
│   Decision logic: validates state prereqs, manages instance pool,          │
│                   parses VLAN lists, determines tagging mode               │
│   Data sent: STP_IPC_MSG over AF_UNIX datagram to /var/run/stpipc.sock   │
│   IPC message types: STP_BRIDGE_CONFIG, STP_VLAN_CONFIG,                  │
│     STP_VLAN_PORT_CONFIG, STP_PORT_CONFIG, STP_VLAN_MEM_CONFIG,           │
│     STP_MST_GLOBAL_CONFIG, STP_MST_INST_CONFIG, STP_MST_INST_PORT_CONFIG  │
└──────────────────────────┬───────────────────────────────────────────────┘
                           │ AF_UNIX (SOCK_DGRAM)
                           │ /var/run/stpipc.sock
                           │ (who decides: stpmgrd translates config,
                           │  stpd executes protocol)
                           ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ stpd (C protocol engine)                                                   │
│   Data received: IPC messages from stpmgrd, BPDU packets from PF_PACKET, │
│                  netlink events from kernel                                │
│   Decision logic: STP algorithm (root election, port role selection,      │
│                   state transitions), MSTP state machines (8 SMs)         │
│   Data sent to stpsync: calls stpsync_update_port_state(),               │
│     stpsync_update_stp_class(), stpsync_update_fastage_state(),           │
│     stpsync_flush_instance_port(), etc.                                    │
│   Data sent to kernel: /sbin/bridge vlan add/del (via stputil_*)          │
└──────────────────────────┬───────────────────────────────────────────────┘
                           │ Direct C function calls (same process)
                           │ (who decides: stpd state machines trigger
                           │  state changes; stpsync is the output path)
                           ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ stpsync (C++ Redis bridge, linked into stpd binary)                        │
│   Data received: C structs from stpd engine (STP_VLAN_TABLE,              │
│     STP_VLAN_PORT_TABLE, STP_MST_TABLE, etc.)                              │
│   Decision logic: field-level filtering (only writes non-default values), │
│                   warm-restart table clearing, batching                     │
│   Data sent to APPL_DB: ProducerStateTable writes to ALL of:              │
│     STP_VLAN_TABLE         — per-VLAN bridge/root info                    │
│     STP_VLAN_PORT_TABLE    — per-VLAN-per-port state + stats               │
│     STP_VLAN_INSTANCE_TABLE — VLAN→instance mapping                        │
│     STP_PORT_TABLE         — per-port admin state, bpdu_guard, port_fast   │
│     STP_PORT_STATE_TABLE   — per-port-per-instance STP state (0-4)        │
│     STP_FASTAGEING_FLUSH_TABLE — FDB flush trigger on topology change      │
│     STP_INST_PORT_FLUSH_TABLE — MST instance-level port flush              │
│     STP_MST_INST_TABLE     — MST instance bridge/root info                 │
│     STP_MST_PORT_TABLE     — MST per-instance port state + stats           │
│   NOTE: There is NO STATE_DB write for STP state. ALL STP tables are      │
│         in APPL_DB. The show spanning-tree CLI reads from APPL_DB.         │
│         The ONLY STP table in STATE_DB is STP_TABLE (max_stp_inst).       │
└──────────────────────────┬───────────────────────────────────────────────┘
                           │ Redis write (ProducerStateTable)
                           │ (who decides: stpsync is a passive output
                           │  layer; stpd decides the values)
                           ▼
               ┌───────────────────────────────────────┐
               │         APPL_DB (Redis)                │
               │  ALL STP state tables listed above     │
               └───────────┬───────────────────────────┘
                           │ Redis keyspace notification
                           ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ StpOrch (inside orchagent, docker-swss container)                          │
│   Data received: APPL_DB table/key/op/fields via Consumer                 │
│   Decision logic: maps STP instance IDs to SAI OIDs, creates STP          │
│                   instances/ports on demand, maps internal state (0-4)    │
│                   to SAI state enum                                        │
│   Data sent to SAI:                                                       │
│     sai_stp_api: create_stp, remove_stp, create_stp_port,                 │
│                  remove_stp_port, set_stp_port_attribute(STATE)            │
│     sai_vlan_api: set_vlan_attribute(STP_INSTANCE)                        │
│     sai_fdb_api:  flush_fdb_entries (on topology change)                  │
└──────────────────────────┬───────────────────────────────────────────────┘
                           │ SAI API calls
                           ▼
                   ┌───────────────────┐
                   │  syncd → SAI → ASIC│
                   └───────────────────┘
```

### Critical Asymmetry vs. the VLAN Pipeline

In the VLAN pipeline (`doc/vlan.md`), `vlanmgrd` writes directly to APPL_DB — the
config reader is also the APPL_DB producer. In the STP pipeline, the config reader
(`stpmgrd`) is **not** the APPL_DB producer — `stpsync` (inside stpd) is. This
creates a 3-hop path for config (CONFIG_DB → stpmgrd → IPC → stpd → stpsync →
APPL_DB) vs. the VLAN pipeline's 2-hop path (CONFIG_DB → vlanmgrd → APPL_DB).

The reason is architectural: STP requires a long-running protocol engine (stpd)
that computes port states based on received BPDUs. stpmgrd just translates
CONFIG_DB changes into IPC messages. stpd then processes BPDUs, runs the STP
algorithm, and stpsync writes the **computed** results (not just config) to APPL_DB.

### Dual Enforcement: Kernel + ASIC

When stpd determines a port state change, TWO enforcement paths are triggered
**synchronously** from the same function:

```
PVST:  stputil_set_port_state()
         ├─ stputil_set_kernel_bridge_port_state()  → /sbin/bridge vlan add/del
         └─ stpsync_update_port_state()             → APPL_DB → StpOrch → SAI

MSTP:  mstputil_set_port_state()
         ├─ mstputil_set_kernel_bridge_port_state()  → /sbin/bridge vlan add/del
         └─ stpsync_update_port_state()             → APPL_DB → StpOrch → SAI
```

Both are called from the same function, one after the other. There is no error
propagation between them — if `/sbin/bridge` fails, the APPL_DB update still
proceeds, and vice versa. This means the kernel bridge and the ASIC can get out
of sync if either path fails independently.

## Workflow Diagram

This diagram shows every inter-process communication mechanism in the STP
pipeline. Each arrow is labeled with the actual transport, socket path, or
API used — not just a generic description.

```
                    ┌─────────────────────────────────────────────────┐
                    │              docker-stp container               │
                    │                                                 │
                    │  ┌───────────────────────────────────────────┐ │
                    │  │       stpmgrd (cfgmgr, C++)               │ │
                    │  │                                           │ │
                    │  │  Select event loop:                       │ │
                    │  │    Consumer(conf_db, "STP")               │ │
                    │  │    Consumer(conf_db, "STP_VLAN")          │ │
                    │  │    Consumer(conf_db, "STP_VLAN_PORT")     │ │
                    │  │    Consumer(conf_db, "STP_PORT")          │ │
                    │  │    Consumer(conf_db, "STP_MST")           │ │
                    │  │    Consumer(conf_db, "STP_MST_INST")      │ │
                    │  │    Consumer(conf_db, "STP_MST_PORT")      │ │
                    │  │    Consumer(state_db, "VLAN_MEMBER_TABLE")│ │
                    │  │    Consumer(conf_db, "LAG_MEMBER_TABLE")  │ │
                    │  │                                           │ │
                    │  │  doTask() → doStpGlobalTask /             │ │
                    │  │              doStpVlanTask /              │ │
                    │  │              doStpPortTask / ...          │ │
                    │  │       │                                   │ │
                    │  │       │ sendMsgStpd()                     │ │
                    │  └───────┼───────────────────────────────────┘ │
                    │          │                                     │
                    │          │  (A) AF_UNIX SOCK_DGRAM              │
                    │          │  sendto() → /var/run/stpipc.sock    │
                    │          │                                     │
                    │  ┌───────┼───────────────────────────────────┐ │
                    │  │       ▼      stpd (C protocol engine)     │ │
                    │  │                                           │ │
                    │  │  libevent loop (single-threaded):         │ │
                    │  │    EV_READ on stpipc.sock                 │ │
                    │  │      → stpmgr_recv_client_msg()           │ │
                    │  │      → stpmgr_process_ipc_msg()           │ │
                    │  │         dispatch by msg_type:             │ │
                    │  │           STP_BRIDGE_CONFIG → stpmgr_*    │ │
                    │  │           STP_VLAN_CONFIG  → stpmgr_*    │ │
                    │  │           STP_PORT_CONFIG  → stpmgr_*    │ │
                    │  │           STP_MST_*_CONFIG → mstpmgr_*   │ │
                    │  │                                           │ │
                    │  │    EV_READ on PF_PACKET sockets (per-port)│ │
                    │  │      BPF filter: STP + PVST BPDUs only    │ │
                    │  │      → stp_pkt_rx_handler()               │ │
                    │  │         → stpmgr_process_rx_bpdu() [PVST] │ │
                    │  │         → mstpmgr_rx_bpdu()       [MSTP]  │ │
                    │  │                                           │ │
                    │  │    100ms timer (priority 0):              │ │
                    │  │      → stpmgr_100ms_timer()               │ │
                    │  │         → mstputil_timer_tick()           │ │
                    │  │         → stptimer_tick()                 │ │
                    │  │                                           │ │
                    │  │    Netlink events:                        │ │
                    │  │      → stp_intf_netlink_cb()              │ │
                    │  │         → port add/del, link state chg    │ │
                    │  │                                           │ │
                    │  │  State change → DUAL enforcement:         │ │
                    │  │    stputil_set_port_state() [PVST]        │ │
                    │  │    mstputil_set_port_state() [MSTP]       │ │
                    │  │       │                                   │ │
                    │  │       ├─ (B1) system() call               │ │
                    │  │       │   /sbin/bridge vlan add/del       │ │
                    │  │       │   → Linux kernel bridge           │ │
                    │  │       │                                   │ │
                    │  │       └─ (B2) direct C fn call ───────┐   │ │
                    │  │          (same process, same binary)   │   │ │
                    │  │                                        │   │ │
                    │  ├────────────────────────────────────────┘   │ │
                    │  │                                            │ │
                    │  │  ┌──────────────────────────────────────┐  │ │
                    │  │  │  stpsync (C++ Redis bridge)          │  │ │
                    │  │  │                                      │  │ │
                    │  │  │  StpSync global object (singleton):  │  │ │
                    │  │  │    ProducerStateTable m_*Table(      │  │ │
                    │  │  │      APPL_DB, "STP_*_TABLE")        │  │ │
                    │  │  │                                      │  │ │
                    │  │  │  Functions called from stpd C code:  │  │ │
                    │  │  │    stpsync_update_port_state()       │  │ │
                    │  │  │    stpsync_update_stp_class()        │  │ │
                    │  │  │    stpsync_add_vlan_to_instance()    │  │ │
                    │  │  │    stpsync_update_fastage_state()    │  │ │
                    │  │  │    stpsync_flush_instance_port()     │  │ │
                    │  │  └──────────────┬───────────────────────┘  │ │
                    │  └─────────────────┼──────────────────────────┘ │
                    │                    │                            │
                    └────────────────────┼────────────────────────────┘
                                         │
                           (C) Redis Unix socket
                           ProducerStateTable.set()
                           → HSET key field value
                           → PUBLISH __keyspace@0__:...
                                         │
                                         ▼
                    ┌────────────────────────────────────────────┐
                    │         Redis (APPL_DB, index 0)           │
                    │                                            │
                    │  STP_VLAN_TABLE          (bridge/root info)│
                    │  STP_VLAN_PORT_TABLE     (port state+stats)│
                    │  STP_VLAN_INSTANCE_TABLE (VLAN→instance)   │
                    │  STP_PORT_TABLE          (admin state)     │
                    │  STP_PORT_STATE_TABLE    (port STP state)  │
                    │  STP_FASTAGEING_FLUSH_TABLE (FDB flush)    │
                    │  STP_INST_PORT_FLUSH_TABLE (MST inst flush)│
                    │  STP_MST_INST_TABLE      (MST inst info)   │
                    │  STP_MST_PORT_TABLE      (MST port state)  │
                    └─────────────┬──────────────────────────────┘
                                  │
                     (D) Redis keyspace notifications
                     SUBSCRIBE __keyspace@0__:STP_*_TABLE
                     → ConsumerTableBase::pops()
                                  │
                                  ▼
                    ┌────────────────────────────────────────────┐
                    │      docker-swss container                 │
                    │                                            │
                    │  ┌──────────────────────────────────────┐  │
                    │  │    orchagent → StpOrch (C++)         │  │
                    │  │                                      │  │
                    │  │  Select event loop:                  │  │
                    │  │    Consumer(appl_db,                 │  │
                    │  │      "STP_VLAN_INSTANCE_TABLE")      │  │
                    │  │    Consumer(appl_db,                 │  │
                    │  │      "STP_PORT_STATE_TABLE")         │  │
                    │  │    Consumer(appl_db,                 │  │
                    │  │      "STP_FASTAGEING_FLUSH_TABLE")   │  │
                    │  │    Consumer(appl_db,                 │  │
                    │  │      "STP_INST_PORT_FLUSH_TABLE")    │  │
                    │  │                                      │  │
                    │  │  doTask() → doStpTask /              │  │
                    │  │              doStpPortStateTask /    │  │
                    │  │              doStpFastageTask /      │  │
                    │  │              doMstInstPortFlushTask  │  │
                    │  │       │                              │  │
                    │  │       │ SAI C API calls              │  │
                    │  └───────┼──────────────────────────────┘  │
                    │          │                                  │
                    └──────────┼──────────────────────────────────┘
                               │
                     (E) sairedis (Redis-based)
                     SAI object create/set attribute
                     → Redis to syncd
                               │
                               ▼
                    ┌────────────────────────────────────────────┐
                    │       docker-syncd container               │
                    │                                            │
                    │  syncd → vendor SAI lib → ASIC SDK → HW    │
                    │                                            │
                    │  sai_stp_api:                              │
                    │    create_stp / remove_stp                  │
                    │    create_stp_port / remove_stp_port        │
                    │    set_stp_port_attribute(STATE)            │
                    │  sai_vlan_api:                              │
                    │    set_vlan_attribute(STP_INSTANCE)         │
                    │  sai_fdb_api:                               │
                    │    flush_fdb_entries()                      │
                    └────────────────────────────────────────────┘


IPC MECHANISM LEGEND:

  (A)  stpmgrd → stpd:
       AF_UNIX + SOCK_DGRAM (datagram socket)
       stpmgrd: sendto(stpd_fd, ..., "/var/run/stpipc.sock")  [stpmgr.cpp:1266]
       stpd:    recvfrom(stpipc_sock, ...) → stpmgr_process_ipc_msg()
                [stp_mgr.c:1999→1866]

  (B1) stpd → kernel bridge:
       system() call (blocking)
       /sbin/bridge vlan add/del vid N dev <port> [un]tagged
       [stp_util.c:158-163] [mstp_util.c:992-1010]

  (B2) stpd → stpsync:
       Direct C function call (same process — stpsync is linked into stpd binary)
       stpsync_update_port_state(), stpsync_update_stp_class(), etc.
       [stp_util.c:189] [mstp_util.c:1093]

  (C)  stpsync → Redis (APPL_DB):
       Redis Unix socket (DEFAULT_UNIXSOCKET = /var/run/redis/redis.sock)
       ProducerStateTable::set() → HSET + PUBLISH
       [stp_sync.cpp:50-52, 173, 423]

  (D)  Redis (APPL_DB) → StpOrch (orchagent):
       Redis keyspace notifications (pub/sub)
       SUBSCRIBE __keyspace@0__:<table> → ConsumerTableBase::pops()
       [orch.cpp:561, stporch.cpp:583]

  (E)  StpOrch → syncd → ASIC:
       sairedis: SAI API → Redis OP → syncd → vendor SAI lib → ASIC SDK
       (same mechanism as all orchagent SAI calls)
       [stporch.cpp:67, 139, 247, 351]
```

## Redis Table Relationships

**Critical correction**: Earlier versions of this document incorrectly stated
that STP state tables were in STATE_DB. In reality, stpsync writes ALL STP
state tables to **APPL_DB** (confirmed by reading `stpsync/stp_sync.cpp:33-45`
which passes an `APPL_DB` DBConnector to all `ProducerStateTable` constructors).
The `show spanning-tree` CLI reads from APPL_DB (confirmed by `show/stp.py`).

The only STP-related STATE_DB table is `STP_TABLE|GLOBAL` which holds
`max_stp_inst` — written by StpOrch after querying SAI capabilities, read by
stpmgrd during startup to know the instance limit.

### CONFIG_DB Tables

| Table | Key Format | Fields | Defined In |
|-------|------------|--------|------------|
| `STP` | `GLOBAL` | `mode` (pvst/mst), `rootguard_timeout` | schema.h (`CFG_STP_GLOBAL_TABLE_NAME`) |
| `STP_VLAN` | `Vlan<id>` | `enabled`, `forward_delay`, `hello_time`, `max_age`, `priority` | schema.h |
| `STP_VLAN_PORT` | `Vlan<id>\|<port>` | `path_cost`, `priority` | schema.h |
| `STP_PORT` | `<port>` | `enabled`, `root_guard`, `loop_guard`, `bpdu_guard`, `bpdu_guard_do_disable`, `path_cost`, `priority`, `portfast`†, `uplink_fast`†, `edge_port`‡, `link_type`‡ | schema.h |
| `STP_MST` | `GLOBAL` | `name`, `revision`, `forward_delay`, `hello_time`, `max_age`, `max_hops` | cfg_schema.h* |
| `STP_MST_INST` | `MST_INSTANCE\|<id>` | `bridge_priority`, `vlan_list` | cfg_schema.h* |
| `STP_MST_PORT` | `INSTANCE\|<id>\|<port>` | `path_cost`, `priority` | cfg_schema.h* |

> † PVST-only. ‡ MSTP-only.
> \* Defined in `cfg_schema.h` but used as **hardcoded strings** in `stpmgr.cpp:35-37` and `stpmgrd.cpp:47-49` instead of the defined constants (a known minor inconsistency).

### APPL_DB Tables (ALL written by stpsync inside stpd)

| Table | Key Format | Written By | Purpose |
|-------|------------|------------|---------|
| `STP_VLAN_TABLE` | `Vlan<id>` | `StpSync::updateStpVlanInfo()` | Bridge ID, root bridge ID, timers, topology change count |
| `STP_VLAN_PORT_TABLE` | `Vlan<id>:<port>` | `StpSync::updateStpVlanInterfaceInfo()` | Port state, designated root/bridge, BPDU stats |
| `STP_VLAN_INSTANCE_TABLE` | `Vlan<id>` | `StpSync::addVlanToInstance()` | `stp_instance=<id>` → consumed by StpOrch |
| `STP_PORT_TABLE` | `<port>` | `StpSync::updatePortAdminState()` | `admin_status`, `bpdu_guard_shutdown`, `port_fast`, `mst_boundary` |
| `STP_PORT_STATE_TABLE` | `<port>:<instance>` | `StpSync::updateStpPortState()` | `state=<0-4>` → consumed by StpOrch |
| `STP_FASTAGEING_FLUSH_TABLE` | `Vlan<id>` | `StpSync::updateStpVlanFastage()` | `state=true` → triggers FDB flush via StpOrch |
| `STP_INST_PORT_FLUSH_TABLE` | `<instance>:<port>` | `StpSync::flushStpInstancePort()` | MST instance-level FDB flush trigger |
| `STP_MST_INST_TABLE` | `<mst_id>` | `StpSync::updateStpMstInfo()` | MST bridge/root info, VLAN mask |
| `STP_MST_PORT_TABLE` | `<mst_id>:<port>` | `StpSync::updateStpMstInterfaceInfo()` | MST per-instance port state, role, stats |
| `STP_BPDU_GUARD_TABLE` | (defined, not used in core flow) | — | Reserved for BPDU guard state (constant exists in schema.h, not referenced in stpsync) |

### STATE_DB Table (only one)

| Table | Key Format | Written By | Read By | Purpose |
|-------|------------|------------|---------|---------|
| `STP_TABLE` | `GLOBAL` | `StpOrch::updateMaxStpInstance()` | `StpMgr::getStpMaxInstances()` | `max_stp_inst` — SAI capability → stpmgrd |

### YANG Model Verification

The YANG model (`sonic-spanning-tree.yang`) defines these containers which map
to CONFIG_DB tables:

```
container sonic-spanning-tree
  container STP           → CONFIG_DB STP
  container STP_VLAN      → CONFIG_DB STP_VLAN
  container STP_VLAN_PORT → CONFIG_DB STP_VLAN_PORT
  container STP_PORT      → CONFIG_DB STP_PORT
  container STP_MST       → CONFIG_DB STP_MST
  container STP_MST_INST  → CONFIG_DB STP_MST_INST
  container STP_MST_PORT  → CONFIG_DB STP_MST_PORT
```

**No legacy names exist**: A search confirmed that `STP_INTF` and `STP_VLAN_INTF`
are NOT used as table names anywhere in the codebase. The only `STP_INTF`
references are in `sonic-stp/include/stp_intf.h` which defines the C data
structure for the interface database, not a Redis table name.

## Deep BPDU Trace: Wire → State Machine → Wire

This section traces a single BPDU through all three layers — ASIC, kernel, and
stpd — in both the receive and transmit directions.

### BPDU Receive Path (RX)

```
┌──────────────────────────────────────────────────────────────────────────┐
│ LAYER 1 — ASIC                                                           │
│                                                                          │
│ BPDU frame arrives on front-panel port.                                  │
│                                                                          │
│ Two SAI hostif trap types are relevant:                                  │
│                                                                          │
│ ┌─────────────────────────────────────────────────────────────────────┐ │
│ │ SAI_HOSTIF_TRAP_TYPE_STP    (id=0x00000000)                          │ │
│ │   Matches: DMAC = 01:80:c2:00:00:00 (IEEE STP bridge group address) │ │
│ │   Used by: STP, RSTP, MSTP BPDUs                                     │ │
│ │   CoPP group: typically "queue4_group2" (copy to CPU, low rate)      │ │
│ ├─────────────────────────────────────────────────────────────────────┤ │
│ │ SAI_HOSTIF_TRAP_TYPE_PVRST  (id=0x00000004)                          │ │
│ │   Matches: DMAC = 01:00:0c:cc:cc:cd (Cisco PVST+ bridge group addr) │ │
│ │   Used by: PVST+ BPDUs only                                          │ │
│ │   CoPP group: typically same as STP or a separate low-rate group     │ │
│ └─────────────────────────────────────────────────────────────────────┘ │
│                                                                          │
│ CoPP (Control Plane Policing) protects the CPU:                          │
│   - Each trap type is assigned to a trap group (e.g., "queue4_group2")   │
│   - Trap priority (1-4) determines scheduling precedence                 │
│   - Policer (CIR/CBS, e.g., 600 pps) rate-limits BPDUs to the CPU        │
│   - RED action = "drop" — excess BPDUs are dropped silently              │
│   - BPDUs use low-rate policers (600 pps) because STP only sends ~1/sec  │
│     per port — a higher rate indicates a loop or attack                  │
│                                                                          │
│ The ASIC copies/punts the BPDU to the CPU via PCIe host interface.       │
│ CoPP configuration is platform-specific (copp_cfg.j2 template).          │
└────────────────────────────┬─────────────────────────────────────────────┘
                             │ PCIe / CPU port
                             ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ LAYER 2 — Linux Kernel                                                    │
│                                                                          │
│ The punted BPDU enters the kernel network stack as a normal packet        │
│ on the ingress interface (e.g., Ethernet0).                              │
│                                                                          │
│ stpd opens one PF_PACKET socket per physical port:                       │
│                                                                          │
│   socket(PF_PACKET, SOCK_RAW, htons(ETH_P_ALL))                          │
│   setsockopt(PACKET_AUXDATA, 1)  ← receive VLAN info                     │
│   setsockopt(SO_ATTACH_FILTER, BPF_FILTER) ← filter STP/PVST only        │
│   bind(sock_fd, &sa, ...)  ← bind to specific interface (sa.sll_ifindex) │
│                                                                          │
│ The BPF filter (cBPF bytecode, g_stp_filter[]) does:                     │
│   1. Load half-word at offset 12 (EtherType/length)                      │
│   2. If > 1500 → REJECT (not a BPDU — BPDUs are small)                  │
│   3. Load word at offset 0 (first 4 bytes of DMAC)                       │
│   4. If == 0x01000ccc → check bytes 4-5 for 0xcccd → ACCEPT (PVST)      │
│   5. Else: load byte at offset 14 (LLC DSAP)                             │
│   6. If == 0x42 → ACCEPT (standard STP — LSAP_BRIDGE_SPANNING_TREE)      │
│   7. Else: REJECT                                                        │
│                                                                          │
│ The socket is registered with libevent (EV_READ|EV_PERSIST), so when     │
│ a matching packet arrives, stp_pkt_rx_handler() is called.               │
│                                                                          │
│ PACKET_AUXDATA provides the VLAN tag from hardware (TP_STATUS_VLAN_VALID)│
│ in the ancillary data of recvmsg(), giving stpd the exact VLAN ID the    │
│ BPDU was received on without having to parse the 802.1Q header.          │
└────────────────────────────┬─────────────────────────────────────────────┘
                             │ libevent callback
                             ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ LAYER 3 — stpd (Protocol Engine)                                          │
│                                                                          │
│ stp_pkt_rx_handler(fd, what, arg):                                       │
│   1. recvmsg(fd, &msg, MSG_TRUNC) — receive raw frame                    │
│   2. Extract VLAN ID from PACKET_AUXDATA (tp_vlan_tci & 0x0fff)          │
│   3. LAG redirect: if intf_node->master_ifindex != 0,                    │
│      replace intf_node with PortChannel's INTERFACE_NODE                 │
│   4. Dispatch by protocol:                                               │
│                                                                          │
│   ┌─ PVST ENABLED ──────────────────────────────────────────────────┐   │
│   │ stpmgr_process_rx_bpdu(vlan_id, port_id, pkt)                    │   │
│   │   → stputil_process_bpdu()                                       │   │
│   │     Parse BPDU header (protocol_id, bpdu_type, flags)            │   │
│   │     Validate BPDU: message age < max_age, port state != DISABLED │   │
│   │     Dispatch by BPDU type:                                       │   │
│   │       CONFIG_BPDU_TYPE: → received_config_bpdu(stp_class, port, bpdu)│
│   │         - Compare root bridge ID → root_selection()              │   │
│   │         - Compare path cost → designated_port_selection()        │   │
│   │         - Compute new port state → port_state_selection()        │   │
│   │         - If state changed: stputil_set_port_state()             │   │
│   │             ├─ stputil_set_kernel_bridge_port_state()            │   │
│   │             │   FORWARDING: /sbin/bridge vlan add vid N dev port │   │
│   │             │   !FORWARDING: /sbin/bridge vlan del vid N dev port│   │
│   │             └─ stpsync_update_port_state()                       │   │
│   │       TCN_BPDU_TYPE: → received_tcn_bpdu(stp_class, port)        │   │
│   │         - Set topology_change flag                               │   │
│   │         - Shorten aging timer → stpsync_update_fastage_state()   │   │
│   └──────────────────────────────────────────────────────────────────┘   │
│                                                                          │
│   ┌─ MSTP ENABLED ──────────────────────────────────────────────────┐   │
│   │ if (stpmgr_protect_process(port_id, vlan_id)) return;  ← BPDU guard│
│   │ if (pkt[1] == 128) ← TCN via MSTP BPDU with tcAck flag          │   │
│   │ mstpmgr_rx_bpdu(vlan_id, port_id, pkt, pkt_len)                 │   │
│   │   → mstputil_validate_bpdu()                                    │   │
│   │   → mstpdata_rx_bpdu() → updates MSTP port data from BPDU       │   │
│   │   → mstp_prx_gate() → Port Receive SM runs                      │   │
│   │     PRX processes the BPDU, updates port's spanning tree info   │   │
│   │   → On next 100ms timer tick:                                    │   │
│   │     PRS gates → Port Role Selection computes new role           │   │
│   │     PRT gates → Port Role Transitions (proposal/agreement)      │   │
│   │     PST gates → if state changed: mstputil_set_port_state()     │   │
│   │       ├─ mstputil_set_kernel_bridge_port_state()                │   │
│   │       │   FORWARDING: /sbin/bridge vlan add for ALL inst VLANs   │   │
│   │       │   !FORWARDING: /sbin/bridge vlan del for ALL inst VLANs │   │
│   │       └─ stpsync_update_port_state()                            │   │
│   │     TCM gates → if topology change: stpsync_flush_instance_port()│   │
│   └──────────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────────┘
```

### BPDU Transmit Path (TX)

```
┌──────────────────────────────────────────────────────────────────────────┐
│ LAYER 3 — stpd (TX trigger)                                               │
│                                                                          │
│ BPDUs are transmitted periodically (hello_time, default 2s) or           │
│ on topology change:                                                      │
│                                                                          │
│   PVST: stputil_send_config_bpdu() / stputil_send_tcn_bpdu()            │
│   MSTP: mstp_ptx_gate() → Port Transmit SM schedules TX                 │
│                                                                          │
│   Both call: stp_pkt_tx_handler(port_id, vlan_id, buffer, size, tagged) │
│                                                                          │
│ BPDU TX uses a single shared PF_PACKET socket (g_stpd_pkt_handle)       │
│ opened in stpd_main(), NOT per-port sockets. This simplifies the design  │
│ for PortChannel TX — the kernel bonding driver handles member selection. │
│                                                                          │
│   stp_pkt_tx_handler():                                                  │
│   1. Look up INTERFACE_NODE by port_id → get kif_index                   │
│   2. If tagged VLAN: insert 802.1Q header (TPID=0x8100, PCP=7, VID)     │
│   3. sendto(shared_sock, send_buf, size, 0, &sa, sizeof(sa))            │
│      where sa.sll_ifindex = intf_node->kif_index                        │
│   4. If error: increment pkt_tx_err counter, log error                   │
└────────────────────────────┬─────────────────────────────────────────────┘
                             │ sendto()
                             ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ LAYER 2 — Linux Kernel (TX)                                               │
│                                                                          │
│ The sendto() on a PF_PACKET socket delivers the raw frame to the         │
│ kernel's transmit path for the specified interface.                      │
│                                                                          │
│ For PortChannel interfaces: the kernel bonding driver selects which      │
│ physical member port to use for TX (based on the bonding hash policy).   │
│                                                                          │
│ No special handling is needed — the frame is transmitted like any        │
│ other raw packet on that interface.                                      │
└────────────────────────────┬─────────────────────────────────────────────┘
                             │ Kernel → driver → hardware
                             ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ LAYER 1 — ASIC (TX)                                                       │
│                                                                          │
│ The kernel transmits the frame via the NIC driver to the ASIC, which     │
│ sends it out the physical front-panel port.                              │
│                                                                          │
│ BPDU TX frames are NOT subject to STP blocking in the ASIC — they are    │
│ sent from the CPU and egress directly, bypassing the ingress pipeline    │
│ that would otherwise block/forward based on STP port state.              │
│                                                                          │
│ BPDU DMAC varies by protocol:                                            │
│   STP/RSTP/MSTP: 01:80:c2:00:00:00                                      │
│   PVST+:         01:00:0c:cc:cc:cd                                       │
└──────────────────────────────────────────────────────────────────────────┘
```

## Kernel-Side STP Enforcement

### The Problem

The Linux vlan-aware bridge does not provide a mechanism to directly set an
STP port state on a bridge port. The kernel bridge has its own built-in STP
implementation (which SONiC disables), but there's no netlink attribute to say
"set this port's STP state to BLOCKING" from userspace.

### The Workaround

SONiC enforces STP port state on the kernel side by **manipulating the bridge
VLAN membership** of ports:

- **When a port transitions to non-FORWARDING** (BLOCKING, LISTENING, DISABLED):
  The port's VLAN membership is **removed** from the kernel bridge
  (`/sbin/bridge vlan del vid N dev port`). The kernel bridge then cannot
  forward traffic for that VLAN on that port.

- **When a port transitions back to FORWARDING**:
  The port's VLAN membership is **re-added** to the kernel bridge
  (`/sbin/bridge vlan add vid N dev port [untagged|tagged]`). The kernel
  bridge resumes forwarding for that VLAN on that port.

### Implementation

The enforcement is implemented by two parallel functions:

**PVST** (`stp/stp_util.c:143-178`):
```c
bool stputil_set_kernel_bridge_port_state(STP_CLASS *stp_class, STP_PORT_CLASS *stp_port_class)
{
    // FORWARDING → /sbin/bridge vlan add vid <N> dev <port> [untagged|tagged]
    // !FORWARDING → /sbin/bridge vlan del vid <N> dev <port> [untagged|tagged]
    // Tracks kernel_state (STP_KERNEL_STATE_FORWARD / STP_KERNEL_STATE_BLOCKING)
    // to avoid redundant system() calls
}
```

**MSTP** (`mstp/mstp_util.c:950-1029`):
```c
bool mstputil_set_kernel_bridge_port_state(MSTP_INDEX mstp_index, PORT_ID port_number, L2_PORT_STATE state)
{
    // Computes VLAN bitmap intersection: port_vlans & instance_vlans
    // FORWARDING → /sbin/bridge vlan add for ALL affected VLANs
    // !FORWARDING → /sbin/bridge vlan del for ALL affected VLANs
    // Uses system() call for each VLAN
    // Also has single-VLAN variant: mstputil_set_kernel_bridge_port_state_for_single_vlan()
}
```

### Call Chain

Both PVST and MSTP trigger kernel enforcement through the same pattern:

**PVST:**
```
port_state_selection()  [stp/stp.c]
  → make_forwarding() or make_blocking()
    → stputil_set_port_state(stp_class, stp_port_class)
      ├─ stputil_set_kernel_bridge_port_state()    ← KERNEL SIDE
      │    → system("/sbin/bridge vlan add/del ...")
      └─ stpsync_update_port_state()               ← ASIC SIDE (via APPL_DB → StpOrch → SAI)
```

**MSTP:**
```
PST (Port State Transition SM)  [mstp/mstp_pst.c]
  → mstputil_set_port_state(mstp_index, port_number, state)
    ├─ mstputil_set_kernel_bridge_port_state()     ← KERNEL SIDE
    │    → system("/sbin/bridge vlan add/del ...") for ALL instance VLANs
    └─ stpsync_update_port_state()                 ← ASIC SIDE (via APPL_DB → StpOrch → SAI)
```

### Relationship with ASIC-Side Enforcement

The kernel-side and ASIC-side enforcement are triggered **synchronously from the
same function call**. They are NOT independently triggered. The sequence is:

1. stpd detects a port state change
2. `stputil_set_port_state()` (or MSTP equivalent) is called
3. **First**: kernel bridge VLAN membership is modified (`/sbin/bridge vlan add/del`)
4. **Second**: APPL_DB is updated (`stpsync_update_port_state()`)
5. **Later** (asynchronously): orchagent picks up the APPL_DB change and programs SAI

**Failure modes:** If step 3 succeeds but the orchagent-to-SAI path (step 5) fails
(e.g., SAI returns an error), the kernel bridge will forward/block traffic
correctly but the ASIC hardware state will be wrong. Conversely, if
`/sbin/bridge` fails (e.g., the bridge device is not ready), the ASIC will be
programmed correctly but the kernel bridge will be wrong.

**Troubleshooting implication:** When debugging STP issues, always check BOTH
the kernel bridge state (`bridge vlan show`) AND the ASIC state
(`show spanning_tree` via APPL_DB + SAI debug counters). They can diverge.

**Note for virtual switch (sonic-vs):** On the sonic-vs platform, the kernel
bridge IS the data plane (there is no hardware ASIC). The kernel-side
enforcement described here is the **primary** forwarding enforcement mechanism.
The SAI STP calls are still made (to the virtual SAI implementation) but the
actual forwarding control happens through the `/sbin/bridge vlan` mechanism.

## Port-ID Allocation

### Physical Ports (Deterministic)

Physical Ethernet ports get their port ID directly from their interface name:
```c
// stp_intf.c:432
port_id = strtol(((char *)if_db->ifname + STP_ETH_NAME_PREFIX_LEN), NULL, 10);
```

`Ethernet0` → port_id=0, `Ethernet48` → port_id=48. This is fully deterministic
across reboots — the same physical port always gets the same STP port ID.

Physical port IDs occupy the range `[0, g_max_stp_port/2)`.

### PortChannels (Non-Deterministic)

PortChannel port IDs are allocated dynamically from a bitset pool:
```c
// stp_intf.h:71-72
#define stp_intf_allocate_po_id()  (STP_BMP_PO_OFFSET + bmp_set_first_unset_bit(g_stpd_po_id_pool))
#define stp_intf_release_po_id(_port_id) bmp_reset(g_stpd_po_id_pool, (_port_id - STP_BMP_PO_OFFSET))
```

Where `STP_BMP_PO_OFFSET = g_max_stp_port/2`.

PortChannel IDs occupy `[g_max_stp_port/2, g_max_stp_port)`.

### The Non-Determinism Problem

PortChannel port IDs are allocated in the order their **first member port is
discovered via netlink**. Since kernel netlink interface discovery order can
vary between reboots, the same PortChannel can receive a different STP port ID
across reboots.

For example:
- Boot 1: PortChannel1 gets ID 260, PortChannel2 gets ID 261
- Boot 2: PortChannel2 gets ID 260, PortChannel1 gets ID 261

### Why This Matters: Port Priority as Tiebreaker

In STP, when two ports have equal root path cost, the **port ID** is used as a
tiebreaker — the lower port ID wins and becomes the Designated Port.

Because PortChannel port IDs are non-deterministic across reboots, the tiebreak
outcome between two PortChannels with equal path cost **can change across
reboots**. This can cause the spanning tree topology to differ after each
restart, even with identical configuration.

**Mitigation:** Always configure an explicit **port priority** on PortChannel
interfaces when there's any possibility of equal path cost. Port priority
is encoded in the upper 4 bits of the 16-bit port identifier and is compared
before the port number (lower 12 bits), making it user-configurable and
deterministic.

```
STP Port Identifier (16 bits, per IEEE 802.1D):
  ┌──────────────────┬────────────────────────────┐
  │ Priority (4 bits) │ Port Number (12 bits)       │
  │ 0-15 (×16 = 0-240)│ Non-deterministic for POs   │
  └──────────────────┴────────────────────────────┘

Root Port Selection Tiebreak (when path costs are equal):
  1. Lowest Designated Root Bridge ID
  2. Lowest Root Path Cost
  3. Lowest Designated Bridge ID
  4. Lowest Designated Port ID (neighbor's priority + number)
  5. Lowest Local Port ID  ← NON-DETERMINISTIC for PortChannels

Configure port priority to make step 4 or 5 deterministic:
  config spanning-tree interface PortChannel1 priority 0    (best)
  config spanning-tree interface PortChannel2 priority 240  (worst, if tiebreak needed)
```

### Port-ID Lifecycle

```
1. Netlink discovers interface → stp_intf_netlink_cb()
2. For Ethernet: port_id = extracted from name (deterministic)
3. For PortChannel:
   a. Node created without port_id (= BAD_PORT_ID)
   b. First member joins → stp_intf_add_po_member()
   c. If g_stpd_port_init_done: port_id = stp_intf_allocate_po_id()
   d. g_stpd_port_init_done is set after initial netlink dump completes
   e. Pre-configured POs (config before netlink): stp_intf_handle_po_preconfig()
4. Port-ID is used in:
   - STP algorithm (root election tiebreak)
   - Port mask bitmaps (member tracking)
   - STATE_DB STP_VLAN_PORT_TABLE (port_num field for show CLI)
5. PO deletion (last member removed) → stp_intf_release_po_id() → frees the ID
```

### AVL Tree Purpose

The AVL tree (`g_stpd_intf_db`) stores all `INTERFACE_NODE` structures, keyed by
interface name (`ifname`). It provides fast lookup by name (`avl_find`) and
full iteration (for port_id-based lookups which require a traversal).

```c
// AVL key comparison (stp_intf.c:178-183):
int stp_intf_avl_compare(...) {
    return strncasecmp(pa->ifname, pb->ifname, IFNAMSIZ);
}
```

The AVL structure is used because interfaces are added/removed dynamically
(via netlink), and both name-based lookup (from config) and kif_index-based
lookup (from packet RX) are needed, but the data set is small enough
(< 512 entries) that a tree is sufficient.

## Source Files

### stpd Daemon (sonic-stp repo: `src/sonic-stp/`)

| File | Role |
|------|------|
| `stpd_main.cpp` | C++ `main()` — calls C `stpd_main()` |
| `stp/stp_main.c` | Daemon init: IPC, packet sockets, netlink, libevent loop |
| `stp/stp_mgr.c` | STP manager: IPC processing, 100ms timer, BPDU routing, port enable/disable (~2000 lines) |
| `stp/stp.c` | Core 802.1D algorithm: root election, designated port selection, port state transitions |
| `stp/stp_pkt.c` | BPDU RX/TX: PF_PACKET socket per port, BPF filter, VLAN-tagged TX |
| `stp/stp_data.c` | Data structure init/alloc/free: global, class (per-VLAN STP), port |
| `stp/stp_util.c` | BPDU encode/decode, validate, send, **kernel bridge enforcement**, bridge/port comparison |
| `stp/stp_intf.c` | Interface DB (AVL tree): port add/del, **port-ID allocation**, kif-index lookup |
| `stp/stp_netlink.c` | Netlink events: interface add/del, link state changes |
| `stp/stp_timer.c` | Tick-based timer implementation |
| `stp/stp_debug.c` | Debug display: BPDU dump, class/port/global state |
| `mstp/mstp.c` | Core MSTP: CIST/MSTI vector computation, agreement, proposal, dispute |
| `mstp/mstp_mgr.c` | MSTP manager: config handling, BPDU RX dispatch (~3200 lines) |
| `mstp/mstp_data.c` | MSTP data structures: bridge, port, per-instance port (msti) |
| `mstp/mstp_util.c` | MSTP utilities: vector comparison, BPDU ordering, digest, **kernel bridge enforcement** |
| `mstp/mstp_prx.c` | **PRX** — Port Receive state machine (IEEE 802.1s §13.22) |
| `mstp/mstp_ptx.c` | **PTX** — Port Transmit state machine (§13.25) |
| `mstp/mstp_prs.c` | **PRS** — Port Role Selection state machine (§13.23) |
| `mstp/mstp_prt.c` | **PRT** — Port Role Transitions state machine (§13.27) — RSTP rapid transition |
| `mstp/mstp_pst.c` | **PST** — Port State Transition state machine (§13.30) |
| `mstp/mstp_tcm.c` | **TCM** — Topology Change state machine (§13.28) |
| `mstp/mstp_pim.c` | **PIM** — Port Information state machine (§13.24) |
| `mstp/mstp_ppm.c` | **PPM** — Port Protocol Migration state machine (§13.26) |
| `mstp/mstp_lib.c` | MSTP library: query functions (root bridge, vlanmask, port states) |
| `stpsync/stp_sync.cpp` | C++ Redis sync: writes ALL STP tables to **APPL_DB** (not STATE_DB) |
| `stpsync/stp_sync.h` | StpSync class: owns 9 ProducerStateTables + 2 CONFIG_DB tables |
| `stpctl/stpctl.c` | CLI utility: show/debug/clear via AF_UNIX IPC to stpd |
| `include/l2.h` | L2 types: port states enum (DISABLED..FORWARDING), MAC/VLAN types, LLC/SNAP headers |
| `include/stp.h` | STP core structs: `BRIDGE_DATA`, `STP_CLASS`, `STP_PORT_CLASS`, `STP_GLOBAL`, `STP_KERNEL_STATE` |
| `include/mstp.h` | MSTP core structs: `MSTP_BRIDGE`, `MSTP_PORT`, `MSTP_CIST_BRIDGE`, `MSTP_MSTI_BRIDGE` |
| `include/stp_common.h` | STP BPDU wire format: config BPDU, TCN BPDU, PVST BPDU |
| `include/mstp_common.h` | MSTP BPDU wire format: `MSTP_BPDU`, `MSTI_CONFIG_MESSAGE`, `RSTP_BPDU` |
| `include/stp_dbsync.h` | DB sync C structs + extern declarations for all stpsync functions |
| `include/stp_ipc.h` | IPC message types and structs (mirrored in stpmgr.h) |
| `include/stp_main.h` | `STPD_CONTEXT` struct, libevent config, logging macros |
| `include/stp_intf.h` | Interface DB types: `INTERFACE_NODE`, port speed, **port-ID allocation macros**, MST info |
| `include/stp_netlink.h` | Netlink socket config, `netlink_db_t` |

### stpmgrd (Config Manager — `src/sonic-swss/cfgmgr/`)

| File | Role |
|------|------|
| `stpmgrd.cpp` | Main entry point, event loop |
| `stpmgr.h` | `StpMgr` class + all STP IPC message structs (mirrors stp_ipc.h) |
| `stpmgr.cpp` | `StpMgr` implementation (~1500 lines) |

### Orchagent (SWSS — `src/sonic-swss/orchagent/`)

| File | Role |
|------|------|
| `stporch.h` | `StpOrch` class declaration |
| `stporch.cpp` | `StpOrch` implementation (~616 lines) |
| `orchdaemon.cpp` | StpOrch construction + registration into orch list |

### CLI (sonic-utilities)

| File | Role |
|------|------|
| `config/stp.py` | `config spanning-tree ...` — ~1895 lines, all config subcommands |
| `show/stp.py` | `show spanning-tree ...` — reads from **APPL_DB** (not STATE_DB) |
| `debug/stp.py` | `debug spanning-tree ...` — calls stpctl |
| `clear/stp.py` | `clear spanning-tree statistics` — calls stpctl |

### YANG Model

| File | Role |
|------|------|
| `src/sonic-yang-models/yang-models/sonic-spanning-tree.yang` | YANG model: STP, STP_VLAN, STP_VLAN_PORT, STP_PORT, STP_MST, STP_MST_INST, STP_MST_PORT |

## CLI Command Traces

### 1. `config spanning-tree enable pvst` — Enable PVST Mode

```
CLI: config spanning-tree enable pvst
  │
  ▼
config/stp.py: stp_enable()
  → validates mode is 'pvst' or 'mst'
  → config_db.set_entry("STP", "GLOBAL", {"mode": "pvst"})
  │
  ▼
CONFIG_DB: STP|GLOBAL → {"mode": "pvst"}
  │ Redis keyspace notification
  ▼
stpmgrd: doStpGlobalTask(consumer)
  key="GLOBAL", op="SET"
  msg.stp_mode = L2_PVSTP
  msg.opcode = STP_SET_COMMAND
  → ebtables -A FORWARD -d 01:00:0c:cc:cc:cd -j DROP   # Prevent PVST BPDU flooding in kernel
  → sendMsgStpd(STP_BRIDGE_CONFIG, sizeof(msg), &msg)
  │
  ▼
stpd: stpmgr_recv_client_msg() → STP_BRIDGE_CONFIG
  → stpmgr_set_proto_mode(L2_PVSTP)
  → Enables PVST BPDU processing branch in stp_pkt_rx_handler()
  → PVST BPDUs (01:00:0c:cc:cc:cd) are now processed by the STP engine
  │
  ▼ (later, when a VLAN is configured with STP)
stpmgrd: doStpVlanTask() for Vlan100
  → allocL2Instance(vlan_id=100)  # PVST: one instance per VLAN, bitset pool
  → getAllVlanMem("Vlan100")      # collect member ports from STATE_VLAN_MEMBER_TABLE
  → sendMsgStpd(STP_VLAN_CONFIG)
  │
  ▼
stpd: stpmgr_process_vlan_config()
  → Creates STP_CLASS for VLAN 100
  → Begins sending/receiving PVST BPDUs on member ports
  │ (after topology converges)
  ▼
stpd: stputil_set_port_state(stp_class, stp_port_class)
  ├─ [KERNEL] stputil_set_kernel_bridge_port_state()
  │     → /sbin/bridge vlan add vid 100 dev Ethernet0 [untagged|tagged]
  └─ [APPL_DB] stpsync_update_port_state("Ethernet0", instance=100, state=FORWARDING)
       → m_stpPortStateTable.set("Ethernet0:100", {"state": "4"})
  │
  ▼
APPL_DB: STP_PORT_STATE_TABLE|Ethernet0:100 → {"state": "4"}
  │ Redis keyspace notification
  ▼
orchagent: StpOrch::doStpPortStateTask()
  key="Ethernet0:100", port_alias="Ethernet0", instance=100, state=4
  → updateStpPortState(port, 100, FORWARDING)
    → addStpPort(port, 100)     # create SAI STP port if needed
    → getStpSaiState(4)         # FORWARDING → SAI_STP_PORT_STATE_FORWARDING
    → sai_stp_api->set_stp_port_attribute(oid, SAI_STP_PORT_ATTR_STATE, FORWARDING)
  │
  ▼
syncd → SAI → ASIC: port Ethernet0 forwards traffic for VLAN 100
```

**Tables touched:**

| Step | DB | Table | Key | Change |
|------|----|-------|-----|--------|
| CLI | CONFIG_DB | STP | GLOBAL | `mode=pvst` |
| stpmgrd→stpd | IPC | — | — | STP_BRIDGE_CONFIG msg |
| stpd→kernel | — | — | — | `/sbin/bridge vlan add vid 100 dev Ethernet0` |
| stpsync | APPL_DB | STP_PORT_STATE_TABLE | `Ethernet0:100` | `state=4` |
| orchagent | SAI | STP port attr | OID | `SAI_STP_PORT_STATE_FORWARDING` |

### 2. `config spanning-tree mode mstp` — Switch to MSTP Mode

```
CLI: config spanning-tree mode mstp
  │
  ▼
config/stp.py: set_mode("mstp")
  → config_db.set_entry("STP", "GLOBAL", {"mode": "mst"})
  │
  ▼
CONFIG_DB: STP|GLOBAL → {"mode": "mst"}
  │
  ▼
stpmgrd: doStpGlobalTask()
  msg.stp_mode = L2_MSTP
  → fill_n(m_vlanInstMap, MAX_VLANS, 0)  # All VLANs → instance 0 (CIST)
  → sendMsgStpd(STP_BRIDGE_CONFIG)
  │
  ▼
stpd: stpmgr_set_proto_mode(L2_MSTP)
  → Enables MSTP BPDU processing (MSTP_BPDU version 3, DMAC 01:80:c2:00:00:00)
  → CIST (instance 0) begins computing loop-free topology
  │
  ▼ (then user configures MST region + instances)
config spanning-tree mst region-name myregion
config spanning-tree mst revision 1
config spanning-tree mst instance 1 priority 4096
config spanning-tree mst instance 1 vlan add 100,200
  │
  ▼
CONFIG_DB changes:
  STP_MST|GLOBAL           → {"name": "myregion", "revision": "1"}
  STP_MST_INST|1           → {"bridge_priority": "4096", "vlan_list": "100,200"}
  │
  ▼
stpmgrd: doStpMstGlobalTask() → sendMsgStpd(STP_MST_GLOBAL_CONFIG)
stpmgrd: doStpMstInstTask()   → parseVlanList("100,200") → [100,200]
                              → updateVlanInstanceMap(1, [100,200])
                              → sendMsgStpd(STP_MST_INST_CONFIG)
  │
  ▼
stpd: mstpmgr_process_inst_config()
  → Updates mstid_table.vlan_to_mstid[100] = 1, [200] = 1
  → MSTI 1 begins running independent spanning tree for VLANs 100,200
  → port states are per-instance (a port can be FORWARDING for CIST
    but BLOCKING for MSTI 1)

After convergence, stpd calls mstputil_set_port_state() for each port+instance:
  ├─ [KERNEL] mstputil_set_kernel_bridge_port_state()
  │     → /sbin/bridge vlan add/del for ALL VLANs in the instance
  └─ [APPL_DB] stpsync_update_port_state()
       → STP_PORT_STATE_TABLE|Ethernet0:0 → {"state": "4"}   (CIST forwarding)
       → STP_PORT_STATE_TABLE|Ethernet0:1 → {"state": "1"}   (MSTI 1 blocking)
```

### 3. `config spanning-tree vlan add 100` — Enable STP on VLAN 100 (PVST)

```
CLI: config spanning-tree vlan add 100
  │
  ▼
config/stp.py: stp_vlan_enable("100")
  → config_db.set_entry("STP_VLAN", "Vlan100", {"enabled": "true"})
  │
  ▼
CONFIG_DB: STP_VLAN|Vlan100 → {"enabled": "true"}
  │
  ▼
stpmgrd: doStpVlanTask()
  key="Vlan100", op="SET"
  if l2ProtoEnabled == L2_NONE: it++ (wait — STP global not yet configured)

  Once STP global is enabled (pvst):
  → If m_vlanInstMap[100] == INVALID_INSTANCE:
    → allocL2Instance(100)  → uses bitset to find free instance idx
    → getAllVlanMem("Vlan100") → enumerates member ports from STATE_VLAN_MEMBER
    → Builds STP_VLAN_CONFIG_MSG with port_list
    → sendMsgStpd(STP_VLAN_CONFIG, len, msg)
  │
  ▼
stpd: stpmgr_process_vlan_config()
  → Creates STP_CLASS for vlan_id=100
  → Associates all member ports
  → Begins sending BPDUs and running STP algorithm per-VLAN
  │ (topology converges)
  ▼
stpd: stputil_set_port_state() triggered by port_state_selection()
  ├─ [KERNEL] /sbin/bridge vlan add vid 100 dev Ethernet0
  └─ [APPL_DB] STP_PORT_STATE_TABLE|Ethernet0:100 → {"state": "4"}

Also, stpsync writes:
  updateStpVlanInfo()    → APPL_DB STP_VLAN_TABLE   (bridge_id, root_bridge_id, etc.)
  updateVlanPortState()  → APPL_DB STP_VLAN_PORT_TABLE (port state, BPDU stats)
  addVlanToInstance()    → APPL_DB STP_VLAN_INSTANCE_TABLE (Vlan100 → stp_instance)
  │
  ▼
orchagent:
  doStpTask():         Vlan100 → stp_instance=X → addVlanToStpInstance("Vlan100", X)
                         → SAI: set_vlan_attribute(VLAN_ATTR_STP_INSTANCE, stp_oid)
  doStpPortStateTask(): Ethernet0:100 → state=FORWARDING → updateStpPortState(...)
                         → SAI: set_stp_port_attribute(STATE, FORWARDING)
```

## Function-by-Function Breakdown

### stpmgrd (Config Manager)

#### 1. `main()` — Entry Point (`stpmgrd.cpp`)

```cpp
// Watches these CONFIG_DB tables:
cfg_tables = { "STP", "STP_VLAN", "STP_VLAN_PORT", "STP_PORT",
               "STP_MST", "STP_MST_INST", "STP_MST_PORT" }
// Watches these STATE_DB tables:
state_tables = { "VLAN_MEMBER_TABLE" }
// Watches CONFIG_DB for LAG tracking:
{ "LAG_MEMBER_TABLE" }
```

- Connects to CONFIG_DB, APPL_DB, STATE_DB
- Initializes Warm Restart support
- Reads switch MAC from `DEVICE_METADATA` table
- Creates `StpMgr` instance
- Opens AF_UNIX socket bound to `/var/run/stpmgrd.sock`, sends to `/var/run/stpipc.sock`
- Waits for `PortInitDone` in APPL_DB
- Reads `max_stp_inst` from STATE_DB `STP_TABLE|GLOBAL` (written by StpOrch) and sends `STP_INIT_READY` to stpd
- Enters infinite `Select` event loop

#### 2. `StpMgr::StpMgr()` — Constructor

- Initializes all CONFIG_DB and STATE_DB table handles
- Sets `l2ProtoEnabled = L2_NONE`
- Initializes `m_vlanInstMap[MAX_VLANS]` all to `INVALID_INSTANCE`
- Removes any existing ebtables PVST DROP rule: `ebtables -D FORWARD -d 01:00:0c:cc:cc:cd -j DROP`

#### 3. `doTask(Consumer &consumer)` — Task Dispatcher

Routes based on table name:
```
CFG_STP_GLOBAL_TABLE_NAME    → doStpGlobalTask()
CFG_STP_VLAN_TABLE_NAME      → doStpVlanTask()
CFG_STP_VLAN_PORT_TABLE_NAME → doStpVlanPortTask()
CFG_STP_PORT_TABLE_NAME      → doStpPortTask()
CFG_LAG_MEMBER_TABLE_NAME    → doLagMemUpdateTask()
STATE_VLAN_MEMBER_TABLE_NAME → doVlanMemUpdateTask()
"STP_MST"                    → doStpMstGlobalTask()
"STP_MST_INST"               → doStpMstInstTask()
"STP_MST_PORT"               → doStpMstInstPortTask()
```

Note: MST table names are **hardcoded strings**, not constants — the defined
constants `CFG_STP_MST_TABLE_NAME` etc. exist in `cfg_schema.h` but are not used.

#### 4. `doStpGlobalTask()` — Global STP Mode

Handles SET/DEL on `STP|GLOBAL`:

**SET `mode=pvst`:**
- Adds ebtables rule to DROP PVST BPDU MAC (`01:00:0c:cc:cc:cd`) in kernel bridge forward path
- Sets `l2ProtoEnabled = L2_PVSTP`
- Sends `STP_BRIDGE_CONFIG` IPC message to stpd with `mode=L2_PVSTP` + switch MAC

**SET `mode=mst`:**
- Sets `l2ProtoEnabled = L2_MSTP`
- Initializes all VLANs to instance 0 (CIST default): `fill_n(m_vlanInstMap, MAX_VLANS, 0)`
- Sends `STP_BRIDGE_CONFIG` with `mode=L2_MSTP`

**DEL (disable STP):**
- Frees all L2 instances: `FREE_ALL_INST_ID()`
- Resets VLAN→instance map to INVALID_INSTANCE
- Removes ebtables rule (if PVST)
- Sets `l2ProtoEnabled = L2_NONE`

#### 5. `doStpVlanTask()` — STP VLAN Config

Handles SET/DEL on `STP_VLAN|Vlan<id>`:

**SET (`enabled=true`):**
1. Validates STP global is enabled and VLAN exists in STATE_DB
2. PVST: `allocL2Instance(vlan_id)` — finds free bit in `l2InstPool` bitset
3. `getAllVlanMem(key)` — iterates `STATE_VLAN_MEMBER_TABLE` to find all ports in this VLAN
4. Builds `STP_VLAN_CONFIG_MSG` with instance ID, timers, priority, port list
5. Sends `STP_VLAN_CONFIG` IPC message to stpd

**DEL (disable):**
- `deallocL2Instance(vlan_id)` — clears bit in pool, resets VLAN→instance map
- Sends `STP_VLAN_CONFIG` with `opcode=STP_DEL_COMMAND`

#### 6. `doStpPortTask()` — STP Per-Port Config

Handles SET/DEL on `STP_PORT|<port>`:

Processes: `enabled`, `root_guard`, `loop_guard`, `bpdu_guard`, `bpdu_guard_do_disable`,
`path_cost`, `priority`, `portfast`†, `uplink_fast`†, `edge_port`‡, `link_type`‡.

Gathers all VLANs this port belongs to via `getAllPortVlan()` and packs them into
`STP_PORT_CONFIG_MSG` with flexible array member. Sends to stpd.

> † PVST-only. ‡ MSTP-only.

#### 7. `doStpMstInstTask()` — MST Instance Config

Handles SET/DEL on `STP_MST_INST|MST_INSTANCE|<id>`:

**SET:**
- `parseVlanList("22-25,30")` → `[22, 23, 24, 25, 30]` — supports ranges
- `updateVlanInstanceMap(instance_id, vlan_ids, true)` — adds new mappings, removes stale
- Builds `STP_MST_INST_CONFIG_MSG` with VLAN list
- Sends to stpd

**DEL:**
- `updateVlanInstanceMap(instance_id, {}, false)` — resets all VLANs back to instance 0
- Sends `STP_MST_INST_CONFIG` with `opcode=STP_DEL_COMMAND`

#### 8. `doVlanMemUpdateTask()` — VLAN Membership Changes

Monitors `STATE_VLAN_MEMBER_TABLE` changes. When a port is added/removed from
an STP-enabled VLAN, sends `STP_VLAN_MEM_CONFIG` IPC message to stpd.

#### 9. `doLagMemUpdateTask()` — LAG Membership Changes

Tracks LAG member count in `m_lagMap`. When the first member joins a PortChannel,
pushes all accumulated `STP_PORT` + `STP_VLAN_PORT` configs for that PO to stpd.

#### 10. `sendMsgStpd()` — IPC to stpd

Allocates `STP_IPC_MSG` header with `msg_type` + `msg_len`, copies typed payload
into `data[]` flexible array, sends via `sendto()` on AF_UNIX datagram socket to
`/var/run/stpipc.sock`.

#### 11. `allocL2Instance()` / `deallocL2Instance()` — Instance Pool

PVST requires one STP instance per VLAN. The `l2InstPool` bitset tracks which
instance IDs are in use. Default max is 255 (`STP_DEFAULT_MAX_INSTANCES`),
actual limit comes from SAI → StpOrch → STATE_DB → stpmgrd.

#### 12. `getStpMaxInstances()` — Capability Discovery

Polls `STATE_STP_TABLE|GLOBAL` for `max_stp_inst` field. Waits up to 60 seconds,
then falls back to `STP_DEFAULT_MAX_INSTANCES=255`.

---

### stpd Daemon (C Protocol Engine)

#### 13. `stpd_main()` — Daemon Entry (`stp/stp_main.c`)

```
1. stpd_log_init()
2. stpsync_clear_appdb_stp_tables()   # Clear stale state on restart
3. libevent event_base with 50ms max dispatch interval
4. 100ms timer → stptimer_100ms_tick()
5. AF_UNIX socket → /var/run/stpipc.sock (IPC from stpmgrd)
6. AVL tree → g_stpd_intf_db (interface tracking)
7. Netlink socket → interface add/del/state events
8. PF_PACKET socket → BPDU TX (shared tx socket)
9. event_base_dispatch() → infinite event loop
```

#### 14. `stp_pkt_sock_create()` — Per-Port BPDU Socket (`stp/stp_pkt.c`)

Creates one `PF_PACKET` raw socket per physical port:
1. `socket(PF_PACKET, SOCK_RAW, htons(ETH_P_ALL))`
2. `setsockopt(PACKET_AUXDATA)` — to receive VLAN info in ancillary data
3. **BPF filter** (`SO_ATTACH_FILTER`):
   - Match PVST: DMAC = `01:00:0c:cc:cc:cd`
   - Match STP: LLC byte = `0x42` (LSAP_BRIDGE_SPANNING_TREE_PROTOCOL)
   - Reject packets > 1500 bytes
4. `bind()` to specific interface index
5. Registers `stp_pkt_rx_handler()` as libevent callback on `EV_READ|EV_PERSIST`

The ASIC must be configured (via `SAI_HOSTIF_TRAP_TYPE_STP` and
`SAI_HOSTIF_TRAP_TYPE_PVRST`) to punt BPDU frames to the CPU, where they arrive
at the kernel and are captured by stpd's PF_PACKET socket.

#### 15. `stp_pkt_rx_handler()` — BPDU Reception

1. `recvmsg()` with `PACKET_AUXDATA` to get VLAN ID from ancillary data
2. If port is a LAG member: redirect to PortChannel (master) `INTERFACE_NODE`
3. Dispatch by protocol:
   - **PVST**: `stpmgr_process_rx_bpdu(vlan_id, port_id, pkt)` → `stputil_process_bpdu()` → `received_config_bpdu()` or `received_tcn_bpdu()`
   - **MSTP**: check `stpmgr_protect_process()` (BPDU guard), then `mstpmgr_rx_bpdu()` → `mstp_prx_gate()` (Port Receive state machine)
   - For MSTP, `pkt[1] == 128` indicates a TCN via MSTP BPDU (tcAck flag)

#### 16. `stp_pkt_tx_handler()` — BPDU Transmission

Sends BPDU via shared PF_PACKET socket (`g_stpd_pkt_handle`):
1. If tagged VLAN: inserts 802.1Q VLAN header (TPID=0x8100, PCP=7, VID)
2. `sendto()` with `sockaddr_ll` specifying destination interface index

#### 17. Core STP Algorithm (PVST — `stp/stp.c`)

- `config_bpdu_generation()` — builds config BPDU from bridge data
- `root_selection()` — compares received root bridge ID with current
- `designated_port_selection()` — computes if this bridge has the best path to root
- `port_state_selection()` — determines new port state based on role
- `make_forwarding()` / `make_blocking()` — transitions port state with timer delays

#### 18. `stputil_set_port_state()` — Dual Enforcement Trigger (PVST)

```c
// stp_util.c:186-191
bool stputil_set_port_state(STP_CLASS *stp_class, STP_PORT_CLASS *stp_port_class) {
    stputil_set_kernel_bridge_port_state(stp_class, stp_port_class);  // KERNEL
    stpsync_update_port_state(ifname, instance, state);              // ASIC (via APPL_DB)
    return true;
}
```

#### 19. `stputil_set_kernel_bridge_port_state()` — Kernel Enforcement (PVST)

```c
// stp_util.c:143-178
// FORWARDING: /sbin/bridge vlan add vid N dev port [untagged|tagged]
// !FORWARDING: /sbin/bridge vlan del vid N dev port [untagged|tagged]
// Tracks kernel_state (FORWARD/BLOCKING) to avoid redundant system() calls
```

#### 20. MSTP State Machines (`mstp/`)

| State Machine | File | Gate Function | Purpose |
|--------------|------|---------------|---------|
| PRX (Port Receive) | `mstp_prx.c` | `mstp_prx_gate()` | Processes received BPDU, updates port info |
| PRS (Port Role Selection) | `mstp_prs.c` | `mstp_prs_gate()` | Computes port role (Root/Designated/Alternate/Backup) |
| PRT (Port Role Transitions) | `mstp_prt.c` | `mstp_prt_gate()` | RSTP proposal/agreement handshake, sync, reroot → rapid transition |
| PST (Port State Transition) | `mstp_pst.c` | `mstp_pst_gate()` | Transitions port: Discarding → Learning → Forwarding |
| TCM (Topology Change) | `mstp_tcm.c` | `mstp_tcm_gate()` | Detects/prepares topology changes, flushes FDB |
| PIM (Port Information) | `mstp_pim.c` | `mstp_pim_gate()` | Updates port's spanning tree information from received BPDUs |
| PPM (Port Protocol Migration) | `mstp_ppm.c` | `mstp_ppm_gate()` | Detects if neighbor is legacy STP → falls back to STP mode |
| PTX (Port Transmit) | `mstp_ptx.c` | `mstp_ptx_gate()` | Schedules BPDU transmission (periodic, on-change, TCN, RSTP) |

**Execution model**: The 100ms timer tick calls `mstputil_timer_tick()` which ticks
all MSTP state machines. Each state machine has a gate function that checks
preconditions. State changes are saved during a round and processed on the next
tick. Single-threaded, synchronous execution.

#### 21. `mstputil_set_port_state()` — Dual Enforcement Trigger (MSTP)

```c
// mstp_util.c:1036-1096
bool mstputil_set_port_state(MSTP_INDEX mstp_index, PORT_ID port_number, L2_PORT_STATE state) {
    // ... validation, CIST/MSTI detection ...
    mstputil_set_kernel_bridge_port_state(mstp_index, port_number, state);  // KERNEL
    stpsync_update_port_state(ifname, mstp_index, state);                  // ASIC
    return true;
}
```

#### 22. `mstputil_set_kernel_bridge_port_state()` — Kernel Enforcement (MSTP)

Computes VLAN bitmap intersection `port_vlans & instance_vlans`, then for each
affected VLAN:
- FORWARDING: `/sbin/bridge vlan add vid N dev port [untagged|tagged]`
- !FORWARDING: `/sbin/bridge vlan del vid N dev port [untagged|tagged]`

Also has a single-VLAN variant for per-VLAN membership changes.

---

### StpSync (stpd → Redis Bridge)

#### 23. `StpSync` Class (`stpsync/stp_sync.cpp`)

**ALL tables are in APPL_DB** (constructor receives `APPL_DB` DBConnector at line 50-52):

| ProducerStateTable | DB | Key Format | What It Writes |
|-------|----|------------|----------------|
| `m_stpVlanTable` | APPL_DB | `Vlan<id>` | bridge_id, root_bridge_id, root_path_cost, timers, topology_change_count |
| `m_stpVlanPortTable` | APPL_DB | `Vlan<id>:<port>` | port_state, designated_root/bridge, path_cost, BPDU tx/rx stats |
| `m_stpVlanInstanceTable` | APPL_DB | `Vlan<id>` | `stp_instance=<id>` — consumed by StpOrch |
| `m_stpPortStateTable` | APPL_DB | `<port>:<instance>` | `state=<0-4>` — consumed by StpOrch |
| `m_stpFastAgeFlushTable` | APPL_DB | `Vlan<id>` | `state=true` — triggers FDB flush |
| `m_stpInstancePortFlushTable` | APPL_DB | `<instance>:<port>` | MST instance-level flush trigger |
| `m_stpMstTable` | APPL_DB | `<mst_id>` | bridge_id, root_bridge_id, regional_root, vlan_mask |
| `m_stpMstPortTable` | APPL_DB | `<mst_id>:<port>` | port_state, port_role, designated_root/bridge, BPDU stats |
| `m_stpPortTable` | APPL_DB | `<port>` | bpdu_guard_shutdown, port_fast, mst_boundary |
| `m_cfgPortTable` | **CONFIG_DB** | `<port>` | `admin_status` (set on BPDU guard shutdown) |
| `m_cfgLagTable` | **CONFIG_DB** | `<port>` | `admin_status` (set on BPDU guard shutdown for LAG) |

The `show spanning-tree` CLI reads from APPL_DB, not STATE_DB.

#### 24. `stpsync_clear_appdb_stp_tables()` — Warm Restart Cleanup

Clears stale APPL_DB entries on stpd startup:
```cpp
m_stpVlanTable.clear();
m_stpVlanPortTable.clear();
// m_stpVlanInstanceTable.clear();  // INTENTIONALLY COMMENTED OUT — preserved
m_stpPortTable.clear();
// m_stpPortStateTable.clear();     // INTENTIONALLY COMMENTED OUT — preserved
m_stpFastAgeFlushTable.clear();
```

VLAN→instance mapping and port state tables are NOT cleared — they survive warm
restart to avoid topology disruption.

---

### Orchagent (StpOrch)

#### 25. `StpOrch::StpOrch()` — Constructor (`stporch.cpp`)

Queries SAI switch for:
- `SAI_SWITCH_ATTR_DEFAULT_STP_INST_ID` → `m_defaultStpId` (used when removing VLAN from STP)
- `SAI_SWITCH_ATTR_MAX_STP_INSTANCE` → `m_maxStpInstance` (published to STATE_DB `STP_TABLE|GLOBAL`)

#### 26. `doTask(Consumer &consumer)` — Task Dispatcher

```
APP_STP_VLAN_INSTANCE_TABLE_NAME   → doStpTask()
APP_STP_PORT_STATE_TABLE_NAME      → doStpPortStateTask()
APP_STP_FASTAGEING_FLUSH_TABLE_NAME → doStpFastageTask()
APP_STP_INST_PORT_FLUSH_TABLE_NAME  → doMstInstPortFlushTask()
```

Guards behind `gPortsOrch->allPortsReady()`.

#### 27. `addVlanToStpInstance()` — VLAN → STP Instance

```
1. Looks up VLAN Port from gPortsOrch
2. getStpInstanceOid(instance) → SAI STP instance OID
   (creates new STP instance via addStpInstance() if needed)
3. sai_vlan_api->set_vlan_attribute(vlan_oid, SAI_VLAN_ATTR_STP_INSTANCE, stp_oid)
4. Updates vlan.m_stp_id and m_vlanAliasToStpInstanceMap
```

#### 28. `updateStpPortState()` — Port STP State

```
1. addStpPort(port, instance) → ensures SAI STP port object exists
   → creates bridge port if needed
   → creates STP port with SAI_STP_PORT_ATTR_STATE=BLOCKING (default init)
2. getStpSaiState(stp_state) → maps internal enum to SAI enum
3. sai_stp_api->set_stp_port_attribute(oid, STATE, sai_state)
```

**State mapping:**
| Internal State | SAI State |
|---------------|-----------|
| DISABLED (0) | `SAI_STP_PORT_STATE_BLOCKING` |
| BLOCKING (1) | `SAI_STP_PORT_STATE_BLOCKING` |
| LISTENING (2) | `SAI_STP_PORT_STATE_BLOCKING` |
| LEARNING (3) | `SAI_STP_PORT_STATE_LEARNING` |
| FORWARDING (4) | `SAI_STP_PORT_STATE_FORWARDING` |

DISABLED, BLOCKING, and LISTENING all map to SAI BLOCKING — the ASIC doesn't
distinguish these three; only LEARNING and FORWARDING have distinct hardware behavior.

#### 29. `stpVlanFdbFlush()` — FDB Flush on Topology Change

Calls `gFdbOrch->flushFdbByVlan(vlan_alias)` — clears the hardware FDB for the
given VLAN so MAC addresses are re-learned on the new topology.

#### 30. `doMstInstPortFlushTask()` — MST Instance Port Flush

When `STP_INST_PORT_FLUSH_TABLE|<instance>:<port>` is SET:
- Looks up all VLAN aliases for the given STP instance from `m_vlanAliasToStpInstanceMap`
- Flushes FDB for each VLAN via `stpVlanFdbFlush()`

## State Machine Overview

### Legacy STP Port States (802.1D)

Defined in `include/l2.h:44-52`:
```
DISABLED(0) → BLOCKING(1) → LISTENING(2) → LEARNING(3) → FORWARDING(4)
```

Managed in `stp/stp.c` via:
- `port_state_selection()` — determines which state each port should be in
- `make_forwarding()` — transitions to FORWARDING after forward_delay timer
- `make_blocking()` — immediately transitions to BLOCKING

### RSTP Port States (802.1w — inside MSTP engine)

RSTP condenses to three states:
```
DISCARDING → LEARNING → FORWARDING
```
(Discarding combines Disabled, Blocking, and Listening)

Implemented in `mstp/mstp_pst.c` (Port State Transition SM). RSTP achieves
sub-second convergence through:
- **Proposal/Agreement handshake** (`mstp/mstp_prt.c`): Point-to-point links negotiate rapid transition without timer delays
- **Edge ports**: Ports configured as `edge_port=true` transition directly to FORWARDING (no timer), revert to normal STP if BPDU received
- **PPM** (`mstp/mstp_ppm.c`): Auto-detects legacy STP neighbors and falls back to slow STP timers

### MSTP Instance Hierarchy

```
CIST (Common and Internal Spanning Tree, mstid=0)
  ├── Controls the overall bridge topology across all regions
  ├── Uses external path cost for inter-region links
  └── One CIST per bridge
MSTI 1..64 (Multiple Spanning Tree Instances)
  ├── Each is an independent spanning tree for a VLAN group
  ├── Uses internal path cost within the region
  └── Up to 64 MSTIs per region (MSTP_MAX_INSTANCES_PER_REGION)
```

**VLAN-to-instance mapping**: `MSTP_CONFIG_TABLE` (4096 entries, indexed by VLAN ID)
stores `mstid` for each VLAN. `MSTP_INDEX_TABLE` maps `mstid` to per-MSTI data structures.

## Intersection with VLAN Pipeline

STP and VLAN management intersect at several points. See also `doc/vlan.md`.

### 1. Shared STATE_DB Subscriber Pattern

Both `vlanmgrd` and `stpmgrd` subscribe to `STATE_VLAN_MEMBER_TABLE`:
- **vlanmgrd**: `doVlanMemberTask()` — creates/removes VLAN members in kernel + APPL_DB
- **stpmgrd**: `doVlanMemUpdateTask()` — notifies stpd when ports join/leave STP-enabled VLANs

This is a **multi-consumer** pattern: both daemons independently react to the same
STATE_DB changes.

### 2. Per-VLAN STP Instance Mapping

PVST creates one STP instance per VLAN. When a new VLAN is created:
1. `vlanmgrd` creates Linux `VlanX` interface + bridge membership
2. If STP is enabled on that VLAN: `stpmgrd` calls `allocL2Instance(vlan_id)`, maps it in `m_vlanInstMap[]`, and sends `STP_VLAN_CONFIG` to stpd
3. stpd begins running STP for that VLAN instance
4. stpsync writes `STP_VLAN_INSTANCE_TABLE|VlanX → {stp_instance: N}` to APPL_DB
5. StpOrch calls `addVlanToStpInstance("VlanX", N)` → SAI `SAI_VLAN_ATTR_STP_INSTANCE`

### 3. Kernel Bridge VLAN Manipulation

When STP blocks a port for a VLAN, the kernel bridge VLAN membership is removed
(`/sbin/bridge vlan del`). When STP unblocks the port, the membership is re-added
(`/sbin/bridge vlan add`). This means:
- `bridge vlan show` output will NOT show the port for blocked VLANs
- vlanmgrd has already added the port to the bridge (via `addHostVlanMember()`),
  but STP may have removed the VLAN membership
- If STP is disabled, the port's full VLAN membership must be restored
  (this happens during STP disable via `stputil_*` functions)

### 4. Port State → VLAN Forwarding

A port's STP state affects ALL VLANs in the same instance:
- `STP_PORT_STATE_TABLE|Ethernet0:0` with `state=BLOCKING` means the port is blocked
  for all VLANs in instance 0 (CIST in MSTP)
- `STP_PORT_STATE_TABLE|Ethernet0:1` with `state=FORWARDING` means the port forwards
  for VLANs in MSTI 1

In PVST (one instance per VLAN), the per-instance state IS the per-VLAN state.

### 5. FDB Flush on Topology Change

When STP topology changes:
1. stpd detects TCN (Topology Change Notification)
2. stpsync writes `STP_FASTAGEING_FLUSH_TABLE|VlanX → {state: true}` to APPL_DB
3. StpOrch calls `gFdbOrch->flushFdbByVlan("VlanX")`
4. Hardware FDB entries for that VLAN are flushed, forcing MAC re-learning

### 6. LAG (PortChannel) Interaction

- **BPDU TX**: Single shared PF_PACKET socket (`g_stpd_pkt_handle`) with kernel
  bonding driver handling member selection
- **BPDU RX**: BPDUs arrive on member ports; `stp_pkt_rx_handler()` detects
  `master_ifindex` and redirects to PortChannel's `INTERFACE_NODE`
- **LAG member join**: `doLagMemUpdateTask()` pushes accumulated STP config when
  the first member joins; `stp_intf_add_po_member()` allocates port ID when
  `g_stpd_port_init_done` is true
- **Port-ID non-determinism**: PortChannels get dynamic port IDs from a bitset
  pool. Configure explicit port priority as a tiebreaker to ensure consistent
  STP topology across reboots.

### 7. Warm Restart Ordering

```
docker-stp (WARM_SHUTDOWN_BEFORE = swss)
  → stops FIRST
  → removes STP configuration from ASIC
swss
  → stops SECOND
  → final state cleanup
```

This prevents a scenario where swss restarts with stale STP state still in the ASIC.

## Key Design Patterns

### Dual IPC + DB Sync (3-hop config path)

Unlike vlanmgrd which directly writes to both Linux kernel and APPL_DB, the STP
pipeline has an intermediate protocol engine:

```
CONFIG_DB → stpmgrd (C++) → IPC → stpd (C engine) → stpsync (C++) → APPL_DB
                                                      └→ /sbin/bridge (kernel)
```

This separation exists because:
1. **Protocol complexity**: STP requires a long-running stateful protocol engine
   (timers, state machines, BPDU processing), not just fire-and-forget config
2. **Performance**: The C engine processes BPDUs in real-time with sub-100ms timers;
   it can't block on Redis I/O for every state change
3. **Computed output**: stpsync writes the **computed** topology results (port states,
   root bridge info), not just the input config

### Dual Enforcement (Kernel + ASIC)

stpd enforces STP port state in TWO places from a single function call:
1. **Kernel bridge**: `/sbin/bridge vlan add/del` — prevents kernel forwarding
2. **ASIC**: `APPL_DB → StpOrch → SAI` — prevents hardware forwarding

Both paths are triggered synchronously but operate independently. They can
diverge if either path fails. The kernel path is critical for sonic-vs (virtual
switch) where the kernel IS the data plane.

### Instance Pool Management (PVST)

PVST requires one STP instance per VLAN. `stpmgrd` manages a `bitset<4096>` pool:
- `allocL2Instance(vlan_id)`: finds first free bit, sets `m_vlanInstMap[vlan_id] = idx`
- `deallocL2Instance(vlan_id)`: clears the bit, resets map entry to INVALID_INSTANCE
- `IS_INST_ID_AVAILABLE()`: checks `l2InstPool.count() < max_stp_instances`

MSTP doesn't use this pool — VLANs are mapped to explicit instance IDs.

### Port-ID Allocation (Deterministic Ethernet, Non-Deterministic PO)

- **Ethernet**: port ID = interface number extracted from name (`Ethernet0` → 0). Deterministic.
- **PortChannel**: port ID = first free bit in bitset pool. Non-deterministic across reboots.
- **Mitigation**: Always configure explicit port priority on PortChannels for tiebreak consistency.

### Warm Restart

During warm restart (docker-stp restart):
- stpmgrd: `WarmStart::initialize("stpmgrd", "stpd")` + `WarmStart::checkWarmStart(...)`
- stpd: `stpsync_clear_appdb_stp_tables()` clears most APPL_DB state but **preserves**
  `STP_VLAN_INSTANCE_TABLE` and `STP_PORT_STATE_TABLE` (lines commented out intentionally)
- Existing CONFIG_DB entries are replayed to stpd
- Port states converge back to correct values before orchagent sees outdated state

## Build & Deployment

### Recipe (`rules/sonic-stp.mk`)

- Package: `stp_1.0.0_$(CONFIGURED_ARCH).deb`
- Build: standard `dpkg-buildpackage` (GNU Autotools: `configure.ac` + `Makefile.am`)
- Depends on: `libswsscommon-dev`, `libhiredis`, `libnl`, `libevent`, `libcrypto`
- Links: `libstp.a` (all C STP/MSTP code) + `libcommonstp.a` (avl, bitmap, applog) + stpsync (C++) → `stpd` binary

### Docker Image (`rules/docker-stp.mk`)

- Based on: `docker-config-engine-trixie`
- Packages: `stp` (stpd, stpctl), `swss` (stpmgrd + StpOrch), `sonic-rsyslog-plugin`
- Capabilities: `NET_ADMIN`, `SYS_ADMIN` (for PF_PACKET raw sockets + netlink)
- Startup order: `start.sh` → rsyslogd → stpd → stpmgrd
- Critical processes: `stpd`, `stpmgrd`
- Shutdown: warm-shutdown **before** swss (`_WARM_SHUTDOWN_BEFORE = swss`)

### Enable/Disable

Controlled by `INCLUDE_STP=y` in build config (`slave.mk`). The docker-stp image
is only built when STP is included. Not all platforms include STP — it's an optional
feature like DHCP relay or linkmgrd.

# Orchagent — SONiC Orchestration Agent

> *Generated from source analysis of `src/sonic-swss/orchagent/` and SONiC architecture documentation. All claims cite specific file/class locations.*

---

## 1. What Orchagent Is

**Orchagent** (`orchagent`) is the central state-translation engine in the SONiC Switch State Service (SwSS) layer. It is a single long-running daemon process that subscribes to Redis-based state databases (APPL_DB, CONFIG_DB, STATE_DB), translates high-level network intent into low-level Switch Abstraction Interface (SAI) object calls, and writes those calls into ASIC_DB — the Redis database that `syncd` reads to program the ASIC hardware.

In the SONiC architecture, orchagent sits **between** the northbound configuration/application layer and the southbound SAI/hardware layer:

```
Northbound apps (BGP, LLDP, SNMP, ...)
          │
    ┌─────▼──────┐
    │   Redis     │  APPL_DB, CONFIG_DB, STATE_DB
    │   (redis-   │
    │   server)   │
    └─────┬──────┘
          │ subscribe (ConsumerTable / NotificationConsumer)
    ┌─────▼──────┐
    │  orchagent  │  ← THIS PROCESS (inside swss Docker container)
    │  (orchagent │
    │   daemon)   │
    └─────┬──────┘
          │ write via sairedis API
    ┌─────▼──────┐
    │   ASIC_DB   │  Redis DB
    └─────┬──────┘
          │ subscribe
    ┌─────▼──────┐
    │   syncd     │  (inside syncd Docker container)
    └─────┬──────┘
          │ SAI API calls
    ┌─────▼──────┐
    │   ASIC /    │
    │   Hardware  │
    └────────────┘
```

**Key architectural points:**

- Orchagent does **not** talk directly to the ASIC SDK. It writes structured state into ASIC_DB; syncd reads it and invokes SAI APIs. — *`orchagent/main.cpp:647` — DBConnector `APPL_DB`, `CONFIG_DB`, `STATE_DB`; `orchagent/main.cpp:617-618` — `initSaiApi()` + `initSaiRedis()`*
- Orchagent runs inside the **`swss`** Docker container alongside other daemons (portsyncd, neighsyncd, fpmsyncd, teamsyncd, intfmgrd, vlanmgrd, etc.). — *SONiC Architecture Wiki*
- Orchagent communicates with Redis via Consumer/Producer patterns using the `swsscommon` library (`ConsumerTable`, `ConsumerStateTable`, `NotificationConsumer`, `ProducerStateTable`). — *`orchagent/orch.h:18-21`*

---

## 2. Why SONiC Needs Orchagent

SONiC adopted a Redis-based publish/subscribe architecture to decouple northbound protocol agents from southbound ASIC programming. This creates a problem: **who translates abstract network intent into concrete SAI objects?**

Orchagent solves several problems:

1. **Intent → ASIC translation**: Northbound agents write high-level state like "add route 10.0.0.0/8 via 192.168.1.1" into APPL_DB. Orchagent reads this, resolves dependencies (port objects, neighbor objects, VRFs), and emits the equivalent `sai_route_entry_t` creation calls into ASIC_DB. — *`orchagent/routeorch.h` — `RouteOrch` class, subscribing to `APP_ROUTE_TABLE_NAME`*

2. **Orchestration / dependency ordering**: Network state is interdependent (you can't install a route before the egress port exists, or a neighbor before the router interface). Orchagent tracks these dependencies via a **retry mechanism** (`m_toSync` and `RetryCache`), deferring tasks whose prerequisites haven't been satisfied yet and retrying them later. — *`orchagent/orch.h:92` — `SyncMap m_toSync`; `orchagent/orch.h:366` — `RetryCacheMap m_retryCaches`*

3. **State reconciliation**: During warm reboot, orchagent reads existing state from Redis (the "golden" pre-reboot state), reconciles it with fresh data from northbound agents, and emits only the delta to ASIC_DB, avoiding a full ASIC reprogram during restart. — *`orchagent/orchdaemon.cpp:1136-1213` — `warmRestoreAndSyncUp()`*

4. **Single writer to ASIC_DB**: Multiple daemons produce network state, but only orchagent writes to ASIC_DB, ensuring serialized, consistent ASIC programming. — *SONiC Architecture Wiki*

5. **Hardware event propagation**: When the ASIC raises events (port state changes, FDB learns, MACsec POST status), syncd writes them to ASIC_DB. Orchagent reads them from notification channels and propagates the state to APPL_DB and STATE_DB for consumption by other applications. — *`orchagent/main.cpp:671-673` — `SAI_SWITCH_ATTR_PORT_STATE_CHANGE_NOTIFY` callback registered*

---

## 3. Jobs and Responsibilities

### 3.1 Main Event Loop

Orchagent is a single-threaded `select()`-based event loop (with an optional ring-buffer thread for batching).

```
orchagent/main.cpp:1044
  orchDaemon->start(heartBeatInterval)
    └── orchagent/orchdaemon.cpp:973  OrchDaemon::start()
          while (true):
            m_select->select(&s, SELECT_TIMEOUT)    ← wait on fd events
              ↓ (event on Redis consumer fd)
            Executor::execute()                     ← pop Redis data, add to m_toSync
              ↓
            Consumer::drain()
              └── Orch::doTask(Consumer&)           ← subclass-specific processing (SAI calls)
              ↓
            Orch::doTask()                          ← periodic: retry cached tasks, drain all consumers
              ↓
            flush()                                 ← flush sairedis pipeline to ASIC_DB
```

**Key sources:** — *`orchagent/orchdaemon.cpp:973-1130` — `OrchDaemon::start()`; `orchagent/orch.cpp:919-955` — `Orch::doTask()`; `orchagent/orch.cpp:561-576` — `Consumer::execute()`*

### 3.2 Table Observers (Consumers)

Each `Orch` subclass registers one or more **Consumers** — objects that subscribe to specific Redis table keyspaces. When data changes in those tables, the consumer's file descriptor becomes readable, triggering `execute()` which pops the key/operation/value tuples and stores them in `m_toSync`.

There are three consumer variants:
- **`Consumer`** (`ConsumerTable`) — standard pub/sub for SET/DEL operations on Redis hash tables. — *`orchagent/orch.h:239-270`*
- **`NotificationConsumer`** — subscribes to Redis notification channels (e.g., `NOTIFICATIONS` DB) for ASIC-initiated events (FDB learns, port state changes). — *`orchagent/orch.h:21`*
- **`ZmqConsumer`** — receives data over ZeroMQ IPC for gRPC-based route injection. — *`orchagent/zmqorch.h:9`*

**Source:** — *`orchagent/orch.h:287-415` — class `Orch` managing `ConsumerMap m_consumerMap`*

### 3.3 ASIC Programming

After a consumer drains its `m_toSync` queue, `Orch::doTask(Consumer&)` (overridden by each subclass) processes each task. Most subclasses follow this pattern:

```
doTask(Consumer& consumer):
  for each key/op/values in m_toSync:
    if op == SET_COMMAND:
      parse fields → create/update SAI object via sairedis API
    if op == DEL_COMMAND:
      find SAI object ID → destroy SAI object via sairedis API
  if SAI call succeeds:
    remove from m_toSync
  else:
    keep in m_toSync for retry
```

SAI calls go through the **sairodis** library, which serializes them into Redis operations on ASIC_DB. The actual SAI API is invoked later by syncd. — *`orchagent/orchdaemon.cpp:925-956` — `OrchDaemon::flush()` flushing the sairedis pipeline*

### 3.4 State Reconciliation (Warm Boot)

During warm reboot, orchagent enters a special restore sequence:

1. **`bake()`**: Each Orch reads existing APP_DB data into its consumers' `m_toSync` queues. — *`orchagent/orchdaemon.cpp:1144` — `o->bake()`*
2. **Three `doTask()` iterations**: Process the baked state to reconstruct internal data structures and SAI object references. — *`orchagent/orchdaemon.cpp:1162-1175`*
3. **`syncd_apply_view()`**: Notify syncd to apply the accumulated ASIC_DB state. — *`orchagent/orchdaemon.cpp:1200`; `orchagent/main.cpp:188-203` — `syncd_apply_view()`*
4. **`onWarmBootEnd()`**: Each Orch performs post-restore cleanup (capability queries, STATE_DB updates). — *`orchagent/orchdaemon.cpp:1202-1205`*

**Source:** — *`orchagent/orchdaemon.cpp:1136-1213` — `warmRestoreAndSyncUp()`*

### 3.5 Heartbeat

Orchagent emits periodic heartbeat messages to stdout (`<!--XSUPERVISOR:BEGIN-->heartbeat<!--XSUPERVISOR:END-->`) to prevent supervisor from flagging it as stuck. — *`orchagent/orchdaemon.cpp:1293-1309` — `OrchDaemon::heartBeat()`*

---

## 4. Container/Process Communication Map

| Container / Process | Role | Communicates With Orchagent Via | Direction |
|---|---|---|---|
| **swss** (orchagent itself) | Runs orchagent | N/A (orchestration daemon) | N/A |
| **swss** (portsyncd, intfsyncd, neighsyncd, fpmsyncd, teamsyncd, lldp_syncd, vlanmgrd, intfmgrd, nbrmgrd, vrfmgrd, etc.) | Write network state into ApplDB | APPL_DB (Redis keyspace — orchagent subscribes via ConsumerTable) | NB → orchagent |
| **swss** (config mgmt daemons: cfgmgrd, etc.) | Apply persisted configuration | CONFIG_DB (Redis keyspace) | NB → orchagent |
| **redis-server** | In-memory data store | Redis protocol (TCP/unix socket) — orchagent acts as both subscriber and publisher | Bidirectional |
| **syncd** (syncd Docker container) | Reads ASIC_DB, calls SAI API, publishes ASIC events | ASIC_DB (Redis keyspace — orchagent writes via sairedis) + NOTIFICATIONS DB (orchagent subscribes to events) | orchagent → ASIC_DB → syncd (southbound); syncd → NOTIFICATIONS → orchagent (notifications) |
| **fpmsyncd / bgp docker** | BGP route injection via gRPC | ZMQ (ZeroMQ IPC socket `ipc:///zmq_swss/...`) — through `ZmqRouteOrch` / `ZmqServer` | NB → orchagent (optional fast path) |
| **gNMI / telemetry** | Streaming telemetry subscriptions | ZMQ (ZeroMQ IPC) — through `ZmqOrch` subclasses (DASH, P4RT) | NB → orchagent (optional fast path) |

**Sources:**
- `orchagent/main.cpp:645-648` — Database connectors: `APPL_DB`, `CONFIG_DB`, `STATE_DB`
- `orchagent/main.cpp:650-658` — ZMQ server initialization
- `orchagent/orchdaemon.cpp:207-224` — `SwitchOrch` subscribing to `CONFIG_DB`, `APPL_DB`, `STATE_DB` tables
- `orchagent/orchdaemon.cpp:365-366` — RouteOrch ZMQ channel for fpmsyncd
- SONiC Architecture Wiki

---

## 5. Orch Sub-Processes (Orch Classes)

Every Orch class runs **within the same orchagent process** — they are not separate processes. They share the same event loop, coordinated by `OrchDaemon::start()` which calls `doTask()` on each in order.

The table below lists every Orch class identified from source, one row per major class.

### 5.1 Core Network Orch Classes

| Orch Class | File | Base Classes | Responsibility | Subscribed Tables |
|---|---|---|---|---|
| **SwitchOrch** | `orchagent/switchorch.h` | `Orch` | Manages global switch attributes: hash algorithms, warm reboot readiness, ACL capability probing, temperature sensors, FDB aging timers, PFC DLR init, ordered ECMP, ASIC SDK health events | `SWITCH_TABLE` (APP_DB), `SWITCH_HASH_TABLE` (CONFIG_DB), `SWITCH_TRIMMING_TABLE` (CONFIG_DB), `RESTART_CHECK_NOTIF` (ASIC_DB) |
| **PortsOrch** | `orchagent/portsorch.h` | `Orch`, `Subject` | Core port management: physical ports, VLANs, LAGs, bridge ports, system ports. Handles port init, admin/oper status, speed/FEC/MTU, VLAN members, ACL table group bindings, and all port/queue flex counters | `PORT_TABLE`, `VLAN_TABLE`, `VLAN_MEMBER_TABLE`, `LAG_TABLE`, `LAG_MEMBER_TABLE` (APP_DB) |
| **IntfsOrch** | `orchagent/intfsorch.h` | `Orch` | Manages router interfaces (RIFs): IP prefix configuration, MTU, MAC, VLAN flooding control, proxy ARP, directed broadcast, loopback, and VRF-to-interface assignment | `INTF_TABLE` (APP_DB), `SAG_TABLE` (APP_DB) |
| **NeighOrch** | `orchagent/neighorch.h` | `Orch`, `Subject`, `Observer` | Manages IPv4/IPv6 neighbor entries and next-hop SAI objects. Resolves neighbors (MAC lookup via FDB), creates next-hop objects, interacts with VOQ encapsulation indices, BFD-triggered NH updates | `NEIGH_TABLE` (APP_DB) |
| **RouteOrch** | `orchagent/routeorch.h` | `ZmqRouteOrch`, `Subject` | Central routing orchestrator. Manages IPv4/IPv6 unicast routes, MPLS label routes, ECMP next-hop groups, default route NH swapping, VIP subnet decap terms, SRv6 route programming, and route state publishing | `ROUTE_TABLE`, `LABEL_ROUTE_TABLE` (APP_DB), plus ZMQ (gRPC) |
| **NhgOrch** | `orchagent/nhgorch.h` | `NhgOrchCommon<NextHopGroup>` | Manages L3 next-hop groups (ECMP groups): creates/deletes NHG SAI objects, validates member next-hops, handles NHG-member add/remove, notifies RouteOrch on member invalidation | `NEXTHOP_GROUP_TABLE` (APP_DB) |
| **FdbOrch** | `orchagent/fdborch.h` | `Orch`, `Subject`, `Observer` | Manages the Forwarding Database (FDB / MAC table): dynamic MAC learning, static FDB entries, VXLAN-advertised remote MACs, MAC flush on topology change, MAC move detection/guarding | `FDB_TABLE`, `VXLAN_FDB_TABLE`, `MCLAG_FDB_TABLE` (APP_DB), plus ASIC FDB event notifications |
| **FgNhgOrch** | `orchagent/fgnhgorch.h` | `Orch`, `Observer` | Manages fine-grained next-hop groups with bank-based bucketing for advanced ECMP weight distribution | `FG_NHG`, `FG_NHG_PREFIX`, `FG_NHG_MEMBER` (CONFIG_DB → APP_DB) |
| **CbfNhgOrch** | `orchagent/cbf/cbfnhgorch.h` | `NhgOrchCommon<CbfNhg>` | Manages class-based forwarding NHGs: maps forwarding classes to NHG indices for per-class traffic steering | `CLASS_BASED_NEXT_HOP_GROUP_TABLE` (APP_DB) |
| **NhgMapOrch** | `orchagent/cbf/nhgmaporch.h` | `Orch` | Manages FC-to-NHG-index mapping tables for CBF | `FC_TO_NHG_INDEX_MAP_TABLE` (APP_DB) |
| **L2NhgOrch** | `orchagent/l2nhgorch.h` | `NhgOrchCommon<NextHopGroup>` | Manages L2 next-hop groups for VTEP tunnel endpoint resolution | `L2_NEXTHOP_GROUP_TABLE` (APP_DB) |

### 5.2 L2 / Overlay / Tunnel Orch Classes

| Orch Class | File | Base Classes | Responsibility | Subscribed Tables |
|---|---|---|---|---|
| **VxlanTunnelOrch** | `orchagent/vxlanorch.h` | `Orch2` | Manages VXLAN tunnels: create/delete tunnels (P2P and P2MP), tunnel termination, encap/decap mappers (VLAN, bridge, VRF), tunnel port lifecycle | `VXLAN_TUNNEL_TABLE` (APP_DB) |
| **VxlanTunnelMapOrch** | `orchagent/vxlanorch.h` | `Orch2` | Maps VNI to VLAN ID for VXLAN tunnel encapsulation | `VXLAN_TUNNEL_MAP_TABLE` (APP_DB) |
| **VxlanVrfMapOrch** | `orchagent/vxlanorch.h` | `Orch2` | Maps VNI to VRF for VXLAN L3 overlay routing | `VXLAN_VRF_TABLE` (APP_DB) |
| **EvpnNvoOrch** | `orchagent/vxlanorch.h` | `Orch2` | Manages EVPN NVO (Network Virtualization Overlay) source-VTEP bindings | `VXLAN_EVPN_NVO_TABLE` (APP_DB) |
| **EvpnRemoteVnip2pOrch** | `orchagent/vxlanorch.h` | `Orch2` | Manages EVPN remote VNI P2P (point-to-point DIP tunnel) entries | `VXLAN_REMOTE_VNI_TABLE` (APP_DB) |
| **EvpnRemoteVnip2mpOrch** | `orchagent/vxlanorch.h` | `Orch2` | Manages EVPN remote VNI P2MP (point-to-multipoint / SIP tunnel) entries | `VXLAN_REMOTE_VNI_TABLE` (APP_DB) |
| **TunnelDecapOrch** | `orchagent/tunneldecaporch.h` | `Orch` | Manages IP-in-IP tunnel decapsulation: create/delete decap tunnels and termination entries, subnet decap configuration | `TUNNEL_DECAP_TABLE`, `TUNNEL_DECAP_TERM_TABLE` (APP_DB) |
| **NvgreTunnelOrch** | `orchagent/nvgreorch.h` | `Orch2` | Manages NVGRE tunnel creation/deletion | `NVGRE_TUNNEL_TABLE` (CONFIG_DB) |
| **NvgreTunnelMapOrch** | `orchagent/nvgreorch.h` | `Orch2` | Maps NVGRE VSID to VLAN ID | `NVGRE_TUNNEL_MAP_TABLE` (CONFIG_DB) |
| **MuxOrch** | `orchagent/muxorch.h` | `Orch2`, `Observer`, `Subject` | Manages server-to-ToR MUX cable state machines (active/standby), installs neighbor-to-tunnel ACLs for failover, manages peer-switch coordination | `MUX_CABLE_TABLE`, `PEER_SWITCH_TABLE` (CONFIG_DB) |
| **MuxCableOrch** | `orchagent/muxorch.h` | `Orch2` | Per-port MUX cable state management from APP_DB | `MUX_CABLE_TABLE` (APP_DB) |
| **MuxStateOrch** | `orchagent/muxorch.h` | `Orch2` | Per-port MUX hardware state tracking from STATE_DB | `HW_MUX_CABLE_TABLE` (STATE_DB) |
| **MlagOrch** | `orchagent/mlagorch.h` | `Orch`, `Observer`, `Subject` | Manages multi-chassis LAG (MLAG) domain configuration, ISL interfaces, and MLAG member ports | `MCLAG_TABLE`, `MCLAG_INTF_TABLE` (CONFIG_DB) |
| **EvpnMhOrch** | `orchagent/evpnmhorch.h` | `Orch` | Manages EVPN multi-homing: Ethernet Segment (ES) and Designated Forwarder (DF) election state | `EVPN_DF_TABLE` (APP_DB), `EVPN_ETHERNET_SEGMENT` (CONFIG_DB) |
| **IsoGrpOrch** | `orchagent/isolationgrouporch.h` | `Orch`, `Observer` | Manages isolation groups that restrict ingress flooding between member ports (port-level or bridge-port-level) | `ISOLATION_GROUP_TABLE` (APP_DB) |
| **ShlOrch** | `orchagent/shlorch.h` | `Orch`, `Observer` | Manages switch-hardware-isolation groups for VTEP IP-based segmentation between tunnel and access bridge ports | `EVPN_SPLIT_HORIZON_TABLE` (APP_DB) |
| **StpOrch** | `orchagent/stporch.h` | `Orch` | Manages Spanning Tree Protocol: STP instances, port STP states, VLAN-to-instance membership, STP-triggered FDB flush | `STP_VLAN_INSTANCE_TABLE`, `STP_PORT_STATE_TABLE`, `STP_FASTAGEING_FLUSH_TABLE`, `STP_INST_PORT_FLUSH_TABLE` (APP_DB) |

### 5.3 QoS / Buffer / ACL / Mirror Orch Classes

| Orch Class | File | Base Classes | Responsibility | Subscribed Tables |
|---|---|---|---|---|
| **BufferOrch** | `orchagent/bufferorch.h` | `Orch` | Manages switch buffer configuration: buffer pools, profiles, per-port queue/PG buffer properties with bulk operation support | `BUFFER_POOL_TABLE`, `BUFFER_PROFILE_TABLE`, `BUFFER_QUEUE_TABLE`, `BUFFER_PG_TABLE`, `BUFFER_PORT_INGRESS_PROFILE_LIST`, `BUFFER_PORT_EGRESS_PROFILE_LIST` (APP_DB) |
| **QosOrch** | `orchagent/qosorch.h` | `Orch` | Manages QoS maps and handlers: DSCP→TC, MPLS TC→TC, Dot1p→TC, TC→Queue, TC→PG, PFC→Queue, WRED profiles, scheduler config, TC→DSCP, TC→Dot1p, and port/queue QoS associations | `DSCP_TO_TC_MAP`, `MPLS_TC_TO_TC_MAP`, `DOT1P_TO_TC_MAP`, `TC_TO_QUEUE_MAP`, `TC_TO_PG_MAP`, `PFC_TO_PG_MAP`, `PFC_TO_QUEUE_MAP`, `WRED_PROFILE`, `SCHEDULER`, `QUEUE`, `PORT_QOS_MAP`, `DSCP_TO_FC_MAP`, `EXP_TO_FC_MAP`, `TC_TO_DSCP_MAP`, `TC_TO_DOT1P_MAP` (CONFIG_DB/APP_DB) |
| **AclOrch** | `orchagent/aclorch.h` | `Orch`, `Observer` | Central ACL orchestrator: manages ACL table types, ACL tables (create/bind/unbind), ACL rules across ingress/egress stages (packet filtering, mirroring, DTel monitoring, DSCP rewrite, inner-source-MAC rewrite), and ACL counters | `ACL_TABLE`, `ACL_RULE`, `ACL_TABLE_TYPE` (both CONFIG_DB and APP_DB) |
| **PbhOrch** | `orchagent/pbhorch.h` | `Orch` | Manages Policy-Based Hashing: PBH tables, rules, hash objects, hash fields; attaches ACL entries to ports for flow-specific hash behavior | `PBH_TABLE`, `PBH_RULE`, `PBH_HASH`, `PBH_HASH_FIELD` (CONFIG_DB) |
| **MirrorOrch** | `orchagent/mirrororch.h` | `Orch`, `Observer`, `Subject` | Manages port mirroring sessions (SPAN/ERSPAN): session create/delete, port binding, nexthop/neighbor resolution, sampled mirroring (sFlow-style), sampled packet objects | `MIRROR_SESSION_TABLE` (both APP_DB and CONFIG_DB) |
| **PolicerOrch** | `orchagent/policerorch.h` | `Orch` | Manages SAI policers: create/delete policer objects, reference counting, port storm-control policer bindings | `POLICER_TABLE` (CONFIG_DB), `PORT_STORM_CONTROL_TABLE` (CONFIG_DB) |
| **CoppOrch** | `orchagent/copporch.h` | `Orch` | Configures Control Plane Policing (CoPP): trap groups, trap IDs, policers, and generic netlink host interfaces; manages trap counters | `COPP_TABLE` (APP_DB) |
| **PfcWdOrch / PfcWdSwOrch** | `orchagent/pfcwdorch.h` | `Orch` (templated) | PFC watchdog detection: monitors PFC storm counters on ports/queues, applies drop/forward/alert actions when storms detected. Platform-specific handlers (ACL-based, DLR-based, Zero-Buffer, etc.) | `PFC_WD_TABLE` (CONFIG_DB) |

### 5.4 VRF / VNet / NAT / Chassis Orch Classes

| Orch Class | File | Base Classes | Responsibility | Subscribed Tables |
|---|---|---|---|---|
| **VRFOrch** | `orchagent/vrforch.h` | `Orch2` | Manages Virtual Routing and Forwarding (VRF) instances: create/delete VRFs, assign VRF IDs, map VNIs to VRFs, manage L3 VNI VLANs | `VRF_TABLE` (APP_DB) |
| **VNetOrch** | `orchagent/vnetorch.h` | `Orch2` | Manages Virtual Network (VNet) objects: VXLAN tunnel bindings, VNI, peer lists, VRF/bridge-based overlay routing | `VNET_TABLE` (APP_DB) |
| **VNetRouteOrch** | `orchagent/vnetorch.h` | `Orch2`, `Subject`, `Observer` | Manages VNet routes: next-hop groups, BFD/custom monitoring sessions, priority routes (primary/standby), tunnel route prefixes, route advertisement | `VNET_ROUTE_TABLE`, `VNET_ROUTE_TUNNEL_TABLE` (APP_DB) |
| **VNetCfgRouteOrch** | `orchagent/vnetorch.h` | `Orch` | Propagates VNET_ROUTE and VNET_ROUTE_TUNNEL entries from CONFIG_DB to APP_DB | `VNET_ROUTE_TABLE`, `VNET_ROUTE_TUNNEL_TABLE` (CONFIG_DB) |
| **MonitorOrch** | `orchagent/vnetorch.h` | `Orch2` | Manages monitoring session state for VNet routes (custom or BFD) | `VNET_MONITOR_TABLE` (STATE_DB) |
| **BfdMonitorOrch** | `orchagent/vnetorch.h` | `Orch2` | Manages custom BFD session parameters for VNet monitoring | `BFD_SESSION_TABLE` (STATE_DB) |
| **NatOrch** | `orchagent/natorch.h` | `Orch`, `Subject`, `Observer` | Manages SNAT/DNAT, NAPT, Twice-NAT, and Twice-NAPT translation entries with connection tracking timeout and hit-bit queries | `NAT_TABLE`, `NAPT_TABLE`, `NAT_TWICE_TABLE`, `NAPT_TWICE_TABLE`, `NAT_GLOBAL_TABLE`, `NAT_DNAT_POOL_TABLE` (APP_DB) |
| **ChassisOrch** | `orchagent/chassisorch.h` | `Orch`, `Observer` | Manages pass-through route table entries across a distributed chassis; syncs routes when VNet nexthop updates | `PASS_THROUGH_ROUTE_TABLE` (CONFIG_DB) |

### 5.5 Security / MACsec Orch Class

| Orch Class | File | Base Classes | Responsibility | Subscribed Tables |
|---|---|---|---|---|
| **MACsecOrch** | `orchagent/macsecorch.h` | `Orch` | Manages per-port MACsec Security Associations (SA), Secure Channels (SC), ACL tables, flow counters, and PFC interaction for link-layer encryption | `MACSEC_PORT_TABLE`, `MACSEC_INGRESS_SA_TABLE`, `MACSEC_EGRESS_SA_TABLE`, `MACSEC_INGRESS_SC_TABLE`, `MACSEC_EGRESS_SC_TABLE` (APP_DB) |

### 5.6 SRv6 / BFD / ICMP / TWAMP Orch Classes

| Orch Class | File | Base Classes | Responsibility | Subscribed Tables |
|---|---|---|---|---|
| **Srv6Orch** | `orchagent/srv6orch.h` | `Orch`, `Observer` | Manages Segment Routing over IPv6 (SRv6): MySID entries, SID lists, SRv6 tunnels, P2P tunnels, VPN contexts, MySID counters, locator configuration | `SRV6_SID_LIST_TABLE`, `SRV6_MY_SID_TABLE`, `PIC_CONTEXT_TABLE` (APP_DB), `SRV6_MY_SID_TABLE` (CONFIG_DB) |
| **BfdOrch** | `orchagent/bfdorch.h` | `Orch`, `Subject` | Manages Bidirectional Forwarding Detection (BFD) sessions: session create/delete from APP_DB, state notification forwarding | `BFD_SESSION_TABLE` (APP_DB) |
| **BgpGlobalStateOrch** | `orchagent/bfdorch.h` | `Orch` | Monitors BGP global state (TSA status, software BFD offload mode) and bridges to other orchestration layers | `BGP_DEVICE_GLOBAL_TABLE` (CONFIG_DB) |
| **IcmpOrch** | `orchagent/icmporch.h` | `Orch`, `Subject` | Manages hardware-offloaded ICMP echo sessions (ping-like probes), writes SAI ICMP session state back to STATE_DB | `ICMP_ECHO_SESSION_TABLE` (APP_DB) |
| **TwampOrch** | `orchagent/twamporch.h` | `Orch` | Manages TWAMP (Two-Way Active Measurement Protocol) sessions: sender/reflector roles, packet counting, latency/jitter statistics monitoring | `TWAMP_SESSION_TABLE` (CONFIG_DB) |

### 5.7 Monitoring / Telemetry / Statistics Orch Classes

| Orch Class | File | Base Classes | Responsibility | Subscribed Tables |
|---|---|---|---|---|
| **CrmOrch** | `orchagent/crmorch.h` | `Orch` | Critical Resource Monitoring: tracks available vs. used resource counts (routes, next-hops, neighbors, ACL entries, FDB entries, NAT, SRv6, etc.), reports threshold violations | `CRM_TABLE` (CONFIG_DB) |
| **FlexCounterOrch** | `orchagent/flexcounterorch.h` | `Orch` | Coordinates which flex counter groups (port, queue, priority group, watermark, host-interface trap, route flow) are enabled based on device metadata | `FLEX_COUNTER_TABLE`, `DEVICE_METADATA_TABLE` (CONFIG_DB) |
| **FlowCounterRouteOrch** | `orchagent/flex_counter/flowcounterrouteorch.h` | `Orch` | Manages pattern-based flow counter routes: applies route-pattern matching to create flex counter entries for matched flows | `FLOW_COUNTER_ROUTE_PATTERN_TABLE` (CONFIG_DB) |
| **WatermarkOrch** | `orchagent/watermarkorch.h` | `Orch` | Manages queue and priority group watermark telemetry: periodic and persistent watermark clear operations | `WATERMARK_TABLE`, `FLEX_COUNTER_TABLE` (CONFIG_DB) |
| **DebugCounterOrch** | `orchagent/debugcounterorch.h` | `Orch`, `Observer` | Manages debug counters (generic and drop-reason counters); installs/uninstalls flex counters on port updates | `DEBUG_COUNTER_TABLE`, `DEBUG_COUNTER_DROP_REASON_TABLE`, `DEBUG_DROP_MONITOR_TABLE` (CONFIG_DB) |
| **SflowOrch** | `orchagent/sfloworch.h` | `Orch` | Manages sFlow sampling: creates/destroys sample-packet sessions for different sample rates; binds/unbinds ports for ingress/egress packet sampling | `SFLOW_TABLE`, `SFLOW_SESSION_TABLE`, `SFLOW_SAMPLE_RATE_TABLE` (APP_DB) |
| **DTelOrch** | `orchagent/dtelorch.h` | `Orch`, `Subject` | Manages Dataplane Telemetry (DTel/INT): INT sessions, report sessions, queue reports, and event configuration for in-network telemetry | `DTEL_TABLE`, `DTEL_REPORT_SESSION_TABLE`, `DTEL_INT_SESSION_TABLE`, `DTEL_QUEUE_REPORT_TABLE`, `DTEL_EVENT_TABLE` (CONFIG_DB) |
| **HFTelOrch** | `orchagent/high_frequency_telemetry/hftelorch.h` | `Orch` | Manages high-frequency telemetry profiles and groups for real-time counter streaming (platform-dependent; enabled only if HW supports it) | `HIGH_FREQUENCY_TELEMETRY_PROFILE_TABLE`, `HIGH_FREQUENCY_TELEMETRY_GROUP_TABLE` (CONFIG_DB) |
| **CounterCheckOrch** | `orchagent/countercheckorch.h` | `Orch` | Periodically checks multicast queue counters and PFC frame counters against hardware state to detect inconsistencies | None (timer-driven; singleton) |
| **NotificationConsumerStatsOrch** | `orchagent/notificationconsumerstatsorch.h` | `Orch` | Periodically publishes admission and LRU dedup statistics for registered NotificationConsumer instances to COUNTERS_DB | None (timer-driven) |
| **FabricPortsOrch** | `orchagent/fabricportsorch.h` | `Orch`, `Subject` | Manages switch fabric ports: port status monitoring, link isolation, fabric capacity reporting, fabric counter statistics | `FABRIC_PORT_TABLE`, `FABRIC_MONITOR_TABLE` (APP_DB) |

### 5.8 P4 / DASH (Smart Switch / DPU) Orch Classes

| Orch Class | File | Base Classes | Responsibility | Subscribed Tables |
|---|---|---|---|---|
| **P4Orch** | `orchagent/p4orch/p4orch.h` | `ZmqOrch` | Manages P4Runtime-based programmable pipeline: receives P4 table entries via ZMQ (from p4rt/gNMI), translates to SAI objects | `P4RT_TABLE` (APP_DB), plus ZMQ |
| **DashOrch** | `orchagent/dash/dashorch.h` | `ZmqOrch` | Manages DASH (Disaggregated API for SONiC Hosts) appliance, routing type, ENI, ENI route, and QoS table entries | `DASH_APPLIANCE_TABLE`, `DASH_ROUTING_TYPE_TABLE`, `DASH_ENI_TABLE`, `DASH_ENI_ROUTE_TABLE`, `DASH_QOS_TABLE` (APP_DB) |
| **DashVnetOrch** | `orchagent/dash/dashvnetorch.h` | `ZmqOrch` | Manages DASH VNet and VNet-to-VNI mapping tables | `DASH_VNET_TABLE`, `DASH_VNET_MAPPING_TABLE` (APP_DB) |
| **DashRouteOrch** | `orchagent/dash/dashrouteorch.h` | `ZmqOrch` | Manages DASH route, route-rule, and route-group tables | `DASH_ROUTE_TABLE`, `DASH_ROUTE_RULE_TABLE`, `DASH_ROUTE_GROUP_TABLE` (APP_DB) |
| **DashAclOrch** | `orchagent/dash/dashaclorch.h` | `ZmqOrch` | Manages DASH ACL: prefix-tag, ACL-in, ACL-out, ACL-group, and ACL-rule tables | `DASH_PREFIX_TAG_TABLE`, `DASH_ACL_IN_TABLE`, `DASH_ACL_OUT_TABLE`, `DASH_ACL_GROUP_TABLE`, `DASH_ACL_RULE_TABLE` (APP_DB) |
| **DashTunnelOrch** | `orchagent/dash/dashtunnelorch.h` | `ZmqOrch` | Manages DASH tunnel table entries | `DASH_TUNNEL_TABLE` (APP_DB) |
| **DashMeterOrch** | `orchagent/dash/dashmeterorch.h` | `ZmqOrch` | Manages DASH meter policy and meter rule tables | `DASH_METER_POLICY_TABLE`, `DASH_METER_RULE_TABLE` (APP_DB) |
| **DashHaOrch** | `orchagent/dash/dashhaorch.h` | `ZmqOrch` | Manages DASH high-availability: HA set, HA scope, and BFD session state for DPU failover | `DASH_HA_SET_TABLE`, `DASH_HA_SCOPE_TABLE`, `BFD_SESSION_TABLE` (APP_DB) |
| **DashPortMapOrch** | `orchagent/dash/dashportmaporch.h` | `ZmqOrch` | Manages DASH outbound port-map and port-map-range tables | `DASH_OUTBOUND_PORT_MAP_TABLE`, `DASH_OUTBOUND_PORT_MAP_RANGE_TABLE` (APP_DB) |
| **DashHaFlowOrch** | `orchagent/dash/dashhafloworch.h` | `ZmqOrch` | Manages DASH HA flow sync sessions and flow dump filter tables | `DASH_FLOW_SYNC_SESSION_TABLE`, `DASH_FLOW_DUMP_FILTER_TABLE` (APP_DB) |
| **DashEniFwdOrch** | `orchagent/dash/dashenifwdorch.h` | `Orch2`, `Observer` | Manages DASH ENI forwarding context: ENI NH entries, ACL rule integration, and neighbor observation for SmartSwitch DPU interworking | `DASH_ENI_FORWARD` (APP_DB) |

---

## 6. Class Hierarchy Summary

```
Orch  (orch.h:287)
├── Orch2  (orch.h:394) — request-based (addOperation/delOperation)
│   ├── VRFOrch
│   ├── VNetOrch, VNetRouteOrch, MonitorOrch, BfdMonitorOrch
│   ├── VxlanTunnelOrch, VxlanTunnelMapOrch, VxlanVrfMapOrch,
│   │   EvpnRemoteVnip2pOrch, EvpnRemoteVnip2mpOrch, EvpnNvoOrch
│   ├── NvgreTunnelOrch, NvgreTunnelMapOrch
│   ├── MuxOrch, MuxCableOrch, MuxStateOrch
│   └── DashEniFwdOrch
├── ZmqOrch  (zmqorch.h:42) — ZMQ-based (gRPC clients)
│   ├── ZmqRouteOrch  (zmqorch.h:61)
│   │   └── RouteOrch
│   ├── P4Orch
│   └── DashOrch, DashVnetOrch, DashRouteOrch, DashAclOrch,
│       DashTunnelOrch, DashMeterOrch, DashHaOrch,
│       DashPortMapOrch, DashHaFlowOrch
├── NhgOrchCommon<NhgClass>  (nhgbase.h)
│   ├── NhgOrch
│   ├── CbfNhgOrch
│   └── L2NhgOrch
├── PfcWdOrch<DropHandler, ForwardHandler>  (pfcwdorch.h)
│   └── PfcWdSwOrch<DropHandler, ForwardHandler>
├── SwitchOrch
├── PortsOrch (+ Subject)
├── IntfsOrch
├── NeighOrch (+ Subject + Observer)
├── FdbOrch (+ Subject + Observer)
├── FgNhgOrch
├── NhgMapOrch
├── AclOrch (+ Observer)
├── PbhOrch
├── MirrorOrch (+ Observer + Subject)
├── BufferOrch
├── QosOrch
├── PolicerOrch
├── CoppOrch
├── NatOrch (+ Subject + Observer)
├── MlagOrch (+ Observer + Subject)
├── IsoGrpOrch (+ Observer)
├── ShlOrch (+ Observer)
├── EvpnMhOrch
├── MACsecOrch
├── Srv6Orch (+ Observer)
├── BfdOrch (+ Subject)
├── BgpGlobalStateOrch
├── IcmpOrch (+ Subject)
├── BfdMonitorOrch
├── StpOrch
├── ChassisOrch (+ Observer)
├── VNetCfgRouteOrch
├── TunnelDecapOrch
├── CrmOrch
├── FlexCounterOrch
├── FlowCounterRouteOrch
├── WatermarkOrch
├── DebugCounterOrch (+ Observer)
├── SflowOrch
├── DTelOrch (+ Subject)
├── HFTelOrch
├── CounterCheckOrch
├── NotificationConsumerStatsOrch
├── TwampOrch
│   └── FabricPortsOrch (+ Subject)
```

Base classes with `+ Subject` implement the Observer pattern — they notify subscribers when their managed state changes. `+ Observer` classes subscribe to state changes from other Orches.

---

## 7. Construction Order

The order in which Orches are added to `m_orchList` matters — it determines warm-restore iteration order, the queued processing sequence after `allPortsReady()`, and the `doTask()` call order. The order from `orchdaemon.cpp` (lines 533-534, with later `push_back` calls):

```
SwitchOrch → CrmOrch → PortsOrch → EvpnMhOrch → BufferOrch →
FlowCounterRouteOrch → IntfsOrch → NeighOrch → NhgMapOrch →
NhgOrch → CbfNhgOrch → FgNhgOrch → RouteOrch → CoppOrch →
QosOrch → WatermarkOrch → PolicerOrch → TunnelDecapOrch →
SflowOrch → DebugCounterOrch → MACsecOrch → BgpGlobalStateOrch →
BfdOrch → IcmpOrch → Srv6Orch → MuxOrch → MuxCableOrch →
MonitorOrch → BfdMonitorOrch → StpOrch → L2NhgOrch →
NotificationConsumerStatsOrch →
[DtelOrch (platform-dependent)] →
FdbOrch → MirrorOrch → AclOrch → PbhOrch →
ChassisOrch → VRFOrch → VxlanTunnelOrch → EvpnNvoOrch →
VxlanTunnelMapOrch → ShlOrch →
EvpnRemoteVni*Orch → VxlanVrfMapOrch → VNetCfgRouteOrch →
VNetOrch → VNetRouteOrch → NatOrch → MlagOrch → IsoGrpOrch →
MuxStateOrch → NvgreTunnelOrch → NvgreTunnelMapOrch →
[FabricPortsOrch (VOQ only)] → [DashEniFwdOrch (SmartSwitch only)] →
FlexCounterOrch → [PfcWdSwOrch] → CounterCheckOrch →
P4Orch → TwampOrch → [HFTelOrch]
```

**Source:** — *`orchagent/orchdaemon.cpp:533-534`* for the initial list; lines 606-910 for subsequent `push_back` calls.

---

## 8. Key Source Files Reference

| File | Purpose |
|---|---|
| `orchagent/main.cpp` | Entry point: signal handlers, SAI init, switch creation, OrchDaemon construction, `syncd_apply_view()` |
| `orchagent/orchdaemon.h` | `OrchDaemon`, `FabricOrchDaemon`, `DpuOrchDaemon` class declarations |
| `orchagent/orchdaemon.cpp` | All Orch construction/registration, event loop (`start()`), warm-boot restore logic (`warmRestoreAndSyncUp()`) |
| `orchagent/orch.h` | Base `Orch` class, `Consumer`, `Executor`, `RingBuffer`, `Orch2`, `SyncMap`, `RetryCache` |
| `orchagent/orch.cpp` | Base class implementation: `Orch::doTask()`, `Consumer::execute()`, reference resolution helpers, ring buffer logic |
| `orchagent/zmqorch.h` | `ZmqOrch` and `ZmqRouteOrch` base classes for ZMQ/gRPC-driven orchestration |
| `orchagent/portsorch.h` | `PortsOrch`: class declaration and port management APIs |
| `orchagent/routeorch.h` | `RouteOrch`: central routing orchestrator |
| `orchagent/neighorch.h` | `NeighOrch`: neighbor and next-hop management |
| `orchagent/aclorch.h` | `AclOrch`, `AclRule`, `AclTable`: ACL infrastructure |
| `orchagent/nhgbase.h` | `NhgOrchCommon`: template base for NHG orchestration |
| `orchagent/saihelper.h/cpp` | SAI failure handling utilities (`handleSaiFailure()`) |
| `orchagent/notifications.h/cpp` | ASIC notification handlers (port state changes, FDB events, switch shutdown, MACsec POST) |
| `doc/swss-schema.md` | Redis table schemas for all tables orchagent subscribes to |

---

## 9. Architecture Notes

1. **Single process, single thread**: All ~50+ Orch classes execute within one process sharing one `select()` loop. The optional ring-buffer mode (`-R` flag) offloads Consumer pop/addToSync to a dedicated thread, but all SAI programming stays on the main thread. — *`orchagent/orchdaemon.cpp:979` — `ring_thread = std::thread(&OrchDaemon::popRingBuffer, this)`*

2. **SAI calls are asynchronous**: Orchagent writes SAI calls through the sairedis library into ASIC_DB. On a `SELECT_TIMEOUT`, `OrchDaemon::flush()` flushes the sairedis pipeline. SAI call results (success/failure, returned attributes) arrive later via ASIC_DB responses. — *`orchagent/orchdaemon.cpp:925-956` — `OrchDaemon::flush()`*

3. **Retry mechanism**: When a SAI call fails (e.g., dependency not yet created), the task remains in `m_toSync` and is retried on subsequent `doTask()` iterations. The `RetryCache` mechanism (newer) tracks constraints explicitly — tasks are moved back from the retry cache to `m_toSync` when the blocking dependency is resolved. — *`orchagent/orch.h:92` — `SyncMap m_toSync`; `orchagent/orch.h:330-341` — `createRetryCache()`, `addToRetry()`, `retryToSync()`*

4. **Object reference tracking**: The base `Orch` class provides `type_map` infrastructure (`setObjectReference()`, `removeObject()`, `isObjectBeingReferenced()`) so Orches can declare that object A (e.g., a route) depends on object B (e.g., a next-hop). This prevents premature deletion and aids warm-boot state reconstruction. — *`orchagent/orch.h:83-84`, `orchagent/orch.h:375-381`*

5. **Warm boot ordering**: The `m_orchList` order is specifically designed so that lower-level objects (switch, ports, buffers) are restored before higher-level objects (routes, ACLs, mirrors). MirrorOrch and AclOrch are deliberately processed last because mirrors and ACL rules depend on everything else being stable. — *`orchagent/orchdaemon.cpp:526-533` — comment on m_orchList ordering*; `orchagent/orchdaemon.cpp:1180-1184` — MirrorOrch/AclOrch warm boot ordering*

# APP_DB — SONiC Application Database

## Overview

**APP_DB** (also called **APPL_DB**) is Redis Database **#0** in the SONiC architecture. It is the central message bus between northbound daemons (which produce network state/intent) and southbound `orchagent` (which consumes that intent and translates it to ASIC SAI calls).

### Quick Facts

| Property | Value |
|---|---|
| Redis DB ID | `0` |
| Separator | `:` (colon) |
| Instance | `redis` (default) |
| Redis key format | `TABLE_NAME:key` (e.g., `PORT_TABLE:Ethernet8`) |
| Config source | `database_config.json` → `/var/run/redis/sonic-db/database_config.json` |
| C/C++ constant | `#define APPL_DB 0` in `schema.h:12` |
| Primary consumer | `orchagent` |
| Primary producers | ~20 netlink/config daemons in swss container |

---

## 1. Why APP_DB Exists — Architecture Rationale

SONiC uses a **Redis-based pub/sub architecture** to decouple northbound state producers from southbound ASIC programming. APP_DB is the middle layer:

```
┌──────────────────────────────────────────────────────────────┐
│  NORTHBOUND (Producers)                                      │
│                                                              │
│  portsyncd  neighsyncd  fpmsyncd  intfmgrd  vlanmgrd        │
│  teammgrd   vrfmgrd    buffermgrd nbrmgrd   stpmgrd          │
│  vxlanmgrd  coppmgrd   natmgrd    sflowmgrd tunnelmgrd       │
│  macsecmgrd fabricmgrd mclagsyncd lldp_syncd ...             │
│                                                              │
│       │  Each writes network intent via ProducerStateTable   │
│       │  (Redis SET/DEL operations on DB 0)                  │
│       ▼                                                      │
├──────────────────────────────────────────────────────────────┤
│                      APP_DB (Redis DB 0)                     │
│                                                              │
│  PORT_TABLE  VLAN_TABLE  LAG_TABLE  NEIGH_TABLE             │
│  ROUTE_TABLE INTF_TABLE  VRF_TABLE  FDB_TABLE               │
│  ... 150+ tables total                                       │
│                                                              │
│       │  ConsumerStateTable subscribes to keyspace events    │
│       ▼                                                      │
├──────────────────────────────────────────────────────────────┤
│  SOUTHBOUND (Consumer)                                       │
│                                                              │
│  orchagent — 50+ Orch objects, each consuming specific       │
│  tables, translating to SAI objects, writing to ASIC_DB      │
│                                                              │
│       │                                                      │
│       ▼                                                      │
│  ASIC_DB (Redis DB 1) → syncd → SAI → Hardware              │
└──────────────────────────────────────────────────────────────┘
```

### Design Rationale

1. **Decoupling**: Producer daemons don't need to know about ASIC programming details. Orchagent doesn't need to know about netlink, BGP, or config sources.

2. **State Reconciliation**: `ConsumerStateTable` merges pending operations per key, so a rapid sequence of SET/DEL/SET for the same key results in a single final operation being processed by orchagent.

3. **Warm Restart**: During warm boot, orchagent reads existing APP_DB state to reconstruct its internal view before processing new events.

4. **Observability**: All intended ASIC state is visible in APP_DB — operators can inspect it with `redis-cli -n 0 keys "*"` to see what the system intends to program.

5. **Language Independence**: C++, Python, and Go daemons all communicate through Redis. The data model is field-value tuples (FV pairs).

---

## 2. Redis Database Number Assignment (All DBs)

From `src/sonic-swss-common/common/schema.h`:

| DB Name | ID | Separator | Purpose |
|---|---|---|---|
| **APPL_DB** | **0** | `:` | Application intent/state |
| ASIC_DB | 1 | `:` | SAI objects for syncd |
| COUNTERS_DB | 2 | `:` | Port/queue counters |
| LOGLEVEL_DB | 3 | `:` | Dynamic log level control |
| CONFIG_DB | 4 | `\|` | Source of truth (config) |
| FLEX_COUNTER_DB | 5 | `:` | PFC watchdog counters |
| STATE_DB | 6 | `\|` | Configuration state/resolution |
| SNMP_OVERLAY_DB | 7 | `\|` | SNMP agent state |
| RESTAPI_DB | 8 | `\|` | REST API state |
| CHASSIS_APP_DB | 12 | `\|` | VOQ chassis interconnect |
| APPL_STATE_DB | 14 | `:` | Application operation responses |
| DPU_APPL_DB | 15 | `:` | DPU/DASH application DB |
| EVENT_DB | 19 | `\|` | Event notifications |
| BMP_STATE_DB | 20 | `\|` | BMP state |

---

## 3. Who Produces to APP_DB (Writers)

### 3.1 Standalone Sync Daemons (kernel/hardware → APP_DB)

These daemons listen on netlink sockets (or similar kernel interfaces) and translate kernel events into APP_DB writes via `ProducerStateTable`:

| Daemon | Tables Written | Source File:Line |
|---|---|---|
| **portsyncd** | `PORT_TABLE` | `portsyncd/portsyncd.cpp:71`, `portsyncd/linksync.cpp:38` |
| **neighsyncd** | `NEIGH_TABLE`, `ROUTE_TABLE` (directly-connected /32, /128) | `neighsyncd/neighsync.cpp:28-30` |
| **fpmsyncd** | `ROUTE_TABLE`, `NEXTHOP_GROUP_TABLE`, `LABEL_ROUTE_TABLE`, `VNET_ROUTE_TABLE`, `VNET_ROUTE_TUNNEL_TABLE`, `SRV6_MY_SID_TABLE`, `SRV6_SID_LIST_TABLE`, `PIC_CONTEXT_TABLE`, `EVPN_SPLIT_HORIZON_TABLE`, `EVPN_DF_TABLE`, `EVPN_ES_BACKUP_NHG_TABLE` | `fpmsyncd/routesync.cpp:172-183` |
| **teamsyncd** | `LAG_TABLE`, `LAG_MEMBER_TABLE` | `teamsyncd/teamsync.cpp:28-29` |
| **natsyncd** | `NAT_TABLE`, `NAPT_TABLE`, `NAT_TWICE_TABLE`, `NAPT_TWICE_TABLE` | `natsyncd/natsync.cpp:41-44` |
| **fdbsyncd** | `VXLAN_FDB_TABLE`, `VXLAN_REMOTE_VNI_TABLE`, `L2_NEXTHOP_GROUP_TABLE` | `fdbsyncd/fdbsync.cpp:33-35` |
| **mclagsyncd** | `INTF_TABLE`, `ISOLATION_GROUP_TABLE`, `MCLAG_FDB_TABLE`, `ACL_TABLE_TABLE`, `ACL_RULE_TABLE`, `LAG_TABLE`, `PORT_TABLE` | `mclagsyncd/mclaglink.cpp:1810-1816` |
| **gearsyncd** | `GEARBOX_TABLE` | `gearsyncd/gearparserbase.cpp:28` |

### 3.2 Config Manager Daemons (CONFIG_DB → APP_DB)

These daemons watch CONFIG_DB for changes and translate into APP_DB operational intent. All are separate binaries built from `cfgmgr/`:

| Daemon | Tables Written | Source Files |
|---|---|---|
| **vlanmgrd** | `VLAN_TABLE`, `VLAN_MEMBER_TABLE`, `FDB_TABLE`, `PORT_TABLE` | `cfgmgr/vlanmgr.cpp:33-36` |
| **teammgrd** | `LAG_TABLE`, `PORT_TABLE` | `cfgmgr/teammgr.cpp:36-37` |
| **intfmgrd** | `INTF_TABLE`, `SAG_TABLE`, `NEIGH_TABLE`, `LAG_TABLE` | `cfgmgr/intfmgr.cpp:45-48` |
| **vrfmgrd** | `VRF_TABLE`, `VNET_TABLE`, `VXLAN_VRF_TABLE` | `cfgmgr/vrfmgr.cpp:22-24` |
| **buffermgrd** | `BUFFER_POOL_TABLE`, `BUFFER_PROFILE_TABLE`, `BUFFER_PG_TABLE`, `BUFFER_QUEUE_TABLE`, `BUFFER_PORT_INGRESS_PROFILE_LIST_TABLE`, `BUFFER_PORT_EGRESS_PROFILE_LIST_TABLE` (+ `PORT_TABLE` in dynamic mode) | `cfgmgr/buffermgr.cpp:28-33` (static), `cfgmgr/buffermgrdyn.cpp:45-55` (dynamic) |
| **portmgrd** | `PORT_TABLE`, `SEND_TO_INGRESS_PORT_TABLE` | `cfgmgr/portmgr.cpp:20-21` |
| **vxlanmgrd** | `VXLAN_TUNNEL_TABLE`, `VXLAN_TUNNEL_MAP_TABLE`, `SWITCH_TABLE`, `VXLAN_EVPN_NVO_TABLE` | `cfgmgr/vxlanmgr.cpp:194-200` |
| **coppmgrd** | `COPP_TABLE` | `cfgmgr/coppmgr.cpp:301` |
| **natmgrd** | `NAT_TABLE`, `NAPT_TABLE`, `NAT_TWICE_TABLE`, `NAPT_TWICE_TABLE`, `NAT_GLOBAL_TABLE`, `NAT_DNAT_POOL_TABLE`, `NAPT_POOL_IP_TABLE` | `cfgmgr/natmgr.cpp:43-47,258-259` |
| **sflowmgrd** | `SFLOW_TABLE`, `SFLOW_SESSION_TABLE` | `cfgmgr/sflowmgr.cpp:15-16` |
| **tunnelmgrd** | `TUNNEL_DECAP_TABLE`, `TUNNEL_DECAP_TERM_TABLE` | `cfgmgr/tunnelmgr.cpp:110-111` |
| **fabricmgrd** | `FABRIC_PORT_TABLE`, `FABRIC_MONITOR_TABLE` | `cfgmgr/fabricmgr.cpp:18-19` |

### 3.3 Other Producers

| Daemon | Tables Written | Source |
|---|---|---|
| **lldp_syncd** | LLDP entries | `dbsyncd/src/lldp_syncd/daemon.py` |
| **xcvrd** | `PORT_TABLE` (transceiver info) | `xcvr_table_helper.py` |
| **db_migrator** | Various tables during migration | `db_migrator.py` |
| **linkmgrd** | `MUX_CABLE_COMMAND_TABLE`, `FORWARDING_STATE_COMMAND` | `muxmgrd/` |
| **vrrpd** | `VRRP_TABLE` | `vrrpd/` |
| **swssconfig** | Any table from JSON config files | `swssconfig/swssplayer.cpp:16` |

### 3.4 Special Case: stpmgrd — Does NOT Write Directly to APP_DB

`stpmgrd` (`cfgmgr/stpmgr.cpp`) is unusual among cfgmgr daemons: it does **not** hold any `ProducerStateTable` for APP_DB. Instead, it communicates with the `stpd` (STP daemon) via Unix IPC (`sendMsgStpd()`). The `stpd` daemon computes STP states and writes them to APP_DB STP tables via `stpsync`. So the actual APP_DB producer for STP tables is `stpsync` (inside the stpd process), not stpmgrd.

### 3.5 Orchagent Write-Back Producers

`orchagent` primarily **consumes** from APP_DB, but several internal Orch components write back for inter-component communication, warm restart state, or route learning:

| Orch Component | Tables Written | Purpose | Source |
|---|---|---|---|
| **NeighOrch** | `NEIGH_RESOLVE_TABLE` | Triggers NbrMgr kernel neighbor resolution | `neighorch.cpp:39,121,140` |
| **RouteOrch** | `TUNNEL_DECAP_TERM_TABLE` | Route-to-tunnel decap term resolution | `routeorch.cpp:55,3250` |
| **FgNhgOrch** | `ROUTE_TABLE` | Route table migration during fine-grained NHG | `fgnhgorch.cpp:32,1865-1951` |
| **VNetOrch / VNetRouteOrch** | `BFD_SESSION_TABLE`, `TUNNEL_DECAP_TERM_TABLE`, `VNET_ROUTE_TABLE`, `VNET_ROUTE_TUNNEL_TABLE`, `ACL_TABLE_TABLE`, `ACL_TABLE_TYPE_TABLE`, `ACL_RULE_TABLE`, `VNET_MONITOR_TABLE` | VNet peer management, tunnel ACLs | `vnetorch.cpp:745-759,3614-3781` |
| **Srv6Orch** | `SRV6_SID_LIST_TABLE`, `SRV6_MY_SID_TABLE`, `PIC_CONTEXT_TABLE` | SRv6 SID configuration | `srv6orch.cpp:104-106` |
| **MuxOrch** | `TUNNEL_ROUTE_TABLE`, `HW_MUX_CABLE_TABLE`, `MUX_CABLE_RESPONSE_TABLE` | MUX tunnel routes, cable state responses | `muxorch.cpp:2869` |
| **PfcWdOrch** | `PFC_WD_TABLE_INSTORM` | Storm detection for warm reboot recovery | `pfcwdorch.cpp:694-695` |
| **DashEniFwdOrch** | `ACL_RULE_TABLE`, `ACL_TABLE_TYPE_TABLE`, `ACL_TABLE_TABLE` | DASH ENI forwarding ACL rules | `dashenifwdorch.cpp:403-405` |
| **Routeresync** | `ROUTE_TABLE` | Route replay during warm restart resync | `routeresync.cpp:26` |

### 3.6 APP_DB Tables With No C++ Producer

The following tables are defined in `schema.h` but have no C++ `ProducerStateTable` in this codebase. They are likely written by Python utilities, external gNMI/P4RT controllers, or are legacy tables:

- `TC_TO_QUEUE_MAP_TABLE`, `SCHEDULER_TABLE`, `DSCP_TO_TC_MAP_TABLE`, `QUEUE_TABLE`, `PORT_QOS_MAP_TABLE`, `WRED_PROFILE_TABLE`, `TC_TO_PRIORITY_GROUP_MAP_TABLE`, `PFC_PRIORITY_TO_PRIORITY_GROUP_MAP_TABLE`, `PFC_PRIORITY_TO_QUEUE_MAP_TABLE` (**legacy QoS — marked "TO BE REMOVED"**)
- All `P4RT_*` tables — produced by external gNMI/P4Runtime controller via ZMQ
- All `DASH_*` tables — produced by DPU gNMI service via ZMQ
- All `MACSEC_*` tables — produced by `macsecmgrd` or external orchestrator
- `VRRP_TABLE`, `PAC_PORT_TABLE`, `SUPPRESS_VLAN_NEIGH_TABLE`, `VLAN_STACKING_TABLE`, `VLAN_TRANSLATION_TABLE`, `PASS_THROUGH_ROUTE_TABLE`, `BGP_PROFILE_TABLE`, `FC_TO_NHG_INDEX_MAP_TABLE`, `SFLOW_SAMPLE_RATE_TABLE`, `MUX_CABLE_TABLE`, `PORT_TABLE_PEER`, `HW_MUX_CABLE_TABLE`

---

## 4. Who Consumes from APP_DB (Readers)

### 4.1 Primary Consumer: orchagent

`orchagent` is the main consumer. It subscribes to APP_DB tables via `ConsumerStateTable`, processes changes through Orch subclasses, and translates them to SAI API calls written to `ASIC_DB`.

#### Core L2/L3 Orchs

| Orch | APP_DB Tables Consumed | Purpose |
|---|---|---|
| **PortsOrch** | `PORT_TABLE`, `VLAN_TABLE`, `VLAN_MEMBER_TABLE`, `LAG_TABLE`, `LAG_MEMBER_TABLE`, `SEND_TO_INGRESS_PORT_TABLE` | Port creation, VLAN/LAG management, bridge ports |
| **IntfsOrch** | `INTF_TABLE`, `SAG_TABLE` | Router interfaces, IP assignment, MTU |
| **NeighOrch** | `NEIGH_TABLE` | ARP/NDP neighbor entries |
| **FdbOrch** | `FDB_TABLE`, `VXLAN_FDB_TABLE`, `MCLAG_FDB_TABLE` | MAC forwarding entries |
| **RouteOrch** | `ROUTE_TABLE`, `LABEL_ROUTE_TABLE` | IPv4/IPv6 route entries |
| **NhgOrch** | `NEXTHOP_GROUP_TABLE` | ECMP next-hop groups |
| **VRFOrch** | `VRF_TABLE` | VRF creation/deletion |

#### VLAN/STP Orchs

| Orch | APP_DB Tables Consumed | Purpose |
|---|---|---|
| **StpOrch** | `STP_VLAN_INSTANCE_TABLE`, `STP_PORT_STATE_TABLE`, `STP_FASTAGEING_FLUSH_TABLE`, `STP_INST_PORT_FLUSH_TABLE` | Spanning tree — VLAN instances, port states, FDB flush |

#### Tunnel/VXLAN Orchs

| Orch | APP_DB Tables Consumed | Purpose |
|---|---|---|
| **TunnelDecapOrch** | `TUNNEL_DECAP_TABLE`, `TUNNEL_DECAP_TERM_TABLE` | IP-in-IP tunnel decap |
| **VxlanTunnelOrch** | `VXLAN_TUNNEL_TABLE` | VXLAN tunnel creation |
| **VxlanTunnelMapOrch** | `VXLAN_TUNNEL_MAP_TABLE` | VLAN-to-VNI mapping |
| **VxlanVrfMapOrch** | `VXLAN_VRF_TABLE` | VXLAN-to-VRF binding |
| **EvpnNvoOrch** | `VXLAN_EVPN_NVO_TABLE` | EVPN network overlay |
| **EvpnRemoteVnip2pOrch / EvpnRemoteVnip2mpOrch** | `VXLAN_REMOTE_VNI_TABLE` | Remote VNI peers |

#### QoS/Buffer Orchs

| Orch | APP_DB Tables Consumed | Purpose |
|---|---|---|
| **BufferOrch** | `BUFFER_POOL_TABLE`, `BUFFER_PROFILE_TABLE`, `BUFFER_QUEUE_TABLE`, `BUFFER_PG_TABLE`, `BUFFER_PORT_INGRESS_PROFILE_LIST_TABLE`, `BUFFER_PORT_EGRESS_PROFILE_LIST_TABLE` | Buffer pool/profile/queue/PG config |

#### ACL/Security Orchs

| Orch | APP_DB Tables Consumed | Purpose |
|---|---|---|
| **AclOrch** | `ACL_TABLE_TABLE`, `ACL_TABLE_TYPE_TABLE`, `ACL_RULE_TABLE` | ACL table and rule management |
| **CoppOrch** | `COPP_TABLE` | Control plane policing |
| **MACsecOrch** | `MACSEC_PORT_TABLE`, `MACSEC_EGRESS_SC_TABLE`, `MACSEC_INGRESS_SC_TABLE`, `MACSEC_EGRESS_SA_TABLE`, `MACSEC_INGRESS_SA_TABLE` | MACsec encryption |

#### Advanced Feature Orchs

| Orch | APP_DB Tables Consumed | Purpose |
|---|---|---|
| **SwitchOrch** | `SWITCH_TABLE` | Switch-level attributes (ECMP hash, etc.) |
| **NatOrch** | `NAT_TABLE`, `NAPT_TABLE`, `NAT_TWICE_TABLE`, `NAPT_TWICE_TABLE`, `NAT_GLOBAL_TABLE`, `NAT_DNAT_POOL_TABLE` | NAT/NAPT entries |
| **SflowOrch** | `SFLOW_TABLE`, `SFLOW_SESSION_TABLE`, `SFLOW_SAMPLE_RATE_TABLE` | sFlow sampling |
| **MuxCableOrch** | `MUX_CABLE_TABLE` | Active/standby MUX cable |
| **BfdOrch** | `BFD_SESSION_TABLE` | BFD session management |
| **IcmpOrch** | `ICMP_ECHO_SESSION_TABLE` | ICMP echo sessions |
| **PfcWdSwOrch** | `PFC_WD_TABLE` | PFC watchdog actions |
| **VNetOrch** | `VNET_TABLE` | Virtual networks |
| **VNetRouteOrch** | `VNET_ROUTE_TABLE`, `VNET_ROUTE_TUNNEL_TABLE` | VNet routes |
| **Srv6Orch** | `SRV6_SID_LIST_TABLE`, `SRV6_MY_SID_TABLE`, `PIC_CONTEXT_TABLE` | SRv6 SID lists |
| **ChassisOrch** | `PASS_THROUGH_ROUTE_TABLE` | VOQ pass-through routes |
| **FabricPortsOrch** | `FABRIC_PORT_TABLE`, `FABRIC_MONITOR_TABLE` | Multi-ASIC fabric ports |
| **IsoGrpOrch** | `ISOLATION_GROUP_TABLE` | Port isolation groups |
| **ShlOrch** | `EVPN_SPLIT_HORIZON_TABLE` | EVPN split horizon |
| **EvpnMhOrch** | `EVPN_DF_TABLE` | EVPN multi-home |
| **CbfNhgOrch** | `CLASS_BASED_NEXT_HOP_GROUP_TABLE` | Class-based NHG |
| **L2NhgOrch** | `L2_NEXTHOP_GROUP_TABLE` | L2 next-hop groups |
| **NhgMapOrch** | `FC_TO_NHG_INDEX_MAP_TABLE` | FC-to-NHG index map |
| **FgNhgOrch** | `ROUTE_TABLE` (indirect) | Fine-grained NHG |

#### P4RT Orchs (P4 Runtime)

| Orch | APP_DB Tables Consumed | Purpose |
|---|---|---|
| **P4Orch** | `P4RT_TABLE` (dispatch) → 17 sub-tables | P4 pipeline programming |

### 4.2 Notification Consumers on APP_DB

These orchagent sub-components consume named notification channels (not tables):

| Orch | Channel | Purpose |
|---|---|---|
| **FdbOrch** | `FLUSHFDBREQUEST` | Flush FDB by VLAN/port/all |
| **NatOrch** | `FLUSHNATSTATISTICS` | Flush NAT counters |
| **NatOrch** | `NAT_DB_CLEANUP_NOTIFICATION` | Cleanup after conntrack timeout |
| **WatermarkOrch** | `WATERMARK_CLEAR_REQUEST` | Clear watermark counters |
| **SwitchOrch** | `RESTARTCHECK` | Warm restart readiness check |

### 4.3 Non-Orchagent Consumers

Some cfgmgr daemons also consume from APP_DB (they both produce and consume):

| Consumer | Table/Channel | Purpose |
|---|---|---|
| **NbrMgr** (nbrmgr) | `NEIGH_RESOLVE_TABLE` | Resolve neighbors in kernel |
| **TunnelMgr** (tunnelmgr) | `TUNNEL_ROUTE_TABLE` | Program tunnel routes to kernel |
| **NatMgr** (natmgrd) | `SETTIMEOUTNAT` channel | Set NAT conntrack timeouts |
| **NatMgr** (natmgrd) | `FLUSHNATENTRIES` channel | Flush NAT conntrack entries |

---

## 5. Complete APP_DB Table Inventory

### 5.1 Port, VLAN, LAG Core Tables

| Table | Producer | Consumer |
|---|---|---|
| `PORT_TABLE` | portsyncd, intfmgrd, portmgrd, xcvrd, linkmgrd | PortsOrch |
| `SEND_TO_INGRESS_PORT_TABLE` | syncd/producer | PortsOrch |
| `GEARBOX_TABLE` | gearsyncd | (external) |
| `FABRIC_PORT_TABLE` | syncd | FabricPortsOrch |
| `VLAN_TABLE` | vlanmgrd | PortsOrch |
| `VLAN_MEMBER_TABLE` | vlanmgrd | PortsOrch |
| `LAG_TABLE` | teammgrd, mclagsyncd | PortsOrch |
| `LAG_MEMBER_TABLE` | teammgrd, mclagsyncd | PortsOrch |
| `INTF_TABLE` | intfmgrd, intfsyncd, mclagsyncd | IntfsOrch |
| `SAG_TABLE` | intfmgrd | IntfsOrch |
| `SYSTEM_PORT_TABLE` | orchagent (from CFG_DB) | orchagent |
| `PASS_THROUGH_ROUTE_TABLE` | srbgpd | ChassisOrch |
| `ISOLATION_GROUP_TABLE` | isolationmgr, mclagsyncd | IsoGrpOrch |
| `SUPPRESS_VLAN_NEIGH_TABLE` | neighsyncd | (state consumer) |
| `VLAN_STACKING_TABLE` | vlanmgrd | (defined) |
| `VLAN_TRANSLATION_TABLE` | vlanmgrd | (defined) |

### 5.2 Neighbor, Route, Tunnel Tables

| Table | Producer | Consumer |
|---|---|---|
| `NEIGH_TABLE` | neighsyncd | NeighOrch |
| `NEIGH_RESOLVE_TABLE` | orchagent (NeighOrch) | nbrmgr |
| `ROUTE_TABLE` | fpmsyncd (bgpd/zebra) | RouteOrch, FgNhgOrch |
| `LABEL_ROUTE_TABLE` | fpmsyncd | RouteOrch |
| `TUNNEL_DECAP_TABLE` | tunnelmgrd | TunnelDecapOrch |
| `TUNNEL_DECAP_TERM_TABLE` | tunnelmgrd, RouteOrch | TunnelDecapOrch |
| `TUNNEL_ROUTE_TABLE` | MuxOrch/tunnelmgr | tunnelmgr |
| `VRF_TABLE` | vrfmgrd | VRFOrch |
| `PIC_CONTEXT_TABLE` | bgpd | Srv6Orch |

### 5.3 FDB, Switch, Nexthop Tables

| Table | Producer | Consumer |
|---|---|---|
| `FDB_TABLE` | fdbsyncd, EVPN | FdbOrch |
| `PFC_WD_TABLE` | pfcwd | PfcWdSwOrch |
| `SWITCH_TABLE` | syncd/cfgmgr | SwitchOrch |
| `NEXTHOP_GROUP_TABLE` | nhgmgrd, fpmsyncd | NhgOrch |
| `CLASS_BASED_NEXT_HOP_GROUP_TABLE` | nhgmgrd | CbfNhgOrch |
| `EVPN_SPLIT_HORIZON_TABLE` | EVPN MCLAG mgrd | ShlOrch |
| `L2_NEXTHOP_GROUP_TABLE` | (producer) | L2NhgOrch |
| `FC_TO_NHG_INDEX_MAP_TABLE` | (producer) | NhgMapOrch |
| `BGP_PROFILE_TABLE` | bgpcfgd | RouteMapMgr |
| `EVPN_DF_TABLE` | EVPN mgrd | EvpnMhOrch |
| `MCLAG_FDB_TABLE` | MCLAG mgrd | FdbOrch |

### 5.4 VXLAN, VNET Tables

| Table | Producer | Consumer |
|---|---|---|
| `VXLAN_VRF_TABLE` | vxlanmgrd | VxlanVrfMapOrch |
| `VXLAN_TUNNEL_MAP_TABLE` | vxlanmgrd | VxlanTunnelMapOrch |
| `VXLAN_TUNNEL_TABLE` | vxlanmgrd | VxlanTunnelOrch |
| `VXLAN_FDB_TABLE` | vxlanmgrd/EVPN | FdbOrch |
| `VXLAN_REMOTE_VNI_TABLE` | EVPN | EvpnRemoteVnip2pOrch / EvpnRemoteVnip2mpOrch |
| `VXLAN_EVPN_NVO_TABLE` | EVPN | EvpnNvoOrch |
| `VNET_TABLE` | vnetmgrd | VNetOrch |
| `VNET_ROUTE_TABLE` | vnetmgrd | VNetRouteOrch |
| `VNET_ROUTE_TUNNEL_TABLE` | vnetmgrd | VNetRouteOrch |
| `VNET_MONITOR_TABLE` | VNetRouteOrch (orchagent) | monitor daemon |

### 5.5 ACL, SFlow, NAT, STP Tables

| Table | Producer | Consumer |
|---|---|---|
| `ACL_TABLE_TABLE` | aclmgrd, VNetOrch, mclagsyncd | AclOrch |
| `ACL_TABLE_TYPE_TABLE` | aclmgrd, VNetOrch | AclOrch |
| `ACL_RULE_TABLE` | aclmgrd, VNetOrch, mclagsyncd | AclOrch |
| `SFLOW_TABLE` | sflowmgrd | SflowOrch |
| `SFLOW_SESSION_TABLE` | sflowmgrd | SflowOrch |
| `SFLOW_SAMPLE_RATE_TABLE` | sflowmgrd | SflowOrch |
| `NAT_DNAT_POOL_TABLE` | natmgrd | NatOrch |
| `NAT_TABLE` | natmgrd, natsyncd | NatOrch |
| `NAPT_TABLE` | natmgrd, natsyncd | NatOrch |
| `NAT_TWICE_TABLE` | natmgrd | NatOrch |
| `NAPT_TWICE_TABLE` | natmgrd | NatOrch |
| `NAT_GLOBAL_TABLE` | natmgrd | NatOrch |
| `NAPT_POOL_IP_TABLE` | natmgrd, natsyncd | natsyncd |
| `STP_VLAN_TABLE` | stpsync | (STATE_DB consumer) |
| `STP_VLAN_PORT_TABLE` | stpsync | (STATE_DB consumer) |
| `STP_VLAN_INSTANCE_TABLE` | stpsync | StpOrch |
| `STP_PORT_TABLE` | stpsync | (STATE_DB consumer) |
| `STP_PORT_STATE_TABLE` | stpsync | StpOrch |
| `STP_FASTAGEING_FLUSH_TABLE` | stpsync | StpOrch |
| `STP_BPDU_GUARD_TABLE` | stpsync | (STATE_DB consumer) |
| `STP_MST_INST_TABLE` | stpsync | (STATE_DB consumer) |
| `STP_MST_PORT_TABLE` | stpsync | (STATE_DB consumer) |
| `STP_INST_PORT_FLUSH_TABLE` | stpsync | StpOrch |

*Note: stpmgr does NOT write directly to APP_DB STP tables. It uses IPC (`sendMsgStpd()`) to communicate with `stpd`, which in turn writes APP_DB tables via `stpsync`.*

### 5.6 BFD, ICMP, COPP, VRRP, MUX, Forwarding State Tables

| Table | Producer | Consumer |
|---|---|---|
| `BFD_SESSION_TABLE` | bfdmgrd, VNetRouteOrch | BfdOrch |
| `ICMP_ECHO_SESSION_TABLE` | (producer) | IcmpOrch |
| `COPP_TABLE` | coppmgrd | CoppOrch |
| `VRRP_TABLE` | vrrpd | (defined) |
| `MUX_CABLE_TABLE` | muxmgrd | MuxCableOrch |
| `HW_MUX_CABLE_TABLE` | ycabled, MuxOrch | ycabled/pmon |
| `MUX_CABLE_COMMAND_TABLE` | ycabled, linkmgrd | orchagent |
| `MUX_CABLE_RESPONSE_TABLE` | orchagent | linkmgrd |
| `FORWARDING_STATE_COMMAND` | linkmgrd | orchagent |
| `FORWARDING_STATE_RESPONSE` | orchagent | linkmgrd |
| `PORT_TABLE_PEER` | linkmgrd | peer orchagent |
| `HW_FORWARDING_STATE_PEER` | linkmgrd | peer orchagent |

### 5.7 MACsec Tables

| Table | Producer | Consumer |
|---|---|---|
| `MACSEC_PORT_TABLE` | macsecmgrd | MACsecOrch |
| `MACSEC_EGRESS_SC_TABLE` | macsecmgrd | MACsecOrch |
| `MACSEC_INGRESS_SC_TABLE` | macsecmgrd | MACsecOrch |
| `MACSEC_EGRESS_SA_TABLE` | macsecmgrd | MACsecOrch |
| `MACSEC_INGRESS_SA_TABLE` | macsecmgrd | MACsecOrch |

### 5.8 Buffer Tables

| Table | Producer | Consumer |
|---|---|---|
| `BUFFER_POOL_TABLE` | buffermgrd (static + dynamic) | BufferOrch |
| `BUFFER_PROFILE_TABLE` | buffermgrd | BufferOrch |
| `BUFFER_PG_TABLE` | buffermgrd | BufferOrch |
| `BUFFER_QUEUE_TABLE` | buffermgrd | BufferOrch |
| `BUFFER_PORT_INGRESS_PROFILE_LIST_TABLE` | buffermgrd | BufferOrch |
| `BUFFER_PORT_EGRESS_PROFILE_LIST_TABLE` | buffermgrd | BufferOrch |

### 5.9 SRv6, Fabric, LLR, PAC, P4RT, DASH Tables

See `src/sonic-swss-common/common/schema.h` for the complete macro definitions. Key groups:

- **SRv6**: `SRV6_SID_LIST_TABLE`, `SRV6_MY_SID_TABLE`
- **Fabric**: `FABRIC_PORT_TABLE`, `FABRIC_MONITOR_TABLE`
- **P4RT**: 19 tables for P4 Runtime pipeline programming
- **DASH**: ~30 tables for DPU/SmartSwitch DASH orchestration
- **Legacy QoS**: 9 tables marked "TO BE REMOVED" (being migrated to CONFIG_DB)

---

## 6. The Data Flow — End to End

### 6.1 Example: VLAN Creation

```
1. CONFIG_DB (DB 4) — VLAN config is written
   Key: "VLAN|Vlan100"

2. vlanmgrd — watches CONFIG_DB, detects new VLAN
   ProducerStateTable::set("Vlan100", { "vlanid": "100" })
   → writes to APP_DB "VLAN_TABLE:Vlan100"

3. APP_DB (DB 0) — Redis keyspace notification fires
   Key: "VLAN_TABLE:Vlan100" → __keyspace@0__:VLAN_TABLE:Vlan100

4. orchagent / PortsOrch — ConsumerStateTable receives event
   PortsOrch::doVlanTask() → addVlan() → sai_create_vlan()

5. ASIC_DB (DB 1) — SAI VLAN object written
   Key: "SAI_OBJECT_TYPE_VLAN:..." with SAI attributes

6. syncd — reads ASIC_DB, calls sai_create_vlan() on hardware
```

### 6.2 Example: STP Port State Change

```
1. stpd (STP daemon) — computes new STP port state
   sendMsgStpd() IPC from stpmgr → stpd computes state → writes via stpsync

2. APP_DB — STP_PORT_STATE_TABLE updated
   Key: "STP_PORT_STATE_TABLE:Ethernet8:0" → state=blocking

3. orchagent / StpOrch — ConsumerStateTable receives event
   StpOrch::doStpPortStateTask() → updateStpPortState()
   → sai_set_port_stp_state() → SAI_PORT_ATTR_STP_STATE

4. ASIC_DB — SAI port attribute written

5. syncd → SAI → Hardware — port state applied to ASIC
```

### 6.3 ConsumerTable Mechanism

The key abstraction is `ConsumerStateTable` (for APP_DB and ASIC_DB):

```cpp
// Producer writes:
ProducerStateTable p(&appl_db, "VLAN_TABLE");
p.set("Vlan100", { {"vlanid", "100"}, {"mtu", "9000"} });

// Consumer reads (in orchagent):
ConsumerStateTable c(&appl_db, "VLAN_TABLE");
// On keyspace notification, pops the operation
// Orch::doTask() processes it:
//   - SET → create or update VLAN
//   - DEL → remove VLAN
```

Important: `ConsumerStateTable` **merges** concurrent operations per key. If two SETs arrive for `Vlan100` before orchagent processes them, only the latest values are used. This prevents unnecessary ASIC churn.

---

## 7. APP_DB-Related Databases

### 7.1 CHASSIS_APP_DB (DB 12)

Used in VOQ (Virtual Output Queue) chassis systems for communication between line cards and the supervisor:

| Table | Purpose |
|---|---|
| `SYSTEM_INTERFACE` | System-side router interfaces |
| `SYSTEM_NEIGH` | System-side neighbor entries |
| `SYSTEM_LAG_TABLE` | System LAG configuration |
| `SYSTEM_LAG_MEMBER_TABLE` | System LAG member ports |

Consumer: orchagent (IntfsOrch, NeighOrch, PortsOrch in VOQ mode)

### 7.2 APPL_STATE_DB (DB 14)

Tracks the status of APP_DB operations. `orchagent` writes operation responses here:

```cpp
ResponsePublisher response_publisher(&appl_state_db);
response_publisher.publish(APPL_STATE_TABLE_NAME, key, status, values);
```

### 7.3 DPU_APPL_DB (DB 15)

Dedicated application DB for DPU/SmartSwitch DASH workloads. Contains ~30 DASH-specific tables consumed by `DpuOrchDaemon` orchs.

---

## 8. Switchdev Analysis — Can We Remove APP_DB?

### Short Answer: Currently Impossible Without Major Rewrite

APP_DB is the **mandatory, non-optional** middle layer in SONiC's architecture. Removing it would break everything. Here is the detailed analysis:

### 8.1 What Would Crash Immediately

1. **orchagent crashes on startup**: `DBConnector("APPL_DB", 0)` in `orchagent/main.cpp:645` throws an unhandled `out_of_range` exception if `APPL_DB` is not in `database_config.json`.

2. **All ~20 producer daemons crash on startup**: Every netlink listener and config manager opens `DBConnector("APPL_DB")` — same unhandled exception pattern.

3. **swss.sh scripts fail**: Startup script flushes APP_DB on cold boot, deletes keys on stop.

### 8.2 No Fallback Path Exists

- orchagent does **NOT** open netlink sockets — it only reads from Redis
- There is no `#ifdef` or config flag to bypass APP_DB
- There is no alternative data source that orchagent can consume from
- ConsumerStateTable is tightly coupled to Redis keyspace notifications
- DBConnector strictly requires the database name in `database_config.json`

### 8.3 What Would Need to Change to Remove APP_DB

Removing APP_DB would require a **fundamental architectural rewrite**:

1. **orchagent would need to listen to netlink directly** — a massive change; orchagent currently has zero netlink code. It would need to duplicate the netlink parsing logic from portsyncd, neighsyncd, intfsyncd, etc.

2. **Config managers would need a new communication path** — vlanmgrd, teammgrd, vrfmgrd, etc. currently write to APP_DB; they'd need a different way to tell orchagent about config changes.

3. **Warm restart would need a new state store** — orchagent currently reads APP_DB to restore state during warm boot.

4. **The pub/sub decoupling would be lost** — all producers would need to know how to directly communicate with orchagent.

### 8.4 What IS Feasible with Switchdev

Instead of removing APP_DB, the realistic approach is to **remove the SAIRedis/ASIC_DB layer** and have orchagent talk to the kernel's switchdev interface instead of SAI:

```
CURRENT:
  daemons → APP_DB → orchagent → ASIC_DB → syncd → SAI → Hardware

SWITCHDEV APPROACH:
  daemons → APP_DB → orchagent → netlink/switchdev → Kernel → Hardware
                                       ↑
                              (replaces ASIC_DB + syncd + SAI)
```

In this model:
- APP_DB stays — it's still the decoupling layer for northbound producers
- orchagent still consumes from APP_DB (no change needed)
- orchagent's SAI calls are replaced with netlink RTM_SETLINK/RTM_SETNEIGH/etc. calls to the kernel's switchdev bridge driver
- `syncd` and `ASIC_DB` are removed — they're the SAI-specific layer

This aligns with the existing [[switchdev-bypass-plan]]: drain the SAI tables in orchagent (PortsOrch, StpOrch, FdbOrch, etc.) and replace SAI calls with netlink operations.

### 8.5 Summary: Keep APP_DB, Replace ASIC_DB

| Layer | Keep? | Reason |
|---|---|---|
| CONFIG_DB | Keep | Source of truth |
| **APP_DB** | **Keep** | Decouples producers from consumers; enables warm restart; provides observability |
| orchagent | Keep (modify) | Replace SAI calls with netlink; keep the Orch framework |
| ASIC_DB | Remove | SAI-specific; not needed for switchdev |
| syncd | Remove | SAI-specific; not needed for switchdev |
| SAI | Remove | Replaced by kernel switchdev |

---

## 9. Key Source Files

| File | Role |
|---|---|
| `src/sonic-swss-common/common/schema.h:10-33` | All Redis DB ID `#define` constants |
| `src/sonic-swss-common/common/schema.h:37-216` | All `APP_*_TABLE_NAME` macros |
| `src/sonic-swss-common/common/database_config.json` | DB name-to-ID mapping config |
| `src/sonic-swss-common/common/dbconnector.h` | `DBConnector` and `SonicDBConfig` classes |
| `src/sonic-swss-common/common/table.cpp:24` | Separator mapping (colon for APP_DB) |
| `src/sonic-swss/orchagent/main.cpp:645` | orchagent APP_DB connection initialization |
| `src/sonic-swss/orchagent/orchdaemon.cpp:189-922` | All Orch object creation and table subscriptions |
| `src/sonic-swss/orchagent/orch.cpp:1196-1205` | `Orch::addConsumer()` — ConsumerStateTable creation |
| `src/sonic-swss/doc/swss-schema.md:9+` | Human-readable schema documentation |
| `orchagent.md` (repo root) | Detailed orchagent architecture explanation |
| `dockers/docker-database/database_config.json.j2` | Docker-level DB config template |
| `files/scripts/swss.sh` | Startup script (APP_DB flush, PortInitDone) |

---

## 10. Related Memories

- [[switchdev-bypass-plan]] — Plan to bypass orchagent SAI calls for switchdev mode
- [[session-progress]] — Active VLAN/stpd development work

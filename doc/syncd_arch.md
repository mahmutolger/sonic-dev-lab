# SONiC ASIC Event & Notification Architecture (function-level trace)

## 1. Processes Waiting on ASIC Events

### 1.1 syncd — Receives ASIC commands from orchagent via Redis/ZMQ

**Wait function**: `Syncd::run()` → `swss::Select::select()`
- File: `src/sonic-sairedis/syncd/Syncd.cpp:6803`
- `int result = s->select(&sel, 1000)` — blocks for up to 1000ms waiting for selectable events
- Selectables registered at lines 6769-6772:
  1. `m_selectableChannel` — Redis/ZMQ consumer for ASIC_DB commands from orchagent
  2. `m_restartQuery` — warm-restart notification channel
  3. `m_flexCounter` — FLEX_COUNTER_TABLE consumer
  4. `m_flexCounterGroup` — FLEX_COUNTER_GROUP_TABLE consumer

**What triggers the wake-up**: A Redis pubsub message or ZMQ message from orchagent writing to `ASIC_STATE_TABLE`, a restart query message, or a flex counter change

**Direct-from-syncd?**: N/A — syncd IS the process that receives from syncd

---

### 1.2 orchagent (via syncd) — Port State Change Notifications

**Wait function**: `PortsOrch::doTask(NotificationConsumer&)` triggers when the notification consumer has data, driven by the main orchagent event loop `OrchDaemon::start()`
- File: `src/sonic-swss/orchagent/portsorch.cpp:9865`
- The `NotificationConsumer` (`m_portStatusNotificationConsumer`) is set up at lines 1097-1106
- Subscribes to ASIC_DB Redis key: `NOTIFICATIONS` with op-allowlist `{"port_state_change"}`
- Uses `swss::NotificationQueuePolicy::LruDedup` deduplication

**What triggers the wake-up**: syncd publishes a `port_state_change` notification to Redis `ASIC_DB NOTIFICATIONS` channel via `RedisNotificationProducer::send()`

**Direct-from-syncd?**: **YES** — this notification flows directly from syncd via:
```
ASIC → SAI callback → SwitchNotifications::onPortStateChange()
  → NotificationHandler::onPortStateChange()
    (src/sonic-sairedis/syncd/NotificationHandler.cpp:109)
  → NotificationProcessor::process_on_port_state_change()
    (src/sonic-sairedis/syncd/NotificationProcessor.cpp:491)
  → RedisNotificationProducer::send()
    (src/sonic-sairedis/syncd/RedisNotificationProducer.cpp:19)
  → Redis pubsub "ASIC_DB NOTIFICATIONS"
  → orchagent m_portStatusNotificationConsumer
    (src/sonic-swss/orchagent/portsorch.cpp:1097)
```

---

### 1.3 portsyncd — Port State Change from Kernel Netlink (INDEPENDENT of syncd)

**Wait function**: `swss::Select::select()` in portsyncd's main loop
- File: `src/sonic-swss/portsyncd/portsyncd.cpp:103`
- `ret = s.select(&temps, DEFAULT_SELECT_TIMEOUT)` — blocks waiting for netlink events
- Only one selectable is registered: `s.addSelectable(&netlink)` at line 97 — the netlink socket

**What triggers the wake-up**: A kernel netlink `RTM_NEWLINK` or `RTM_DELLINK` event — delivered when the kernel netdevice's link state or operstate changes. These are received via the libnl socket (created at `src/sonic-swss-common/common/netlink.cpp:16` as `nl_socket_alloc()`, connected at line 27 as `nl_connect(m_socket, NETLINK_ROUTE)`)

**Registered netlink groups**: `RTNLGRP_LINK` only (`portsyncd.cpp:87`)

**Direct-from-syncd?**: **NO** — portsyncd receives netlink events directly from the Linux kernel, NOT from syncd. The netlink socket is completely independent of syncd's SAI notification path. portsyncd's `LinkSync::onMsg()` (`linksync.cpp:111`) reads `IFF_RUNNING` from `rtnl_link_get_flags(link)` (line 131) and writes `netdev_oper_status` to `STATE_DB PORT_TABLE`.

The only dependency on syncd is the wait for `PortInitDone` signal — portsyncd at line 97-98 checks `if (!g_init && g_portSet.empty())` to send `PortInitDone` through `ProducerStateTable p(applDb, APP_PORT_TABLE_NAME)` at line 134. This waits until all ports from CONFIG_DB have been seen via netlink before signaling readiness.

---

### 1.4 orchagent (via syncd) — FDB Event Notifications

**Wait function**: FdbOrch's consumer triggered by main orchagent `select()` loop
- The `NotificationConsumer` for FDB events is set up in `fdborch.cpp:79`
- Subscribes to ASIC_DB `NOTIFICATIONS` channel for FDB events

**What triggers the wake-up**: syncd publishes FDB event notification via the same `RedisNotificationProducer` mechanism

**Direct-from-syncd?**: **YES** — FDB events come from syncd:
```
ASIC → SAI callback → NotificationHandler::onFdbEvent()
    (src/sonic-sairedis/syncd/NotificationHandler.cpp:87)
  → NotificationProcessor::process_on_fdb_event()
    (src/sonic-sairedis/syncd/NotificationProcessor.cpp:309)
  → RedisNotificationProducer::send()
  → orchagent FdbOrch consumer
```

---

### 1.5 fdbsyncd — State DB FDB Changes AND Kernel Netlink

**Wait function**: fdbsyncd's main select loop
- File: `src/sonic-swss/fdbsyncd/fdbsyncd.cpp`
- **Netlink socket**: Subscribes to `RTNLGRP_LINK` (line 77), `RTNLGRP_NEIGH` (line 78), `RTNLGRP_NEXTHOP` (line 79)
- **Registered message handlers** (lines 27-31): `RTM_NEWNEIGH` (raw), `RTM_DELNEIGH` (raw), `RTM_NEWLINK`, `RTM_NEWNEXTHOP` (raw), `RTM_DELNEXTHOP` (raw)
- **Redis subscriptions** (lines 98-100): `STATE_DB`, `MCLAG_REMOTE_FDB_TABLE`, `CFG_VXLAN_EVPN_NVO_TABLE`

**Direct-from-syncd?**: **PARTIALLY** — FDB events originate from syncd (ASIC FDB learn/age notifications) but arrive at fdbsyncd through STATE_DB (after orchagent's FdbOrch processes the syncd notification and updates STATE_DB). fdbsyncd also independently receives netlink events for VXLAN FDB operations.

---

### 1.6 neighsyncd — Kernel Netlink Neighbor Events (INDEPENDENT of syncd)

**Wait function**: neighsyncd's main select loop
- File: `src/sonic-swss/neighsyncd/neighsyncd.cpp:65`
- Netlink: `netlink.registerGroup(RTNLGRP_NEIGH)` — subscribes to neighbor events
- Dump: `netlink.dumpRequest(RTM_GETNEIGH)` (line 67)

**Direct-from-syncd?**: **NO** — neighsyncd receives kernel netlink events for neighbor changes (`RTM_NEWNEIGH`/`RTM_DELNEIGH`). These originate from the kernel's ARP/NDP tables, not directly from the ASIC.

---

### 1.7 teamsyncd — Kernel Netlink Link Events (INDEPENDENT of syncd)

**Wait function**: teamsyncd's main select loop
- File: `src/sonic-swss/teamsyncd/teamsyncd.cpp:51`
- Netlink: `netlink.registerGroup(RTNLGRP_LINK)`
- Dump: `netlink.dumpRequest(RTM_GETLINK)` (line 52)

**Direct-from-syncd?**: **NO** — receives kernel netlink events for team/link state changes. Filters for team driver (`TEAM_DRV_NAME = "team"`) in `TeamSync::onMsg()`.

---

### 1.8 natsyncd — Netfilter Conntrack Events (INDEPENDENT of syncd)

**Wait function**: natsyncd's main select loop
- File: `src/sonic-swss/natsyncd/natsyncd.cpp:66-68`
- Uses `NfNetlink` (netfilter netlink, NOT rtnetlink); file: `src/sonic-swss-common/common/nfnetlink.cpp:16`
- `NFNLGRP_CONNTRACK_NEW`, `NFNLGRP_CONNTRACK_UPDATE`, `NFNLGRP_CONNTRACK_DESTROY`
- Dump: `nfnl.dumpRequest(IPCTNL_MSG_CT_GET)` (line 71)

**Direct-from-syncd?**: **NO** — receives netfilter conntrack events from the Linux kernel, completely independent of syncd/SAI.

---

### 1.9 fpmsyncd — Kernel Netlink AND FPM (TCP from zebra)

**Wait function**: fpmsyncd's main select loop
- File: `src/sonic-swss/fpmsyncd/fpmsyncd.cpp:95-102`
- Netlink: `netlink.registerGroup(RTNLGRP_LINK)`
- FPM TCP server: `FpmLink` accepts connections from FRR's zebra on `127.0.0.1:2620`
- Registered message handlers: `RTM_NEWROUTE`, `RTM_DELROUTE`, `RTM_NEWLINK`, `RTM_DELLINK`, `RTM_NEWTFILTER`, `RTM_DELTFILTER`

**Direct-from-syncd?**: **NO** — fpmsyncd's route information comes from FRR's zebra via the FPM protocol (TCP). The netlink socket is for monitoring interface state and kernel routing changes, not syncd notifications.

---

### 1.10 linkmgrd — Kernel Netlink Neighbor Events (INDEPENDENT)

**Wait function**: linkmgrd's DbInterface select loop
- File: `src/linkmgrd/src/DbInterface.cpp:1856`
- Netlink: `netlinkNeighbor.registerGroup(RTNLGRP_NEIGH)`

**Direct-from-syncd?**: **NO**

---

### 1.11 orchagent (via syncd) — Other ASIC Notifications

All received through the sairedis notification callback:
- File: `src/sonic-sairedis/lib/RedisRemoteSaiInterface.cpp:2308` — `handleNotification()`
- **BFD session state**: `bfdorch.cpp:64` — `ASIC_DB NOTIFICATIONS` consumer
- **ICMP echo session**: `icmporch.cpp:60` — `ASIC_DB NOTIFICATIONS` consumer
- **Switch state change**: `notifications.cpp` — `ASIC_DB NOTIFICATIONS` consumer
- **Queue PFC deadlock**: `notifications.cpp` — `ASIC_DB NOTIFICATIONS` consumer
- **Port Host TX Ready**: `portsorch.cpp:1111-1120` — `port_host_tx_ready` op on same NOTIFICATIONS channel

All are **direct-from-syncd?**: **YES** — all originate from syncd's `NotificationProcessor` → `RedisNotificationProducer`

---

### 1.12 COPP trap / sFlow / psample — genetlink (genl-packet module)

**Wait function**: countersyncd (Rust) uses genetlink
- File: `src/sonic-swss/crates/countersyncd/src/main.rs:354`
- Uses `get_genl_family_group()` to find and subscribe to a genetlink family + multicast group
- File: `src/sonic-genl-packet/libgenl-packet/genl-packet/prepare_netlink.h:35`
- Calls `genl_connect(nlsock)` on a genetlink socket

**Direct-from-syncd?**: **NO** — this is a kernel genetlink path for COPP/sFlow sampled packet data. The `sonic-genl-packet` kernel module creates a genetlink family; userspace subscribes via `genl_connect()`.

---

### 1.13 NetMsgRegistrar (VS only — monitors kernel netlink for virtual switch)

**Wait function**: `NetMsgRegistrar::run()` — `swss::Select::select()`
- File: `src/sonic-sairedis/vslib/NetMsgRegistrar.cpp:125`
- Netlink: `netlink.registerGroup(RTNLGRP_LINK)` (line 115)
- Runs in a dedicated thread (`m_thread`, line 19)
- Receives `RTM_NEWLINK`/`RTM_DELLINK` and dispatches to registered callbacks

**Direct-from-syncd?**: **NO** — this is a netlink listener in the VS syncd process, used to detect kernel netdevice state changes for the virtual switch. It catches netlink events for tap/veth interfaces that the VS itself created.

---

## 2. Netlink Events Enumerated

### 2.1 Class Hierarchy (swss-common)

File: `src/sonic-swss-common/common/`

**Selectable** → base class (`selectable.h`): `virtual int getFd()`, `virtual uint64_t readData()`

**NetLink** (`netlink.cpp:13-106`) — RTNETLINK wrapper:
- Constructor: `nl_socket_alloc()` (line 16), `nl_connect(m_socket, NETLINK_ROUTE)` (line 27)
- `registerGroup(int rtnlGroup)`: `nl_socket_add_membership(m_socket, rtnlGroup)` (line 53)
- `dumpRequest(int rtmGetCommand)`: `nl_rtgen_request(m_socket, rtmGetCommand, AF_UNSPEC, NLM_F_DUMP)` (line 65)
- `readData()`: `nl_recvmsgs_default(m_socket)` (line 86)

**NfNetlink** (`nfnetlink.cpp:13-148`) — NFNETLINK wrapper:
- Constructor: `nl_socket_alloc()` (line 16), `nfnl_connect(m_socket)` (line 22)
- `registerGroup(int nfnlGroup)`: `nl_socket_add_membership(m_socket, nfnlGroup)` (line 81)
- Used only by natsyncd for conntrack events

**NetDispatcher** (singleton, `netdispatcher.cpp`):
- `registerMessageHandler(int nlmsg_type, NetMsg *callback)` — parsed (libnl-object) handlers (line 18)
- `registerRawMessageHandler(int nlmsg_type, NetMsg *callback)` — raw `nlmsghdr` handlers (line 31)
- Dispatch: parsed handler lookup → `nl_msg_parse()` → `callback->onMsg(nlmsg_type, obj)`. If not found, falls through to raw handler lookup → `callback->onMsgRaw(nlmsghdr)` (lines 111-123)

**LinkCache** (singleton, `linkcache.cpp:10`): `nl_socket_alloc()` + `rtnl_link_alloc_cache()` for ifindex-to-name translation

### 2.2 Complete Netlink Group Subscriptions

| Daemon | File:Line | Groups |
|---|---|---|
| portsyncd | `portsyncd.cpp:87` | `RTNLGRP_LINK` |
| neighsyncd | `neighsyncd.cpp:65` | `RTNLGRP_NEIGH` |
| fpmsyncd | `fpmsyncd.cpp:95` | `RTNLGRP_LINK` |
| teamsyncd | `teamsyncd.cpp:51` | `RTNLGRP_LINK` |
| fdbsyncd | `fdbsyncd.cpp:77-79` | `RTNLGRP_LINK`, `RTNLGRP_NEIGH`, `RTNLGRP_NEXTHOP` |
| linkmgrd | `DbInterface.cpp:1856` | `RTNLGRP_NEIGH` |
| hostapdmgr | `hostapdmgr_main.cpp:43` | `RTNLGRP_LINK` |
| fpnim (PAC) | `fpnim.cpp:229` | `RTNLGRP_LINK` |
| natsyncd | `natsyncd.cpp:66-68` | `NFNLGRP_CONNTRACK_NEW`, `NFNLGRP_CONNTRACK_UPDATE`, `NFNLGRP_CONNTRACK_DESTROY` |
| iccpd | `iccp_netlink.c:1742-1764` | `RTNLGRP_NEIGH`, `RTNLGRP_LINK`, `RTNLGRP_IPV4_IFADDR`, `RTNLGRP_IPV6_IFADDR` + generic netlink dynamic group |
| NetMsgRegistrar (VS) | `NetMsgRegistrar.cpp:115` | `RTNLGRP_LINK` |

| Netlink Type | Listener Process | Parser Function | Group | Firing Condition |
|---|---|---|---|---|
| `RTM_NEWLINK` | portsyncd | `LinkSync::onMsg()` (`linksync.cpp:111`) | `RTNLGRP_LINK` | Kernel netdevice created or link state/flags change (e.g. `IFF_RUNNING` toggles) |
| `RTM_DELLINK` | portsyncd | `LinkSync::onMsg()` (`linksync.cpp:111`) | `RTNLGRP_LINK` | Kernel netdevice removed |
| `RTM_NEWLINK` | fpmsyncd | `RouteSync::onMsg()` (`routesync.cpp`) | `RTNLGRP_LINK` | Kernel interface state change (for route next-hop tracking) |
| `RTM_DELLINK` | fpmsyncd | `RouteSync::onMsg()` (`routesync.cpp`) | `RTNLGRP_LINK` | Kernel interface removed |
| `RTM_NEWLINK` | fdbsyncd | fdbsync handler | `RTNLGRP_LINK` | VXLAN interface discovery |
| `RTM_NEWLINK` | teamsyncd | `TeamSync::onMsg()` (`teamsync.cpp`) | `RTNLGRP_LINK` | Team/LAG interface state changes |
| `RTM_DELLINK` | teamsyncd | `TeamSync::onMsg()` (`teamsync.cpp`) | `RTNLGRP_LINK` | Team/LAG interface removal |
| `RTM_NEWLINK` | NetMsgRegistrar | `NetMsgRegistrar::onMsg()` (`NetMsgRegistrar.cpp:140`) | `RTNLGRP_LINK` | VS-only: kernel netdevice state for virtual switch |
| `RTM_DELLINK` | NetMsgRegistrar | `NetMsgRegistrar::onMsg()` (`NetMsgRegistrar.cpp:140`) | `RTNLGRP_LINK` | VS-only: kernel netdevice removal |
| `RTM_NEWLINK` | pac/fpinfra (`fpnim.cpp`) | fpnim handler | `RTNLGRP_LINK` | DPU/SmartNIC port link events |
| `RTM_NEWLINK` | pac/hostapdmgr (`hostapdmgr_main.cpp`) | hostapd manager handler | `RTNLGRP_LINK` | HostAPD interface events |
| `RTM_NEWROUTE` | fpmsyncd | `RouteSync::onMsg()` (`routesync.cpp:633`) | `RTNLGRP_LINK` | Kernel route added (received via FPM TCP or netlink) |
| `RTM_DELROUTE` | fpmsyncd | `RouteSync::onMsg()` (`routesync.cpp:633`) | `RTNLGRP_LINK` | Kernel route removed |
| `RTM_NEWNEIGH` | neighsyncd | `NeighSync::onMsg()` (`neighsync.cpp`) | `RTNLGRP_NEIGH` | Kernel ARP/NDP neighbor added |
| `RTM_DELNEIGH` | neighsyncd | `NeighSync::onMsg()` (`neighsync.cpp`) | `RTNLGRP_NEIGH` | Kernel ARP/NDP neighbor removed |
| `RTM_NEWNEIGH` (raw) | fdbsyncd | fdbsync raw handler | `RTNLGRP_NEIGH` | VXLAN FDB neighbor create (raw) |
| `RTM_DELNEIGH` (raw) | fdbsyncd | fdbsync raw handler | `RTNLGRP_NEIGH` | VXLAN FDB neighbor delete (raw) |
| `RTM_NEWNEXTHOP` (raw) | fdbsyncd | L2 NHG handler | `RTNLGRP_NEXTHOP` | L2 nexthop group create |
| `RTM_DELNEXTHOP` (raw) | fdbsyncd | L2 NHG handler | `RTNLGRP_NEXTHOP` | L2 nexthop group delete |
| `RTM_NEWNEXTHOP` (raw) | fpmsyncd (via FPM) | `RouteSync::onMsg()` (`routesync.cpp:2428`) | N/A (FPM-encapsulated) | NHG from zebra |
| `RTM_DELNEXTHOP` (raw) | fpmsyncd (via FPM) | `RouteSync::onMsg()` (`routesync.cpp:2429`) | N/A (FPM-encapsulated) | NHG delete from zebra |
| `RTM_NEWTFILTER` | fpmsyncd | `RouteSync::onMsg()` (`routesync.cpp:2109`) | `RTNLGRP_LINK` | EVPN split-horizon traffic filter |
| `RTM_DELTFILTER` | fpmsyncd | `RouteSync::onMsg()` | `RTNLGRP_LINK` | EVPN SH filter removed |
| `RTM_GETLINK` (dump) | portsyncd, fpmsyncd, teamsyncd | `NetLink::dumpRequest()` (`netlink.cpp:63`) | N/A (dump request) | Initial state sync at daemon startup |
| `RTM_GETNEIGH` (dump) | neighsyncd | `NetLink::dumpRequest()` | N/A (dump request) | Initial neighbor state sync |
| `IPCTNL_MSG_CT_NEW` (nfnetlink) | natsyncd | `NatSync::onMsg()` (`natsync.cpp:262`) | `NFNLGRP_CONNTRACK_NEW` | Netfilter conntrack entry created → NAT entry add |
| `IPCTNL_MSG_CT_DELETE` (nfnetlink) | natsyncd | `NatSync::onMsg()` (`natsync.cpp:288`) | `NFNLGRP_CONNTRACK_*` | Netfilter conntrack entry destroyed → NAT entry remove |
| `RTM_NEWNEIGH` (manual send) | nbrmgr (cfgmgr) | `nbrmgr.cpp:126` — constructs and sends | N/A (sender) | Sends neighbor proxy ND entry to kernel |
| `RTM_NEWADDR` | iccpd | `iccp_netlink.c:1477` | `RTNLGRP_IPV4_IFADDR`, `RTNLGRP_IPV6_IFADDR` | IP address change for MC-LAG |
| `RTM_DELADDR` | iccpd | `iccp_netlink.c:1477` | same groups | IP address removal for MC-LAG |

### 2.4 Custom FPM message types (FRR → fpmsyncd via FPM TCP)

These are FPM-encapsulated netlink messages sent by FRR's dplane_fpm_sonic plugin over TCP to fpmsyncd. They use custom `nlmsg_type` values in the range 1000-3000 and 140-148:

| Message Type | Numeric Value | Handler | Purpose |
|---|---|---|---|
| `RTM_NEWSRV6LOCALSID` | 1000 | `RouteSync::onMsgRaw()` (`routesync.cpp:2478`) | SRv6 MySID entry add |
| `RTM_DELSRV6LOCALSID` | 1001 | `RouteSync::onMsgRaw()` | SRv6 MySID entry delete |
| `RTM_NEWPICCONTEXT` | 2000 | `RouteSync::onMsgRaw()` | SRv6 PIC context add |
| `RTM_DELPICCONTEXT` | 2001 | `RouteSync::onMsgRaw()` | SRv6 PIC context delete |
| `RTM_NEWSRV6VPNROUTE` | 3000 | `RouteSync::onMsgRaw()` | SRv6 VPN route add |
| `RTM_DELSRV6VPNROUTE` | 3001 | `RouteSync::onMsgRaw()` | SRv6 VPN route delete |
| `RTM_FPM_ADD_EVPN_SHL` | 143 | `RouteSync::onMsgRaw()` (`routesync.cpp:2438`) | EVPN split horizon add |
| `RTM_FPM_DEL_EVPN_SHL` | 144 | `RouteSync::onMsgRaw()` | EVPN split horizon delete |
| `RTM_FPM_ADD_EVPN_DF` | 145 | `RouteSync::onMsgRaw()` | EVPN designated forwarder add |
| `RTM_FPM_DEL_EVPN_DF` | 146 | `RouteSync::onMsgRaw()` | EVPN designated forwarder delete |
| `RTM_FPM_ADD_EVPN_ES_BACKUP_NHG` | 147 | `RouteSync::onMsgRaw()` | EVPN ES backup NHG add |
| `RTM_FPM_DEL_EVPN_ES_BACKUP_NHG` | 148 | `RouteSync::onMsgRaw()` | EVPN ES backup NHG delete |

---

## 3. Port Link State Change — Order of Operations (with evidence)

### THE ORDER in this codebase:

**For hardware platforms (Broadcom, Mellanox, etc.): The SAI callback and kernel netlink are PARALLEL paths that fire from the same physical event, with the kernel netlink typically arriving first because the vendor kernel driver gets the interrupt before SAI processes it.**

**For virtual switch (VS): The SAI path happens FIRST, and the kernel netlink is a CONSEQUENCE of the SAI notification.**

Here is the complete evidence:

### Path A — SAI Notification (syncd → orchagent)

**Registration**: Callbacks bound in `Syncd` constructor
- `src/sonic-sairedis/syncd/Syncd.cpp:221`:
  ```cpp
  m_sn.onPortStateChange = std::bind(&NotificationHandler::onPortStateChange,
      m_handler.get(), _1, _2);
  ```
- `src/sonic-sairedis/syncd/Syncd.cpp:237`:
  ```cpp
  m_handler->setSwitchNotifications(m_sn.getSwitchNotifications());
  ```
- The `sai_switch_notifications_t` struct is passed to `sai_create_switch()` during switch initialization. At that point, `updateNotificationsPointers()` (`NotificationHandler.cpp:64-81`) replaces any vendor-provided pointers with syncd's own.

**Flow when port changes**:
1. `SwitchNotifications::SlotBase::onPortStateChange()` — `SwitchNotifications.cpp:61-69`
2. `NotificationHandler::onPortStateChange()` — `NotificationHandler.cpp:109-120`
3. Serialized, enqueued → `NotificationProcessor` thread wakes up
4. `NotificationProcessor::process_on_port_state_change()` — `NotificationProcessor.cpp:491-565`
   - RID→VID translation (line 519)
   - Link event damping check (line 534)
   - If not suppressed: `sendNotification(SAI_SWITCH_NOTIFICATION_NAME_PORT_STATE_CHANGE, s)` (line 559)
5. `RedisNotificationProducer::send()` — `RedisNotificationProducer.cpp:19-29`
   - Publishes to Redis: `ASIC_DB NOTIFICATIONS` channel

**Receiving side (orchagent)**:
1. `PortsOrch` constructor at `portsorch.cpp:1097-1106` creates a `NotificationConsumer` on `ASIC_DB` listening for `NOTIFICATIONS` with op-allowlist `{"port_state_change"}`
2. `PortsOrch::doTask(NotificationConsumer&)` — `portsorch.cpp:9865`
3. `PortsOrch::handleNotification()` — `portsorch.cpp:9889-9959`
   - Parses port oper status from syncd's notification
   - Calls `updatePortOperStatus(port, status)` (line 9919)
4. `PortsOrch::updatePortOperStatus()` — `portsorch.cpp:10027`
   - Calls `updateDbPortOperStatus()` → writes `oper_status` to STATE_DB `PORT_TABLE` (`m_portTable`)
   - Calls `setHostIntfsOperStatus(port, isUp)` (line 10071)
5. `PortsOrch::setHostIntfsOperStatus()` — `portsorch.cpp:3887`
   - Calls `sai_hostif_api->set_hostif_attribute(port.m_hif_id, SAI_HOSTIF_ATTR_OPER_STATUS, isUp)` (line 3895)
   - **This SAI call goes through the sairedis client → syncd → vendor SAI → kernel driver, which updates the netdev's operstate**

### Path B — Kernel Netlink (kernel → portsyncd)

**Registration**:
- `portsyncd.cpp:84-87`:
  ```cpp
  NetLink netlink;                          // line 84
  netlink.registerGroup(RTNLGRP_LINK);      // line 87
  netlink.dumpRequest(RTM_GETLINK);          // line 88
  ```
- `portsyncd.cpp:94-95`:
  ```cpp
  NetDispatcher::getInstance().registerMessageHandler(RTM_NEWLINK, &sync);
  NetDispatcher::getInstance().registerMessageHandler(RTM_DELLINK, &sync);
  ```

**Flow when netlink fires**:
1. `NetLink::readData()` — `netlink.cpp:80` → `nl_recvmsgs_default(m_socket)` (line 86)
2. `NetLink::onNetlinkMsg()` — `netlink.cpp:102` → `NetDispatcher::onNetlinkMessage(msg)` (line 104)
3. `LinkSync::onMsg()` — `linksync.cpp:111`
   - Reads `flags = rtnl_link_get_flags(link)` (line 129)
   - Extracts: `admin = flags & IFF_UP`, `oper = flags & IFF_RUNNING` (lines 130-131)
   - Writes to STATE_DB: `m_statePortTable.set(key, vector)` with field `netdev_oper_status` = `oper ? "up" : "down"` (line 201)

### Evidence of parallelism — portsyncd does NOT wait for syncd notifications

portsyncd's select loop (`portsyncd.cpp:99-145`) only has ONE selectable: the netlink socket (`s.addSelectable(&netlink)` at line 97). There is NO Redis consumer for syncd notifications in portsyncd. portsyncd's `LinkSync::onMsg()` is a `NetMsg` handler — it extends `NetMsg`, not any Redis consumer.

In the supervisor config (`dockers/docker-orchagent/supervisord.conf.common.j2:54-71`), portsyncd has `dependent_startup_wait_for` pointing to `rsyslogd:running`, NOT to syncd. It has NO explicit dependency on syncd startup.

### ZMQ MODE EXCEPTION

When using ZMQ communication mode (`SAI_REDIS_COMMUNICATION_MODE_ZMQ_SYNC`), orchagent's `on_port_state_change()` callback in `notifications.cpp:29-41` FORWARDS the SAI callback directly to Redis `NOTIFICATIONS`:
```cpp
void on_port_state_change(uint32_t count, sai_port_oper_status_notification_t *data)
{
    if (gRedisCommunicationMode == SAI_REDIS_COMMUNICATION_MODE_ZMQ_SYNC)
    {
        swss::DBConnector db("ASIC_DB", 0);
        swss::NotificationProducer port_state_change(&db, "NOTIFICATIONS");
        std::string sdata = sai_serialize_port_oper_status_ntf(count, data);
        port_state_change.send("port_state_change", sdata, values);
    }
}
```
The comment at line 22-27 explains: "Don't perform DB operations within this event handler, because it runs by libsairedis in a separate thread which causes concurrency issues." This forwarding path exists only as a ZMQ→Redis bridge.

### DETERMINATION: Which fires first?

**Hardware platforms (real ASIC):**
Both paths fire from the same physical link event. The kernel driver receives the PCIe interrupt → updates netdev `IFF_RUNNING` flag → kernel emits `RTM_NEWLINK` → portsyncd. The SAI notification callback also fires from the same interrupt, but goes through the vendor SAI → syncd → Redis pubsub → orchagent. The kernel netlink path is typically nanoseconds faster because it avoids the userspace SAI serialization/Redis round-trip.

**Virtual switch (VS):**
The SAI path fires FIRST. The `send_port_oper_status_notification()` in `src/sonic-sairedis/vslib/SwitchStateBaseHostif.cpp:136-194` explicitly calls `meta->meta_sai_on_port_state_change(1, &data)` (line 152) to fire the SAI notification. The kernel netdevice operstate update happens as a CONSEQUENCE of `setHostIntfsOperStatus()` → `SAI_HOSTIF_ATTR_OPER_STATUS` → `vs_create_hostif_tap_interface()` which the VS handles internally.

---

## 4. CPU Punt Path

**The packet reaches the kernel AFTER passing through the SAI hostif mechanism. The packet does NOT arrive at the kernel first as a direct RX on a physical netdevice.**

Key architecture evidence: syncd explicitly sets `on_packet_event = nullptr` in its notification registration (`src/sonic-sairedis/syncd/SwitchNotifications.h:156`). syncd never receives data packets from the ASIC — it only handles switch notifications (FDB events, port state changes, switch shutdown).

### 4.1 SAI hostif types

Three hostif types are defined in `src/sonic-sairedis/SAI/inc/saihostif.h:848-859`:

| Type | Enum Value | Description |
|---|---|---|
| `SAI_HOSTIF_TYPE_NETDEV` | 0 (line 851) | Creates a Linux netdevice (TAP). Packets appear as regular ingress traffic in the kernel. |
| `SAI_HOSTIF_TYPE_FD` | 1 (line 854) | Delivers packets to userspace via file descriptor/callback directly. |
| `SAI_HOSTIF_TYPE_GENETLINK` | 2 (line 857) | Delivers packets via generic netlink socket; typically created by vendor kernel driver. |

### 4.2 Hostif creation (orchagent → SAI)

When a port is created, orchagent creates a SAI hostif object:

- File: `src/sonic-swss/orchagent/portsorch.cpp:7211-7290`
- `sai_hostif_api->create_hostif()` is called with:
  - `SAI_HOSTIF_TYPE_NETDEV` — creates a kernel netdevice (line 7211)
  - `SAI_HOSTIF_ATTR_OBJ_ID` = port_oid (the SAI port object)
  - `SAI_HOSTIF_ATTR_NAME` = port name (e.g., "Ethernet0")

This is a sairedis-wrapped call → syncd → vendor SAI → kernel driver creates the netdevice.

### 4.2 Hostif operstatus (orchagent → syncd → kernel)

When port state changes:
- `PortsOrch::setHostIntfsOperStatus()` (`portsorch.cpp:3887`) calls `sai_hostif_api->set_hostif_attribute(port.m_hif_id, SAI_HOSTIF_ATTR_OPER_STATUS, isUp)` (line 3895)
- This goes through sairedis → syncd → vendor SAI, which updates the kernel netdevice's operational state

### 4.3 Packet reception from ASIC (vendor SAI callback → kernel)

The SAI API defines a `recv_hostif_packet` callback in the hostif API:
- File: `src/sonic-sairedis/SAI/inc/saihostif.h:1365-1377`:
  ```c
  typedef sai_status_t (*sai_recv_hostif_packet_fn)(
      _In_ sai_object_id_t hostif_id,
      _Inout_ void *buffer,
      _Inout_ sai_size_t *buffer_size,
      _Inout_ uint32_t *attr_count,
      _Inout_ sai_attribute_t *attr_list);
  ```
- This callback is part of `sai_hostif_api_t` (line 1474): `recv_hostif_packet`

When the ASIC traps a packet and sends it to the CPU, the vendor SAI library calls this registered callback. syncd or the host application processes the packet and delivers it to the kernel netdevice.

### 4.4 Virtual switch packet path (VS)

For the virtual switch, the hostif mechanism is implemented in userspace:

1. **Tap device creation**: `SwitchStateBase::vs_create_hostif_tap_device()` (`src/sonic-sairedis/vslib/SwitchStateBaseHostif.cpp:41-78`)
   - Opens `/dev/net/tun` (line 49) and creates a TAP device via `ioctl(fd, TUNSETIFF, ...)` (line 66)
   - This creates a kernel-side tap interface

2. **Packet forwarding threads**: `HostInterfaceInfo` (`src/sonic-sairedis/vslib/HostInterfaceInfo.h`)
   - `tap2veth_fun()` thread: Reads packets from the TAP device (kernel→ASIC direction). Packets injected into the TAP device by the kernel appear here and are forwarded to the virtual "ASIC" data path
   - `veth2tap_fun()` thread: Writes packets to the TAP device (ASIC→kernel direction). Packets from the virtual "ASIC" that need to go to the CPU are written to the TAP device, which makes them appear as ingress on the kernel netdevice
   - `runThreads()` at `HostInterfaceInfo.h:58` and `SwitchStateBaseHostif.cpp:511`: `m_hostif_info_map[tapname]->runThreads()`

3. **Packet receive from ASIC**: The virtual switch processes the packet through its forwarding pipeline. When a packet matches a trap action, `tap2veth_fun()` writes it to the TAP fd, which delivers it to the Linux kernel network stack as an RX packet on the tap netdevice.

### 4.7 Trap configuration (CoppOrch — the central CoPP orchestrator)

The `CoppOrch` class (`src/sonic-swss/orchagent/copporch.h`) is the central control-plane policy orchestrator. It maps CoPP trap rules from Redis `COPP_TABLE` to SAI objects.

**Key data structures** (`copporch.h:71-101`):
- `m_trap_group_map`: trap group name → SAI trap group OID
- `m_trap_group_policer_map`: trap group OID → policer object
- `m_syncdTrapIds`: maps trap type → `copp_trap_objects` (trap OID, trap group OID)

**Trap creation** (`copporch.cpp:500-533` — `CoppOrch::applyAttributesToTrapIds`):
```cpp
sai_status_t status = sai_hostif_api->create_hostif_trap(&hostif_trap_id, gSwitchId, ...);
```
Each of the 44 trap types (defined in the `trap_id_map` at `copporch.cpp:55-99`) is created as a separate SAI hostif trap object. Trap IDs include: `stp`, `lacp`, `lldp`, `arp_req`, `arp_resp`, `dhcp`, `bgp`, `bgpv6`, `ospf`, `ospfv6`, `isis`, `ip2me`, `ssh`, `snmp`, `bfd`, `bfdv6`, `ttl_error`, `l3_mtu_error`, `sample_packet` (for sFlow), and many more.

**Genetlink CoPP path** (`copporch.cpp:657-679` — `CoppOrch::createGenetlinkHostIf`):
- Creates hostif with `SAI_HOSTIF_TYPE_GENETLINK`, `SAI_HOSTIF_ATTR_NAME` = genetlink family name (e.g., `"psample"`), and `SAI_HOSTIF_ATTR_GENETLINK_MCGRP_NAME` = multicast group name
- Creates hostif table entry (`copporch.cpp:419-471`) mapping trap → hostif → `SAI_HOSTIF_TABLE_ENTRY_CHANNEL_TYPE_GENETLINK`
- This is used for sFlow sampled packets and P4 ACL punt rules

**Schema constants** (`copporch.h:26-46`):
```cpp
const std::string copp_genetlink_name      = "genetlink_name";
const std::string copp_genetlink_mcgrp_name = "genetlink_mcgrp_name";
```

### 4.8 End-to-end punt path summary

```
                              ┌──────────────────────┐
                              │    ASIC Hardware      │
                              │  (packet classifier)   │
                              │  matches trap rule     │
                              └──────────┬───────────┘
                                         │
                                         ▼
                              ┌──────────────────────┐
                              │   Vendor SAI / SDK    │
                              │  (closed-source, runs │
                              │   in syncd container   │
                              │   or kernel driver)    │
                              └──────────┬───────────┘
                                         │
                    ┌────────────────────┼────────────────────┐
                    │                    │                    │
                    ▼                    ▼                    ▼
            ┌──────────────┐   ┌──────────────┐   ┌──────────────┐
            │ NETDEV path   │   │  GENETLINK    │   │    FD path   │
            │ (Control plane│   │  (sFlow/COPP  │   │ (Direct      │
            │  protocols)   │   │   sampled)    │   │  userspace)  │
            └──────┬───────┘   └──────┬───────┘   └──────┬───────┘
                   │                  │                  │
                   ▼                  ▼                  ▼
            ┌──────────────┐   ┌──────────────┐   ┌──────────────┐
            │ Kernel TAP    │   │ Generic      │   │ Application  │
            │ device (e.g., │   │ Netlink      │   │ fd/callback  │
            │ Ethernet0)    │   │ socket       │   │              │
            └──────┬───────┘   └──────┬───────┘   └──────────────┘
                   │                  │
                   ▼                  ▼
            ┌──────────────┐   ┌──────────────┐
            │ Linux Network │   │ counteryncd  │
            │ Stack         │   │ (Rust) reads │
            │ (protocol     │   │ genl messages │
            │  handlers:    │   │ for HFT data) │
            │  STP, LACP,   │   └──────────────┘
            │  LLDP, ARP,   │
            │  DHCP, BGP,   │
            │  OSPF, etc.)  │
            └──────────────┘
```

**Note**: syncd explicitly sets `on_packet_event = nullptr` in `SwitchNotifications.h:156` — it does NOT receive data packets. Only notifications (FDB events, port state changes, switch state) pass through syncd. The actual data packet delivery from ASIC to OS is handled entirely by the vendor SAI library/kernel driver, not by syncd's code.

---

## 5. Missing / Unconfirmed

### Files expected but NOT FOUND:

1. **A dedicated packet receive thread in syncd for hostif packets**: Confirmed absent — `SwitchNotifications.h:156` sets `on_packet_event = nullptr`. syncd does NOT register a packet receive callback with SAI. The actual packet delivery from ASIC to OS is handled entirely by the vendor SAI library/kernel driver.

2. **syncd registering `sai_recv_hostif_packet` callback**: The SAI hostif API function pointer table includes `recv_hostif_packet` (`saihostif.h:1474`), but syncd never registers it. The DASH SAI implementation also sets it to 0 (`dash-sai/DASH/dash-pipeline/SAI/lib/sai_dash_hostif.cpp:17`). This callback may be registered by vendor-specific components outside this workspace.

3. **A netlink message handler for `RTM_NEWADDR`/`RTM_DELADDR` in core SONiC daemons**: Only `iccpd` (`src/iccpd/src/iccp_netlink.c:1477,1503`) handles these — for MC-LAG address tracking. No core SWSS daemon subscribes to address change events. FRR/zebra handles them separately.

4. **A netlink handler for `RTM_NEWQDISC`/`RTM_DELQDISC`**: No qdisc handlers found in any SONiC daemon.

5. **`intfmgrd` as a netlink listener**: Confirmed — intfmgrd (`src/sonic-swss/cfgmgr/intfmgrd.cpp`) does NOT create any netlink socket. It is a CONFIG_DB→APP_DB producer. It calls `ip addr add` via shell exec but does not listen for address events.

6. **The `sairedis` library registration of `recv_hostif_packet`**: The `sai_hostif_api_t` struct in `saihostif.h:1474` defines `recv_hostif_packet` callback pointer. The DASH SAI stub sets it to 0 (`dash-sai/DASH/dash-pipeline/SAI/lib/sai_dash_hostif.cpp:17`). In the syncd codebase, `on_packet_event = nullptr` at `SwitchNotifications.h:156`. The registration of this callback is in the vendor's closed-source SAI library.

7. **Neighsyncd's nlmsg_type dispatch**: `NeighSync::onMsg()` at `neighsync.cpp:151-346` dispatches on `RTM_NEWNEIGH`, `RTM_GETNEIGH`, `RTM_DELNEIGH` (lines 163-165). It writes neighbor entries to `APP_DB NEIGH_TABLE` with fields `family` and `neigh`. For EVPN, deletes host routes on neighbor removal.

8. **Private netlink sockets for link cache**: Both `NeighSync` (`neighsync.cpp:45`) and `RouteSync` (`routesync.cpp:186`) maintain private `NETLINK_ROUTE` sockets with `rtnl_link_alloc_cache()` for ifindex-to-name lookups — not for event listening.

9. **iccpd's comprehensive netlink support**: `iccpd` (`src/iccpd/src/iccp_netlink.c`) has the most comprehensive netlink coverage of any SONiC daemon, using TWO route sockets (one sender, one listener) and TWO generic netlink sockets. It is the only process subscribing to `RTNLGRP_IPV4_IFADDR` and `RTNLGRP_IPV6_IFADDR` (lines 1756, 1762) for MC-LAG address synchronization.

### Claims that could NOT be fully verified in code:

1. **Whether the kernel driver's `IFF_RUNNING` update and the SAI port-state-change notification are truly simultaneous or one always precedes the other on hardware platforms** — This depends on the vendor's closed-source SAI library and kernel driver, which are not in this workspace. The SONiC-side code shows both paths exist independently, but the relative timing cannot be confirmed from this codebase alone.

2. **The exact mechanism by which a vendor SAI delivers hostif packets to the kernel netdevice** — The SAI API defines `recv_hostif_packet` as a callback from the vendor SAI to the application. The application (or syncd) would then inject the packet into the kernel netdevice. This injection code was not found in syncd's source (it may be in the vendor SAI library or a different component not in this workspace).

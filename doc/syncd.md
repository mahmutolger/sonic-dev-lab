# Syncd — SONiC SAI-to-ASIC Sync Daemon

> *Generated from source analysis of `src/sonic-sairedis/syncd/` and SONiC architecture documentation. All claims cite specific file/class locations.*

---

## 1. What Syncd Is

**Syncd** (`syncd`) is the daemon process that bridges the gap between Redis-based ASIC state representation and the vendor-specific SAI (Switch Abstraction Interface) library. It runs inside the **`syncd`** Docker container and is the sole process in SONiC that loads the vendor `.so` SAI implementation and directly calls SAI C APIs against the ASIC hardware.

In the SONiC architecture, syncd sits at the **very bottom** of the software stack — below orchagent, below the sairedis library, and directly above the ASIC SDK:

```
  orchagent (swss container)
       │ writes ASIC state as Redis hashes into...
       ▼
  ┌──────────────┐
  │   ASIC_DB     │  Redis database
  │  (redis-server)│
  └──────┬───────┘
         │ consumed via SelectableChannel (Redis or ZMQ)
         ▼
  ┌──────────────┐
  │    syncd      │  ← THIS PROCESS (inside syncd Docker container)
  │   (syncd      │
  │    daemon)    │
  └──────┬───────┘
         │ dlopen() → vendor_sai.so
         ▼
  ┌──────────────┐
  │ Vendor SAI    │  Dynamically loaded .so (e.g., libsai-brcm.so, mlnx_sai.so)
  │ library (.so) │
  └──────┬───────┘
         │ SAI C API calls
         ▼
  ┌──────────────┐
  │ ASIC SDK /    │
  │ Hardware      │
  └──────────────┘
```

**Key architectural points:**

- Syncd does **not** talk to orchagent directly. It reads ASIC_DB entries written by orchagent's sairedis library. — *`syncd/Syncd.cpp:394-416` — `Syncd::processEvent()` reading from `SelectableChannel`*
- Syncd loads the vendor SAI `.so` via `VendorSai`, which wraps `dlopen`/`dlsym` logic. — *`syncd/VendorSai.h:17-18` — `VendorSai : public sairedis::SaiInterface`*
- Syncd sends hardware notifications (port state changes, FDB events, etc.) back to orchagent via Redis **notification channels** (`NotificationProducerBase`) or ZeroMQ. — *`syncd/Syncd.h:635` — `m_notifications` member; `syncd/NotificationProcessor.h:26` — constructor takes `NotificationProducerBase`*
- The sairedis library (`libsairedis`) is the **client-side** counterpart: orchagent links to it, and it serializes SAI calls into Redis hashes. Syncd links to the vendor SAI directly. — *`README.md:19-22`*

---

## 2. Why SONiC Needs Syncd

The fundamental design decision of SONiC is to keep the ASIC vendor's SDK and SAI library **isolated** in a separate container. Syncd exists to enforce this isolation.

**Problems syncd solves:**

1. **Container-level isolation of vendor binaries**: The vendor SAI `.so` and SDK are complex, large, and potentially unstable. Isolating them in a separate Docker container (`syncd`) prevents crashes or memory corruption in the vendor library from taking down orchagent or other critical SwSS components. — *`syncd/syncd_main.cpp:67` — `VendorSai` created inside syncd process only*

2. **ASIC_DB → SAI API translation**: Orchagent writes abstract key/value tuples like `ASIC_STATE:SAI_OBJECT_TYPE_ROUTE_ENTRY:{"dest":"10.0.0.0/8"}` with fields `{"SAI_ROUTE_ENTRY_ATTR_NEXT_HOP_ID":"oid:0x...", "SAI_ROUTE_ENTRY_ATTR_PACKET_ACTION":"SAI_PACKET_ACTION_FORWARD"}`. Syncd deserializes these, translates Virtual IDs (VIDs) to Real IDs (RIDs), and calls `sai_create_route_entry()`. — *`syncd/Syncd.cpp:4413-4562` — `processQuadEvent()` calling `processEntry()` or `processOid()`*

3. **VID-to-RID translation**: Orchagent uses Virtual Object IDs (VIDs) — deterministic, Redis-friendly identifiers. The vendor SAI uses Real Object IDs (RIDs) — opaque pointers that change every boot. Syncd maintains the bidirectional mapping. — *`syncd/VirtualOidTranslator.h` — `translateVidToRid()`, `translateRidToVid()`*

4. **ASIC hardware event propagation**: When the ASIC generates events (port goes down, MAC address learned, BFD session timeout, PFC deadlock), these arrive as C callbacks from the vendor SAI on a vendor-controlled thread. Syncd's `NotificationHandler` captures them, enqueues them, and `NotificationProcessor` (on a dedicated thread) translates RIDs→VIDs and forwards them to orchagent. — *`syncd/NotificationHandler.h:45-117` — all `on*` callback methods; `syncd/NotificationProcessor.h:70-127` — all `process_on_*` methods*

5. **Warm reboot / fast reboot with data-plane continuity**: Syncd supports restarting the control plane (syncd + orchagent) while the ASIC data plane continues forwarding packets. On warm boot, syncd reconnects to the existing ASIC state without reprogramming it. — *`syncd/Syncd.cpp:5980-6015` — `onSyncdStart(warmStart=true)` calling `performWarmRestart()`*

6. **View comparison and reconciliation**: When orchagent restarts (while syncd keeps running), it builds a new "temporary view" of desired ASIC state. Syncd compares this against the "current view" (actual ASIC state) via `ComparisonLogic`, computing only the delta operations needed. — *`syncd/Syncd.cpp:5706-5855` — `applyView()`; `syncd/ComparisonLogic.h` — class declaration*

---

## 3. Jobs and Responsibilities

### 3.1 Main Event Loop

Syncd's `run()` method uses a `swss::Select`-based event loop with a 1-second timeout, multiplexing four selectables:

```
syncd/Syncd.cpp:6736  Syncd::run()
  while (runMainLoop):
    s->select(&sel, 1000ms)
      ├── sel == m_selectableChannel  → processEvent()     [ASIC operations from orchagent]
      ├── sel == m_restartQuery       → handleRestartQuery() [warm/cold/fast shutdown commands]
      ├── sel == m_flexCounter        → processFlexCounterEvent()
      ├── sel == m_flexCounterGroup   → processFlexCounterGroupEvent()
      └── TIMEOUT                     → processPendingDampingSync() + flushPendingDampingNotifications()
```

**Source:** — *`syncd/Syncd.cpp:6736-7032` — `Syncd::run()`*

### 3.2 ASIC_DB Consumption and SAI Calls

Syncd reads operations from a `SelectableChannel` — either a **Redis-based channel** (`RedisSelectableChannel`) or a **ZeroMQ-based channel** (`ZeroMQSelectableChannel`). Each entry is a key/operation/values tuple:

```
ASIC_STATE:<object_type>:<object_id>  |  (create|remove|set|get)  |  [field=value, ...]
```

The `processSingleEvent()` method dispatches based on the operation string:

| Operation | Handler | What it does |
|---|---|---|
| `create` | `processQuadEvent(SAI_COMMON_API_CREATE)` | Calls `vendorSai->create()` to instantiate an SAI object |
| `remove` | `processQuadEvent(SAI_COMMON_API_REMOVE)` | Calls `vendorSai->remove()` to destroy an SAI object |
| `set` | `processQuadEvent(SAI_COMMON_API_SET)` | Calls `vendorSai->set()` to modify an attribute |
| `get` | `processQuadEvent(SAI_COMMON_API_GET)` | Calls `vendorSai->get()` to read attributes |
| `bulk_create/remove/set/get` | `processBulkQuadEvent()` | Batch SAI operations |
| `notify` | `processNotifySyncd()` | Meta-commands: INIT_VIEW, APPLY_VIEW, INSPECT_ASIC, INVOKE_DUMP |
| `get_stats` | `processGetStatsEvent()` | Poll SAI counter statistics |
| `clear_stats` | `processClearStatsEvent()` | Clear SAI counters |
| `flush` | `processFdbFlush()` | Flush FDB entries |
| `attr_capability_query` | `processAttrCapabilityQuery()` | Query if an attribute is implemented |
| `damping_config_set` | `processLinkEventDampingConfigSet()` | Configure link event damping |

**Source:** — *`syncd/Syncd.cpp:450-536` — `processSingleEvent()` dispatch table*

### 3.3 VID/RID Translation

Every object has two identities:
- **VID** (Virtual ID): a deterministic, fixed-width ID used by orchagent. Encodes switch index, object type, and object index in bit fields. — *`syncd/VidManager.h` — static bit-decode methods*
- **RID** (Real ID): an opaque `sai_object_id_t` assigned by the vendor SAI. Changes every cold boot.

`VirtualOidTranslator` manages bidirectional maps (in-memory for speed, backed by Redis for persistence) and creates new VIDs on demand. — *`syncd/VirtualOidTranslator.h` — `translateVidToRid()`, `translateRidToVid()`, `insertRidAndVid()`*

### 3.4 Notification Processing (Hardware → Orchagent)

Notifications are processed on a **dedicated background thread** to avoid blocking the main event loop:

1. The vendor SAI calls a C callback (e.g., `on_port_state_change`). — *`syncd/SwitchNotifications.h` — `sai_switch_notifications_t` struct with all callback pointers*
2. `NotificationHandler::onPortStateChange()` serializes the data and enqueues it in `NotificationQueue`. — *`syncd/NotificationHandler.h:55-57`*
3. `NotificationProcessor::ntf_process_function()` (background thread) dequeues the notification, translates RIDs to VIDs, applies link event damping, and sends to orchagent via `NotificationProducerBase::send()`. — *`syncd/NotificationProcessor.h:42` — `ntf_process_function()`*

Notifications handled (each with its own handler in `NotificationProcessor`):

| Notification | Handler | Described in |
|---|---|---|
| FDB event (learn/age/flush) | `handle_fdb_event()` | `NotificationProcessor.h:134` |
| NAT event | `handle_nat_event()` | `NotificationProcessor.h:137` |
| Port state change | `handle_port_state_change()` | `NotificationProcessor.h:143` |
| Queue PFC deadlock | `handle_queue_deadlock()` | `NotificationProcessor.h:140` |
| Switch shutdown request | `handle_switch_shutdown_request()` | `NotificationProcessor.h:165` |
| Switch state change | `handle_switch_state_change()` | `NotificationProcessor.h:131` |
| BFD session state change | `handle_bfd_session_state_change()` | `NotificationProcessor.h:146` |
| ICMP echo session state change | `handle_icmp_echo_session_state_change()` | `NotificationProcessor.h:149` |
| TWAMP session event | `handle_twamp_session_event()` | `NotificationProcessor.h:171` |
| ASIC SDK health event | `handle_switch_asic_sdk_health_event()` | `NotificationProcessor.h:162` |
| HA set/scope event | `handle_ha_set_event()`, `handle_ha_scope_event()` | `NotificationProcessor.h:153-156` |
| MACsec POST status | `handle_switch_macsec_post_status()`, `handle_macsec_post_status()` | `NotificationProcessor.h:178-181` |
| Port host TX ready | `handle_port_host_tx_ready_change()` | `NotificationProcessor.h:168` |
| Flow bulk get session | `handle_flow_bulk_get_session_event()` | `NotificationProcessor.h:158` |
| TAM TEL type config | `handle_tam_tel_type_config_change()` | `NotificationProcessor.h:175` |

### 3.5 Warm/Fast-Boot Restart Handling

Syncd supports multiple restart types:

| Restart Type | Behavior | Trigger |
|---|---|---|
| **Cold boot** | Full SAI reinit, all objects created from scratch via `HardReiniter::hardReinit()` | Default; `SAI_START_TYPE_COLD_BOOT` |
| **Warm boot** | ASIC data plane preserved; syncd reconnects via `performWarmRestart()`, discovers existing objects | `SAI_START_TYPE_WARM_BOOT`; orchagent sends `WARM_SHUTDOWN` |
| **Fast boot** | Like warm boot but skips some ASIC reinitialization steps | `SAI_START_TYPE_FAST_BOOT` |
| **Express boot** | Even faster variant using `SAI_SWITCH_ATTR_FAST_API_ENABLE` | `SAI_START_TYPE_EXPRESS_BOOT` |
| **FastFast boot** | Fastest variant; syncd calls `onApplyViewInFastFastBoot()` | `SAI_START_TYPE_FASTFAST_BOOT` |

**Warm restart flow** (from source):

1. `syncd_main()` detects `isWarmStart` via `WarmStart::isWarmStart()`. — *`syncd/syncd_main.cpp:39-43`*
2. `onSyncdStart(true)` calls `performWarmRestart()`. — *`syncd/Syncd.cpp:5980-6015`*
3. `performWarmRestart()` reads existing switch keys from ASIC DB, calls `performWarmRestartSingleSwitch()` for each. — *`syncd/Syncd.cpp:6320-6348`*
4. `performWarmRestartSingleSwitch()` creates the switch via SAI with `SAI_SWITCH_ATTR_INIT_SWITCH=true` on the already-running hardware. — *`syncd/Syncd.cpp:6201-6318`*
5. A `SaiSwitch` object is created in warm-boot mode; its constructor calls `helperDiscover()` to enumerate all already-existing objects on the switch. — *`syncd/SaiSwitch.h:38-39` — constructor signature; `syncd/SaiSwitch.cpp:53` — `helperDiscover()` call*

**WarmRestartTable** records the shutdown status in STATE_DB, so the next syncd can validate whether warm boot data is consistent. — *`syncd/WarmRestartTable.h` — `setPreShutdown()`, `setWarmShutdown()`, `setFlagFailed()`*

### 3.6 View Comparison and Reconciliation (APPLY_VIEW)

When orchagent restarts while syncd keeps running (warm-reboot of swss container only), it initiates an `INIT_VIEW` → `APPLY_VIEW` sequence:

**Phase 1: INIT_VIEW**
- Orchagent sends `notify:SAI_REDIS_NOTIFY_SYNCD_INIT_VIEW`. — *`syncd/Syncd.cpp:5400-5407`*
- Syncd sets `m_asicInitViewMode = true`. — *`syncd/Syncd.cpp:5528`*
- All subsequent operations are written to a **TEMPORARY** ASIC view (a separate Redis table), not applied to the ASIC. — *`syncd/Syncd.cpp:394-416` — `processEvent()` passing `isInitViewMode()`*
- Orchagent builds the complete desired state in the TEMP view.

**Phase 2: APPLY_VIEW**
- Orchagent sends `notify:SAI_REDIS_NOTIFY_SYNCD_APPLY_VIEW`. — *`syncd/Syncd.cpp:5547`*
- Syncd calls `applyView()`: — *`syncd/Syncd.cpp:5706-5855`*
  1. Read **current** ASIC view (actual hardware state) from Redis. — *line 5746*
  2. Read **temporary** ASIC view (desired state) from Redis. — *line 5747*
  3. For each switch, create `ComparisonLogic` with both views. — *line 5803*
  4. **Stage 1 (non-destructive):** `cl->compareViews()` — match objects, compute create/set/remove operations. — *line 5805*
  5. **Stage 2 (destructive):** `cl->executeOperationsOnAsic()` — apply the computed operations to the actual ASIC. — *line 5836*
  6. `updateRedisDatabase()` — sync Redis with the new state. — *line 5839*
  7. Optional consistency check: `cl->checkAsicVsDatabaseConsistency()`. — *line 5845*

**ComparisonLogic** is the heart of reconciliation. It:
- Matches objects between views by RID or by attributes (for non-deterministic IDs like routes and neighbors). — *`syncd/ComparisonLogic.h:45-46` — `matchOids()`*
- Handles **break-before-make** when resources are limited (remove first, then create). — *`syncd/ComparisonLogic.h:148-151` — `breakBeforeMake()`*
- Manages VID reference counting to order creates and removes correctly (dependencies are respected). — *`syncd/AsicView.h:124-143` — `getVidReferenceCount()`, `insertNewVidReference()`*
- Generates an ordered list of `AsicOperation` objects to execute. — *`syncd/AsicView.h:236-240` — `asicGetOperations()`*

### 3.7 Flex Counter Management

Syncd also manages periodic polling of SAI statistics (flex counters). The `FlexCounterManager` manages `FlexCounter` instances that poll counters at configurable intervals:

1. Orchagent writes flex counter configuration to `FLEX_COUNTER_DB`. — *`syncd/Syncd.cpp:6771` — `m_flexCounter` and `m_flexCounterGroup` added to select loop*
2. Syncd's main loop dispatches flex counter events to `processFlexCounterEvent()` / `processFlexCounterGroupEvent()`. — *`syncd/Syncd.cpp:6919-6925`*
3. `FlexCounter` instances call `vendorSai->getStats()` at intervals and write results back to COUNTERS_DB. — *`syncd/FlexCounterManager.h` — `addCounter()`, `removeCounter()`*

### 3.8 Link Event Damping

Syncd implements configurable link event damping to suppress rapid port state flapping:

- Port state changes from SAI go through `NotificationProcessor` → `m_linkEventDampingApplier()` → `Syncd::applyLinkEventDamping()`. — *`syncd/NotificationProcessor.h:26` — constructor parameter; `syncd/NotificationProcessor.h:89-91` — `process_on_port_state_change()`*
- Damping state is maintained per-port in `m_portLinkEventDampingStates`. — *`syncd/Syncd.h:653`*
- A dedicated timer thread periodically checks for ports exceeding `max_suppress_time`. — *`syncd/Syncd.h:280-296` — `dampingTimerThreadFunc()`, `startDampingTimerThread()`*
- Damping counters are published to STATE_DB for monitoring. — *`syncd/Syncd.h:313-315` — `writeDampingCountersToStateDb()`*

---

## 4. Container/Process Interaction Map

| Container / Process | Role | Communicates With Syncd Via | Direction |
|---|---|---|---|
| **syncd** (syncd itself) | Runs syncd; loads vendor SAI `.so`; programs ASIC | N/A (main daemon) | N/A |
| **swss** (orchagent) | Writes desired ASIC state, sends APPLY_VIEW | **ASIC_DB** — orchagent writes via sairedis; syncd reads from `SelectableChannel` (Redis or ZMQ) | orchagent → syncd |
| **swss** (orchagent) | Receives ASIC-originated notifications | **NOTIFICATIONS DB** (Redis) or **ZeroMQ** — syncd publishes via `NotificationProducerBase`; orchagent subscribes | syncd → orchagent |
| **redis-server** | In-memory data store; hosts ASIC_DB, FLEX_COUNTER_DB, STATE_DB | Redis protocol (TCP/unix socket) | Bidirectional |
| **Vendor SAI library** (e.g., `libsai-brcm.so`, `mlnx_sai.so`) | Provides SAI C API; issues notifications via C callbacks | `dlopen()`/`dlsym()` — `VendorSai` loads it dynamically; C callbacks registered via `SwitchNotifications` | Bidirectional (API calls down; callbacks up) |
| **ASIC SDK / Hardware** | Programmed by vendor SAI; generates hardware events | Via vendor SAI (proprietary interfaces) | syncd → SAI → SDK → HW; HW → SDK → SAI → syncd (callbacks) |
| **syncd** (FLEX_COUNTER_DB consumer) | Reads flex counter configuration | `FLEX_COUNTER_DB` (Redis) — ConsumerTable | orchagent → syncd |
| **syncd** (COUNTERS_DB writer) | Writes polled counter values | `COUNTERS_DB` (Redis) — ProducerTable | syncd → telemetry/CLI |
| **syncd** (STATE_DB writer) | Records warm restart status, damping counters | `STATE_DB` (Redis) — Table writes | syncd → state consumers |
| **syncd** (MDIO IPC) | Access PHY registers over MDIO | `MdioIpcServer` — Unix domain socket IPC | syncd ↔ PHY clients |
| **syncd** (diagnostic shell) | Optional vendor-specific CLI for debugging | `SAI_SWITCH_ATTR_SWITCH_SHELL_ENABLE` — blocking SAI call on dedicated thread | Admin → syncd |

**Sources:**
- `syncd/Syncd.h:625-635` — DB connectors: `m_dbAsic`, `m_dbFlexCounter`, `m_flexCounter`, `m_flexCounterGroup`, `m_notifications`
- `syncd/Syncd.cpp:6769-6772` — Selectables registered: `m_selectableChannel`, `m_restartQuery`, `m_flexCounter`, `m_flexCounterGroup`
- `syncd/Syncd.cpp:6351-6395` — Diagnostic shell: `startDiagShell()`, `diagShellThreadProc()`
- `syncd/Syncd.h:593` — MDIO IPC server: `m_mdioIpcServer`

---

## 5. Internal Modules / Classes

All classes run **within the same syncd process**, coordinated by the `Syncd::run()` event loop and the notification processing thread.

### 5.1 Core Orchestration

| Class | File | Base Class | Responsibility |
|---|---|---|---|
| **Syncd** | `syncd/Syncd.h` | *(none)* | Central orchestrator. Main event loop (`run()`), ASIC event dispatching (`processEvent()`, `processSingleEvent()`), VID/RID coordination, warm/cold restart logic, view comparison orchestrator, flex counter management, link event damping coordination |
| **VendorSai** | `syncd/VendorSai.h` | `sairedis::SaiInterface` | Wraps the dynamically-loaded vendor SAI `.so`. Provides the entire SAI C API as C++ virtual methods (create/remove/set/get, bulk, stats, entry operations). Loads the library via `dlopen()`, resolves all SAI API symbols, and manages API initialization via `apiInitialize()` |
| **VidManager** | `syncd/VidManager.h` | *(static only — deleted constructors)* | Utility class for encoding/decoding Virtual Object IDs. Extracts switch index, object type, global context, and object index from VID bit fields using static methods. Pure bit manipulation — no DB access |

### 5.2 SAI Switch Lifecycle

| Class | File | Base Class | Responsibility |
|---|---|---|---|
| **SaiSwitch** | `syncd/SaiSwitch.h` | `SaiSwitchInterface` | Manages a single switch's lifecycle. Handles object discovery after switch init (`helperDiscover()` via `SaiDiscovery`), maintains discovered RIDs and default OID attribute maps, tracks port-related objects (queues, scheduler groups), manages VID↔RID maps, saves discovered objects and lane maps to Redis, supports warm-boot and cold-boot discovered VID tracking |
| **HardReiniter** | `syncd/HardReiniter.h` | *(none)* | Performs hard (cold) reinitialization of switches. Called from `Syncd::onSyncdStart(false)`. Creates switches from scratch by calling `vendorSai->create(SAI_OBJECT_TYPE_SWITCH)` and discovering all objects |
| **SaiSwitchInterface** | `syncd/SaiSwitchInterface.h` | *(none)* | Abstract interface for switch-level operations — provides the contract that `SaiSwitch` implements and that `ComparisonLogic` depends on |

### 5.3 Virtual ID Translation

| Class | File | Base Class | Responsibility |
|---|---|---|---|
| **VirtualOidTranslator** | `syncd/VirtualOidTranslator.h` | *(none)* | Translates between Virtual IDs (VIDs) and Real IDs (RIDs). Maintains bidirectional maps both in-memory and in Redis. Creates new VIDs on demand via `VirtualObjectIdManager`. Handles translation of OID attributes in attribute lists for both directions (VID→RID for SAI calls, RID→VID for notifications). Supports batch operations and lookup of previously-removed objects |

### 5.4 Redis Communication

| Class | File | Base Class | Responsibility |
|---|---|---|---|
| **BaseRedisClient** | `syncd/BaseRedisClient.h` | *(none)* | Abstract interface for all Redis/ASIC DB operations. Declares virtual methods for creating/reading/updating/deleting ASIC state objects, VID/RID maps, lane maps, cold boot VIDs, hidden attributes, and table dumps |
| **RedisClient** | `syncd/RedisClient.h` | `BaseRedisClient` | Full Redis implementation of `BaseRedisClient`. Provides all ASIC_DB CRUD operations: ASIC object creation/removal (single and bulk), VID↔RID map persistence, lane map management, cold boot VID tracking, hidden attribute storage, FDB flush handling, and table dump retrieval for `applyView()` |
| **DisabledRedisClient** | `syncd/DisabledRedisClient.h` | `BaseRedisClient` | No-op implementation of `BaseRedisClient`. Used when Redis is disabled (testing/debug scenarios). All virtual methods are empty stubs returning defaults |
| **RedisNotificationProducer** | `syncd/RedisNotificationProducer.h` | `NotificationProducerBase` | Sends notifications (port state changes, FDB events, etc.) to orchagent via Redis notification channels. Used when `-z redis_async` or `-z redis_sync` is configured |
| **ZeroMQNotificationProducer** | `syncd/ZeroMQNotificationProducer.h` | `NotificationProducerBase` | Sends notifications to orchagent via ZeroMQ PUB/SUB sockets. Used when ZMQ communication mode is configured |

### 5.5 Notification Processing

| Class | File | Base Class | Responsibility |
|---|---|---|---|
| **SwitchNotifications** | `syncd/SwitchNotifications.h` | *(none)* | Wraps the `sai_switch_notifications_t` C struct. Uses a template `Slot<context>` pattern to bridge C static callbacks to C++ `std::function` members. Registers ~17 distinct notification callbacks with the vendor SAI |
| **NotificationHandler** | `syncd/NotificationHandler.h` | *(none)* | Receives SAI notification callbacks from `SwitchNotifications`. Serializes notification data and enqueues it into `NotificationQueue`. Provides one callback method per notification type (onFdbEvent, onPortStateChange, onBfdSessionStateChange, etc.). Holds the `sai_switch_notifications_t` struct |
| **NotificationProcessor** | `syncd/NotificationProcessor.h` | *(none)* | Processes notifications from the `NotificationQueue` in a **dedicated background thread**. Translates RIDs→VIDs, applies link event damping, updates Redis ASIC DB for FDB events, and forwards notifications to orchagent via `NotificationProducerBase`. Handles all notification types (FDB, NAT, port state, BFD, ICMP, TWAMP, etc.) |
| **NotificationQueue** | `syncd/NotificationQueue.h` | *(none)* | Thread-safe bounded queue for notifications. Supports configurable size limits (default 300,000), duplicate event detection (consecutive threshold, default 1,000), and optional auxiliary data (e.g., flow dump JSON payloads). Drops events when full + duplicates detected to prevent memory runaway |
| **PortStateChangeHandler** | `syncd/PortStateChangeHandler.h` | *(none)* | Handles port state change callbacks from SAI. Contains a `SelectableEvent` for cross-thread signaling and a mutex-protected concurrent queue for the notification data (4k max events). Bridges the producer (SAI callback) and consumer (notification processing) threads |
| **NotificationProducerBase** | `syncd/NotificationProducerBase.h` | *(none)* | Abstract interface for sending notifications. Declares `send(notification, data, entry)`. Implemented by `RedisNotificationProducer` and `ZeroMQNotificationProducer` |

### 5.6 Warm Restart and View Comparison

| Class | File | Base Class | Responsibility |
|---|---|---|---|
| **AsicView** | `syncd/AsicView.h` | *(none)* | Represents a snapshot of ASIC database state. Populated from Redis table dumps. Organizes objects by type (OIDs, FDBs, neighbors, routes, NAT entries), maintains VID reference counts for dependency ordering, and generates `AsicOperation` lists (CREATE/SET/REMOVE). Contains both current view and temporary view data during reconciliation |
| **ComparisonLogic** | `syncd/ComparisonLogic.h` | *(none)* | Compares two `AsicView` instances (current vs. temporary) and computes the delta operations to transition from current to desired state. Handles object matching by OID or attributes, dependency-aware ordering, break-before-make for limited resources, default state restoration for non-removable objects, and optional consistency verification. Core of the `applyView()` reconciliation |
| **WarmRestartTable** | `syncd/WarmRestartTable.h` | *(none)* | Manages the warm restart state in STATE_DB. Records pre-shutdown success/failure, final warm shutdown success/failure, and flag-failed status. Consulted by next syncd on warm start to validate warm boot data |
| **SaiObj** | `syncd/SaiObj.h` | *(none)* | Represents a single SAI object in an ASIC view. Holds the object's RID, VID, attributes (as `SaiAttr` instances), and processing status flags (processed/unprocessed) |
| **SaiAttr** | `syncd/SaiAttr.h` | *(none)* | Represents a single SAI attribute value within a `SaiObj`. Stores serialized name/value and provides access to the underlying `sai_attribute_t` |
| **AsicOperation** | `syncd/AsicOperation.h` | *(none)* | Represents a single operation to be executed on the ASIC. Contains a key, operation code, and serialized attribute list (in the same format as SAIREDIS). Generated by `AsicView` methods and executed by `ComparisonLogic::executeOperationsOnAsic()` |
| **BestCandidateFinder** | `syncd/BestCandidateFinder.h` | *(none)* | Finds the best-matching object in the current view for a given temporary view object. Used during `applyViewTransition()` to determine whether to update an existing object or create a new one |
| **AttrVersionChecker** | `syncd/AttrVersionChecker.h` | *(none)* | Checks attribute version compatibility during view comparison. Helps detect when SAI metadata has changed between syncd versions |

### 5.7 Flex Counters

| Class | File | Base Class | Responsibility |
|---|---|---|---|
| **FlexCounterManager** | `syncd/FlexCounterManager.h` | *(none)* | Manages a collection of `FlexCounter` instances. Creates/removes/reconfigures instances by ID, manages counter plugins, and provides bulk counter addition. All operations are mutex-protected |
| **FlexCounter** | `syncd/FlexCounter.h` | *(none)* | A single flex counter instance that polls SAI statistics at a configurable interval. Supports individual and group-based counters, multiple counter IDs per instance, and configurable polling plugins |

### 5.8 Command Line, Configuration, Debug

| Class | File | Base Class | Responsibility |
|---|---|---|---|
| **CommandLineOptions** | `syncd/CommandLineOptions.h` | *(none)* | Holds all parsed command-line options: startup type (cold/warm/fast/express), Redis communication mode, profiling configuration, temp view enable/disable, unit test mode, diagnostic shell, break config, etc. |
| **CommandLineOptionsParser** | `syncd/CommandLineOptionsParser.h` | *(none)* | Parses `argc`/`argv` into a `CommandLineOptions` object |
| **BreakConfig** | `syncd/BreakConfig.h` | *(none)* | Manages breakout configuration for ports (splitting a high-speed port into multiple lower-speed sub-ports) |
| **BreakConfigParser** | `syncd/BreakConfigParser.h` | *(none)* | Parses breakout configuration from the port config file |
| **ServiceMethodTable** | `syncd/ServiceMethodTable.h` | *(none)* | Wraps the SAI service method table (`sai_service_method_table_t`). Uses `Slot<context>` pattern to bridge C callbacks (`profile_get_value`, `profile_get_next_value`) to C++ `std::function` members |
| **TimerWatchdog** | `syncd/TimerWatchdog.h` | *(none)* | Watchdog timer that kills syncd (via `exit()`) if an operation exceeds the timeout. Prevents indefinite hangs on SAI calls |
| **WatchdogScope** | `syncd/WatchdogScope.h` | *(none)* | RAII scope guard for `TimerWatchdog`. Starts the watchdog on construction, stops it on destruction. Used in `processSingleEvent()` around each operation |
| **SelectablesTracker** | `syncd/SelectablesTracker.h` | *(none)* | Keeps track of all `Selectable` objects and their associated `EventHandler` objects. Provides lookup and removal |
| **RequestShutdown** | `syncd/RequestShutdown.h` | *(none)* | Handles shutdown request parsing from the restart query channel. Distinguishes warm/cold/fast/express/pre-shutdown types |
| **PortMap / PortMapParser** | `syncd/PortMap.h`, `syncd/PortMapParser.h` | *(none)* | Maps port names to hardware port indices. Used for Thrift RPC server mode (`SAITHRIFT`) |
| **MetadataLogger** | `syncd/MetadataLogger.h` | *(none)* | Logs SAI metadata information at startup for debugging/audit purposes |
| **Workaround** | `syncd/Workaround.h` | *(none)* | Platform-specific workarounds for vendor SAI quirks |

### 5.9 MDIO IPC

| Class | File | Base Class | Responsibility |
|---|---|---|---|
| **MdioIpcServer** | `syncd/MdioIpcServer.h` | *(none)* | Unix domain socket server that handles MDIO register read/write requests from external PHY management tools. Provides access to PHY registers via `vendorSai->switchMdioRead()` / `switchMdioWrite()` |
| **MdioIpcClient** | `syncd/MdioIpcClient.h` | *(none)* | Client-side counterpart for `MdioIpcServer`. Connects to the MDIO IPC server and issues MDIO requests |

### 5.10 Flow Dump

| Class | File | Base Class | Responsibility |
|---|---|---|---|
| **FlowDump** | `syncd/FlowDump.h` | *(none)* | Manages flow bulk-get session dump data. Handles serialization and deserialization of flow dump JSON payloads that are carried as auxiliary data in `NotificationItem` |

---

## 6. Initialization and Startup Sequence

The syncd startup sequence, traced from code:

```
syncd_main()
  ├── WarmStart::initialize("syncd", "syncd")          [syncd_main.cpp:39]
  ├── WarmStart::checkWarmStart("syncd", "syncd")      [syncd_main.cpp:41]
  ├── MetadataLogger::initialize()                      [syncd_main.cpp:46]
  ├── CommandLineOptionsParser::parseCommandLine()      [syncd_main.cpp:47]
  ├── new VendorSai()                                   [syncd_main.cpp:67]
  │     └── apiInitialize() → dlopen vendor .so        [VendorSai.cpp]
  ├── new Syncd(vendorSai, cmd, isWarmStart)            [syncd_main.cpp:69]
  │     └── performStartupLogic()                       [Syncd.cpp constructor]
  │           ├── loadProfileMap()                      [Syncd.cpp]
  │           ├── create DB connectors (ASIC_DB,        [Syncd.cpp]
  │           │     FLEX_COUNTER_DB, STATE_DB)
  │           ├── new FlexCounterManager()              [Syncd.cpp]
  │           ├── new SwitchNotifications()             [Syncd.cpp]
  │           ├── new NotificationQueue()               [Syncd.cpp]
  │           ├── new NotificationHandler()             [Syncd.cpp]
  │           ├── new NotificationProcessor()           [Syncd.cpp]
  │           ├── new VirtualOidTranslator()            [Syncd.cpp]
  │           ├── new RedisClient() / DisabledRedisClient()  [Syncd.cpp]
  │           ├── new RedisNotificationProducer() /     [Syncd.cpp]
  │           │     ZeroMQNotificationProducer()
  │           ├── new RedisSelectableChannel() /        [Syncd.cpp]
  │           │     ZeroMQSelectableChannel()
  │           └── setSaiApiLogLevel()                   [Syncd.cpp]
  └── syncd->run()                                      [syncd_main.cpp:71]
        └── onSyncdStart(warmStart)                     [Syncd.cpp:6752]
              ├── [warm] performWarmRestart()            [Syncd.cpp:6011]
              │     └── performWarmRestartSingleSwitch()
              │           └── vendorSai->create(switch, INIT_SWITCH=true)
              │               + new SaiSwitch(warmBoot=true)
              │                   └── helperDiscover()
              └── [cold] HardReiniter::hardReinit()     [Syncd.cpp:6031]
                    └── vendorSai->create(switch)
                        + new SaiSwitch(warmBoot=false)
                            └── helperDiscover()
        └── startNotificationsProcessingThread()        [Syncd.cpp:6758]
        └── startMdioThread()                           [Syncd.cpp:6765]
        └── startDampingTimerThread()                   [Syncd.cpp start]
        └── main event loop                             [Syncd.cpp:6797]
```

---

## 7. Key Source Files Reference

| File | Purpose |
|---|---|
| `syncd/syncd_main.cpp` | Application entry point: warm start detection, CLI parsing, VendorSai creation, Syncd creation, `syncd->run()` |
| `syncd/main.cpp` | Trivial wrapper: calls `syncd_main(argc, argv)` |
| `syncd/Syncd.h` | `Syncd` class declaration: all methods and ~50 data members |
| `syncd/Syncd.cpp` | `Syncd` implementation (~7000 lines): main event loop, ASIC event processing, warm restart, view comparison, notification dispatch, flex counter handling, link event damping, shutdown |
| `syncd/VendorSai.h` | `VendorSai` class: wraps the vendor SAI `.so`, declares all SAI API methods |
| `syncd/VendorSai.cpp` | `VendorSai` implementation: dlopen, dlsym, SAI API calls |
| `syncd/SaiSwitch.h` | `SaiSwitch` class: per-switch lifecycle, object discovery, port lane management |
| `syncd/SaiSwitch.cpp` | `SaiSwitch` implementation: `helperDiscover()`, lane map, MAC address retrieval |
| `syncd/AsicView.h/cpp` | `AsicView`: ASIC state snapshot, VID reference counting, ASIC operation generation |
| `syncd/ComparisonLogic.h/cpp` | `ComparisonLogic`: view comparison, object matching, transition computation |
| `syncd/NotificationHandler.h/cpp` | `NotificationHandler`: SAI callback reception and notification enqueue |
| `syncd/NotificationProcessor.h/cpp` | `NotificationProcessor`: background thread notification processing, RID→VID translation, forwarding to orchagent |
| `syncd/NotificationQueue.h/cpp` | `NotificationQueue`: thread-safe bounded queue with dedup |
| `syncd/VirtualOidTranslator.h/cpp` | `VirtualOidTranslator`: VID↔RID bidirectional translation |
| `syncd/RedisClient.h/cpp` | `RedisClient`: all Redis/ASIC_DB CRUD operations |
| `syncd/FlexCounterManager.h/cpp` | `FlexCounterManager`: flex counter instance lifecycle management |
| `syncd/WarmRestartTable.h/cpp` | `WarmRestartTable`: STATE_DB warm restart status tracking |
| `syncd/HardReiniter.h/cpp` | `HardReiniter`: cold boot switch initialization |
| `syncd/SwitchNotifications.h` | `SwitchNotifications`: C callback ↔ C++ function bridge for all SAI notifications |
| `syncd/ServiceMethodTable.h` | `ServiceMethodTable`: C callback bridge for profile_get_value |
| `syncd/VidManager.h` | `VidManager`: static VID bit-field decode utilities |
| `syncd/CommandLineOptions.h` | `CommandLineOptions`: all CLI parameter definitions |
| `syncd/TimerWatchdog.h/cpp` | `TimerWatchdog`: operation timeout watchdog |
| `syncd/WatchdogScope.h/cpp` | `WatchdogScope`: RAII watchdog activation scope |
| `syncd/LinkEventDamping.h` | `LinkEventDampingPortState`: per-port damping state struct |
| `syncd/PortStateChangeHandler.h` | `PortStateChangeHandler`: cross-thread port state notification bridge |
| `syncd/scripts/syncd_init_common.sh` | Shell init script: sets up syncd environment, loads SAI profile |
| `syncd/scripts/syncd_start.sh` | Shell start script: starts the syncd process with platform-specific args |

---

## 8. Architecture Notes

1. **Two-thread design**: Syncd uses two main threads:
   - **Main thread** (`Syncd::run()`): the `select()` event loop handling ASIC operations, flex counters, and restart queries. All SAI programming happens here, protected by `m_mutex`. — *`syncd/Syncd.h:623` — `m_mutex`*
   - **Notification thread** (`NotificationProcessor::ntf_process_function()`): handles incoming SAI callbacks, translates VIDs, applies damping, and forwards to orchagent. — *`syncd/NotificationProcessor.cpp` — `ntf_process_function()`*

2. **The mutex (`m_mutex`) is used in four critical places** to synchronize main-thread and notification-thread access to shared state (VID/RID maps, switch maps, Redis). — *`syncd/Syncd.h:599-623` — documented in header comment*

3. **Two communication modes**: Syncd can read ASIC operations from either Redis keyspace subscriptions (`RedisSelectableChannel`) or ZeroMQ IPC (`ZeroMQSelectableChannel`). The mode is controlled by the `-z` CLI flag. — *`syncd/Syncd.h:591` — `m_selectableChannel`*

4. **Init View / Temp View pattern**: When orchagent builds a new desired state (after its own restart), syncd enters "init view mode" where all operations go to a temporary Redis table rather than being applied. The `APPLY_VIEW` command triggers the comparison and delta application. This is the mechanism that allows orchagent to restart without taking down the data plane. — *`syncd/Syncd.cpp:5521-5588` — `processNotifySyncd()` handling INIT_VIEW and APPLY_VIEW*

5. **Watchdog safety**: Every ASIC operation is wrapped in `WatchdogScope`, which engages a `TimerWatchdog`. If the SAI call takes too long (potentially hanging), the watchdog fires and kills syncd to trigger a restart, rather than silently hanging forever. — *`syncd/Syncd.cpp:467` — `WatchdogScope ws(m_timerWatchdog, op + ":" + key, &kco)` in `processSingleEvent()`*

6. **Single-switch support with multi-switch architecture**: The code is written to support multiple switches (per-switch VID maps, per-switch `SaiSwitch` instances, per-switch views), but currently only a single switch is expected in practice. — *`syncd/Syncd.h:566-578` — comment on `m_switches` map*

7. **Deterministic VIDs**: Virtual IDs are not random — they are constructed from switch index, global context, object type, and object index, making them deterministic across restarts. This is crucial for warm reboot, as orchagent's stored VIDs must still be valid when syncd restarts. — *`syncd/VidManager.h` — `switchIdQuery()`, `objectTypeQuery()`, `getSwitchIndex()`, `getObjectIndex()`*

8. **SAI discovery**: After switch creation (both cold and warm boot), `SaiSwitch::helperDiscover()` uses `SaiDiscovery` to enumerate every object already present on the switch (ports, queues, default VLAN, default VR, CPU port, etc.). This populates the discovered RID set and the default OID attribute map, which is essential for the comparison logic's understanding of what already exists. — *`syncd/SaiSwitch.h:304` — `helperDiscover()` declaration; `syncd/SaiSwitch.cpp:53` — called in constructor*

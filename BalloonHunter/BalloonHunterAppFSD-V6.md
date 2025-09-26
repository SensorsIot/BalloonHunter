



# Functional Specifications Document (FSD) for the Balloon Hunter App

## Intro

This document outlines requirements for an iOS application designed to assist a person in hunting and recovering weather balloons. The app's design is centered around a single-screen, map-based interface that provides all critical information in real-time as they pursue a balloon.

The balloon carries a sonde that transmits its position signal. This signal is received by a device, called “MySondyGo”. This device transmits the received telemetry data via BLE to our app. So, sonde and balloon are used interchangeable.

## Dealing with Frequencies

- **Startup with live BLE telemetry** — If BLE packets are received, the frequency and probe type encoded in those BLE packets are treated as the source of truth.
- **Startup without BLE telemetry** — If BLE packets are not yet available, the app uses the most recent APRS/SondeHub frame instead. Frequency and probe type have to be transmitted to RadioSondyGo using the BLE command. If RadioSondyGo is ready for commands, immediately, otherwise when it connected (Ready for commands).
- **APRS telemetry mismatch** — While APRS fallback is active, the app compares the APRS frequency and probe type against the current RadioSondyGo settings. When a mismatch is detected, a confirmation alert appears; accepting applies the APRS values via the BLE command, while cancelling defers the change for a short period.

## Telemetry Availability Scenarios

- `bleTelemetryIsAvailable`: TRUE when a Type 1 BLE telemetry packet was parsed within the last 3 seconds.
- `aprsTelemetryIsAvailable`: TRUE when the latest SondeHub call returned and was parsed successfully.
- All other telemetry availability flags are deprecated; consumers must rely on these two booleans.

The app treats BLE (MySondyGo) telemetry as authoritative whenever it is available and healthy. APRS/SondeHub data is used as a fallback when BLE packets stop arriving. The following scenarios cover how the coordinator and services respond:

1. **Live BLE telemetry – balloon flying**  
   - `BalloonPositionService` publishes each packet immediately and determines `balloonPhase` based on landing detection and vertical speed.
   - `BalloonTrackService` updates the track and motion metrics (raw + smoothed speeds, adjusted descent).  
   - Prediction scheduling runs every 60 s and route updates follow the normal cadence.
2. **Live BLE telemetry – balloon landed**  
   - Landing detection latches `.landed`, averages the buffered coordinates for a stable landing point, and zeroes all motion metrics.  
   - `ServiceCoordinator` mirrors the landing point to the map, disables further prediction requests, and the data panel/route display switch to recovery mode. 
   - APRS polling remains stopped.
3. **APRS fallback with fresh timestamp (balloon flying)**  
   - APRS triggered immediately when BLE telemetry is not available. Afterwards, APRS data stays on the 15 s cadence until BLE recovers.
   - Track and motion metrics update exactly as they would for BLE packets, keeping the coordinator UI responsive while the balloon is still airborne. 
   - When BLE recovers, APRS is stopped again.
   - If RadioSondyGo is connected (BLE connected), the app regularly checks its frequency/sonde type and issues a command to change its frequency/sondetype to the one reported from APRS.
4. **APRS fallback with old timestamp (balloon landed)**  
   - APRS triggered immediately when BLE telemetry becomes stale. The polling cadence steps down to every 5 minutes once the latest packet is older than 120 s (indicating a landed balloon).  
   - Motion metrics are zero, the landing point is updated with the last APRS packet, and prediction requests remain disabled.  
   - If the last packet becomes older than 30 minutes, APRS polling stops altogether until fresh telemetry arrives or BLE recovers.
   - If RadioSondyGo is connected (BLE connected), the app regularly checks its frequency/sonde type and issues a command to change its frequency/sondetype to the one reported from APRS.
5. **No telemetry available**  
   - On startup (before any BLE/APRS data) or after both feeds go silent, the UI shows placeholders (e.g., `"--"` distance, `"--:--"` arrival) while the red telemetry-stale frame alerts the user.  
   - The flight state is set to unknown 
   - The last landing point is still valid and the tracking map (including routing) still works.

## Telemetry State Machine

The telemetry availability scenarios are implemented as a formal state machine within `BalloonPositionService`. This state machine centralizes all telemetry source decision-making and ensures predictable, testable behavior.

##### States

The state machine defines seven distinct states based on telemetry source availability and balloon phase:

*   `startup`: Initial application launch before any telemetry data is received.
*   `liveBLEFlying`: BLE telemetry is active, and the balloon is in flight.
*   `liveBLELanded`: BLE telemetry is active, and the balloon has landed.
*   `waitingForAPRS`: An intermediate state when BLE telemetry is lost, and the system is waiting for an APRS response.
*   `aprsFallbackFlying`: APRS telemetry is being used as a fallback, and the balloon is in flight.
*   `aprsFallbackLanded`: APRS telemetry is being used as a fallback, and the balloon has landed.
*   `noTelemetry`: No telemetry sources are available.

##### Input Signals

State transitions are driven by the following input signals:

*   `bleTelemetryIsAvailable`: `true` when a Type 1 BLE packet has been received within the last 3 seconds.
*   `aprsTelemetryIsAvailable`: `true` when the `APRSTelemetryService` has successfully fetched data.
*   `balloonPhase`: The flight phase of the balloon (`.flying`, `.landed`, `.unknown`), as determined by `BalloonPositionService` using vector analysis landing detection.

##### State Transition Rules and Functionality

Each state defines explicit exit criteria and associated functionality upon entering the state.

**State: `startup`**
*   **Functionality**:
    *   Disables APRS polling.
    *   Disables predictions and landing detection.
*   **Transitions**:
    1.  `bleTelemetryIsAvailable` AND `balloonPhase.isFlying` → `liveBLEFlying`
    2.  `bleTelemetryIsAvailable` AND `balloonPhase.isLanded` → `liveBLELanded`
    3.  `aprsTelemetryIsAvailable` AND `balloonPhase.isFlying` → `aprsFallbackFlying`
    4.  `aprsTelemetryIsAvailable` AND `balloonPhase.isLanded` → `aprsFallbackLanded`
    5.  `ELSE` → `noTelemetry`

**State: `liveBLEFlying`**
*   **Functionality**:
    *   Disables APRS polling.
    *   Enables predictions and landing detection.
*   **Transitions**:
    1.  `balloonPhase.isLanded` → `liveBLELanded`
    2.  `NOT bleTelemetryIsAvailable` → `waitingForAPRS`

**State: `liveBLELanded`**
*   **Functionality**:
    *   Disables APRS polling.
    *   Disables predictions. The live BLE position is used as the landing point.
*   **Transitions**:
    1.  `balloonPhase.isFlying` → `liveBLEFlying`
    2.  `NOT bleTelemetryIsAvailable` → `waitingForAPRS`

**State: `waitingForAPRS`**
*   **Functionality**:
    *   Enables APRS polling.
    *   Disables predictions and landing detection while waiting for a response.
*   **Transitions**:
    1.  `bleTelemetryIsAvailable` → `liveBLEFlying` or `liveBLELanded` (based on `balloonPhase`)
    2.  `aprsTelemetryIsAvailable` → `aprsFallbackFlying` or `aprsFallbackLanded` (based on `balloonPhase`)
    3.  `timeInState` > 30 seconds → `noTelemetry`

**State: `aprsFallbackFlying`**
*   **Functionality**:
    *   Enables APRS polling.
    *   Enables predictions and landing detection.
    *   Monitors for frequency mismatches between APRS and the BLE device settings.
*   **Transitions**:
    1.  `bleTelemetryIsAvailable` AND `timeInState` ≥ 30s → `liveBLEFlying`
    2.  `balloonPhase.isLanded` → `aprsFallbackLanded`
    3.  `NOT aprsTelemetryIsAvailable` → `noTelemetry`

**State: `aprsFallbackLanded`**
*   **Functionality**:
    *   Enables APRS polling.
    *   Disables predictions. The APRS position is used as the landing point.
*   **Transitions**:
    1.  `bleTelemetryIsAvailable` AND `timeInState` ≥ 30s → `liveBLEFlying` or `liveBLELanded` (based on `balloonPhase`)
    2.  `balloonPhase.isFlying` → `aprsFallbackFlying`
    3.  `NOT aprsTelemetryIsAvailable` → `noTelemetry`

**State: `noTelemetry`**
*   **Functionality**:
    *   Disables APRS polling.
    *   Disables predictions and landing detection.
*   **Transitions**:
    1.  `bleTelemetryIsAvailable` AND `balloonPhase.isFlying` → `liveBLEFlying`
    2.  `bleTelemetryIsAvailable` AND `balloonPhase.isLanded` → `liveBLELanded`
    3.  `aprsTelemetryIsAvailable` AND `balloonPhase.isFlying` → `aprsFallbackFlying`
    4.  `aprsTelemetryIsAvailable` AND `balloonPhase.isLanded` → `aprsFallbackLanded`

##### Key Design Principles

*   **Input-Driven Transitions**: State changes occur only when input signals change.
*   **30-Second Debouncing**: Transitions from APRS back to BLE require the system to be in an APRS state for at least 30 seconds to prevent rapid oscillation between telemetry sources.
*   **External Balloon Phase**: The state machine consumes balloon phase decisions made by the `BalloonTrackService`.
*   **APRS Service Manages Polling**: The `APRSTelemetryService` internally handles its polling frequency; the state machine only enables or disables it.

### Architecture

  Our architecture continues to enforce a clean separation of responsibilities while embracing the new modular service layout, a coordinator, and a map presenter.

  - Separation of Concerns
  - Business logic lives in services and the coordinator; SwiftUI views remain declarative, consuming ready-to-render state from environment objects without reaching into data sources directly.
  - Coordinator as Orchestrator
    ServiceCoordinator listens to raw service publishers, applies cross-cutting rules that cannot be handled by one service alone, and publishes the merged app state.
  - Modular Services
    Each service file bundles one domain: location tracking, balloon telemetry smoothing, persistence, routing, or prediction. Grouping the related caches
    (PredictionCache, RoutingCache) alongside their services keeps the surface area small and reduces coupling.
  - Presenter Layer for Complex Views
    The MapPresenter map-specific state transformations (overlay generation, formatted strings, user intents) so TrackingMapView does not need
    to manipulate coordinator or services state directly. This keeps the coordinator focused on orchestration and the view focused on layout.
  - Combine-Driven Data Flow
    Services publish changes via @Published properties or actors; the coordinator and presenter subscribe, transform, and re-publish derived values. This
    provides a single reactive pipeline from BLE/location inputs to UI outputs.
  - Environment-Driven UI: Views observe the coordinator, presenter, and settings objects through @EnvironmentObject. User actions (toggle heading, trigger prediction, open Maps) bubble up through intent methods defined on the presenter/coordinator instead of mutating state locally.
  - Persistence & Caching: PersistenceService handles all disk IO (tracks, landing history, user/device prefs), and caching actors prevent redundant prediction/route work. Both are injected once through AppServices, reinforcing a single source of truth.

### File Structure

Do not open a new file without asking the user

#### BalloonHunterApp.swift:

The main entry point of the application. It initializes the dependency container (`AppServices`), creates the `ServiceCoordinator`, injects both (plus shared services such as `LandingPointTrackingService`) into the SwiftUI environment, and manages scene lifecycle tasks like persistence saves and notification routing.

####  AppServices.swift:

A dependency injection container that wires up the core infrastructure: `PersistenceService`, `BLECommunicationService`, `CurrentLocationService`, `BalloonPositionService`, `BalloonTrackService`, `LandingPointTrackingService`, the caching actors, and other singletons used across the app.

#### ServiceCoordinator.swift:

The central architectural component that coordinates all services, manages application state, arbitrates telemetry between BLE and APRS providers, and contains the main business logic that was originally intended for the policy layer in the FSD.

#### CoordinatorServices.swift:

An extension to ServiceCoordinator that specifically contains the detailed 8-step startup sequence logic, keeping the main ServiceCoordinator file cleaner.

#### CoreModels.swift:

Centralizes the shared data types (`TelemetryData`, `BalloonTrackPoint`, `PredictionData`, etc.) plus logging helpers so every service can import the same model definitions without circular references.

#### LocationServices.swift:

Houses the `CurrentLocationService` and related helpers that manage background/precision GPS updates, distance overlays, and proximity checks against the balloon.

#### BalloonTrackingServices.swift:

Contains `BalloonPositionService`, `BalloonTrackService`, and `LandingPointTrackingService`. These coordinate telemetry parsing, track smoothing, landing detection, and persistence of historic track/landing data.

#### RoutingServices.swift:

Bundles `RouteCalculationService` with the `RoutingCache` actor. Route planning and caching logic now live together so the coordinator can request routes without touching unrelated services.

#### PersistenceService.swift:

Dedicated file for the `PersistenceService`, responsible for saving/loading tracks, landing histories, user/device settings, and coordinating document-directory persistence.

#### BLEService.swift:

Contains the `BLECommunicationService`, which is responsible for all Bluetooth Low Energy communication, including device scanning, connection, and parsing incoming data packets from the MySondyGo device.

#### MapPresenter.swift:

An observable presenter that aggregates map-related state from the coordinator and services. Views bind to it for overlays, distance text, and intent methods (toggle heading, open Maps, etc.).

#### TrackingMapView.swift:

The main map view. It renders live overlays (balloon track, SondeHub landing history, prediction path, routes), reflects the user’s controls, and hosts the SondeHub serial confirmation popup when required.

#### DataPanelView.swift:

A SwiftUI view that displays the two tables of telemetry and calculated data at the bottom of the main screen.

#### SettingsView.swift:

Contains the UI for all settings, including the main "Sonde Settings" and the tabbed "Device Settings" sheet (with inlined numeric text field control).

#### PredictionService.swift:

Implements the SondeHub prediction workflow (manual and scheduled), including API orchestration, caching integration, and publishing `PredictionData` back to the coordinator and UI. The prediction cache actor now lives inside this file.

#### DebugCSVLogger.swift:

Utility that records incoming telemetry frames (excluding development sondes) to a CSV file in the app’s documents directory for offline analysis.

#### Settings.swift:

Defines `UserSettings`, `DeviceSettings`, and app-level configuration structures, plus helpers for persisting and observing user-selectable preferences (transport mode, prediction defaults, etc.).




### Architecture

Our architecture keeps the coordinator-centric design while reinforcing clear separation of responsibilities.

- **Separation of Concerns**  
  Business logic lives in services and the coordinator; SwiftUI views remain declarative consumers of published state and never reach into data sources directly.

- **Coordinator as Orchestrator**  
  `ServiceCoordinator` listens to service publishers, applies cross-cutting rules (prediction cadence, routing policies), mirrors landing state emitted by `BalloonTrackService`, and republishes merged state for the UI.

- **Modular Services**  
  Location, balloon tracking, routing, prediction, and persistence each live in their own files. Caches are co-located with the services that use them, keeping APIs small and dependencies minimal.

- **Presenter Layer for Complex Screens**  
  `MapPresenter` consolidates map-specific state transformations (overlays, distance strings, intent handling) so the map view remains a pure SwiftUI layout and the coordinator stays focused on coordination.

- **Combine-Driven Data Flow**  
  Services publish via `@Published` or actors; the coordinator and presenter subscribe, transform, and re-publish. This provides a single reactive pipeline from BLE/location inputs to UI outputs.

- **Environment-Driven UI**  
  Views observe the coordinator/presenter/settings through `@EnvironmentObject`. User actions bubble up through intent methods instead of mutating state locally.

- **Persistence & Caching**  
  `PersistenceService` centralizes disk IO, `PredictionCache` and `RoutingCache` avoid redundant work, and both are injected once through `AppServices`, ensuring a single source of truth.

- **Extensibility Without File Sprawl**  
  Even though services live in multiple files now, related pieces are grouped, shared models remain in `CoreModels.swift`, and new files are added only with deliberate intent, keeping navigation simple.

### Data Flow

  The data flow is straightforward and centralized:

1. Data In: Services like BLECommunicationService and CurrentLocationService receive data from external sources (the  BLE device, GPS).  

2. Coordination: These services publish their data using Combine. The ServiceCoordinator subscribes to these publishers.  

3. Logic & State Update: When the ServiceCoordinator receives new data, it runs its business logic (e.g., checks if  a new prediction is needed) and updates its own @Published state properties.  

4. UI Update: Because the SwiftUI views are observing the ServiceCoordinator, they automatically re-render to display the new state.


## Services

### BLE Communication Service

**Purpose**  
Discover and connect to MySondyGo devices over Bluetooth Low Energy, subscribe to their UART characteristic, parse the MySondyGo Type 0–3 packets, and surface telemetry, device status, and diagnostic information to the rest of the app.

**Constants & UUIDs**

- `UART_SERVICE_UUID` = `53797269-614D-6972-6B6F-44616C6D6F6E`
- `UART_RX_CHARACTERISTIC_UUID` (notify) = `53797267-614D-6972-6B6F-44616C6D6F8E`
- `UART_TX_CHARACTERISTIC_UUID` (write/writeWithoutResponse) = `53797268-614D-6972-6B6F-44616C6D6F7E`

**Initialization**

1. Constructed with a `PersistenceService` reference.
2. Creates a `CBCentralManager` (queue `nil`, delegate `self`).
3. Starts two timers: every 3 seconds `updateBLEStaleState()` checks `lastTelemetryUpdateTime`; every 10 seconds `printBLEDiagnostics()` logs health information.

**State Publishers**

- `latestTelemetry`, `deviceSettings`, `connectionStatus`, `isReadyForCommands`.
- `telemetryData` (`PassthroughSubject<TelemetryData, Never>`).
- `centralManagerPoweredOn` (`PassthroughSubject<Void, Never>`).
- Internal state: `lastMessageType`, `lastTelemetryUpdateTime`, `isBLETelemetryStale` (not @Published).

**Note**: Telemetry availability state is managed by `BalloonPositionService` via `bleTelemetryIsAvailable` and `aprsTelemetryIsAvailable` for proper separation of concerns.

**Central Manager Lifecycle**

- `centralManagerDidUpdateState` logs state transitions. When `.poweredOn`, emits `centralManagerPoweredOn` and marks BLE healthy; when powered off/unauthorized, sets `connectionStatus = .disconnected` and publishes an unhealthy event.
- `startScanning()` runs only when Bluetooth is powered on. Scans for peripherals advertising the UART service whose name contains “MySondy”; duplicate discovery is disabled.

**Peripheral Discovery & Connection**

- `didDiscover` accepts devices whose name contains “MySondy”. Stops scanning, assigns `connectedPeripheral`, sets the delegate, and calls `connect`.
- `didConnect` logs success, sets `connectionStatus = .connected`, and starts `discoverServices([UART_SERVICE_UUID])`.
- `didFailToConnect` logs an error and restarts scanning.
- `didDisconnect` logs whether the disconnect was clean or error-driven, flips `connectionStatus`, resets `isReadyForCommands`, and—if unexpected—restarts the scan after 2 seconds.

**Service & Characteristic Discovery**

- `didDiscoverServices` iterates services; for the UART service it discovers RX/TX characteristics.
- `didDiscoverCharacteristicsFor` sets `writeCharacteristic` (prefers `.write` but falls back to `.writeWithoutResponse`) and enables notifications on RX. If TX is missing it logs an error; once configured it publishes a healthy event.

**Receiving Data**

- `didUpdateNotificationStateFor` logs success/failure when enabling RX notifications.
- `didUpdateValueFor` receives `Data` from RX, converts to UTF‑8, and passes the string to `parseMessage(_)`.

**Packet Parsing**

- `parseMessage` splits on `/`, stores `lastMessageType`, and flips `isReadyForCommands` on the first valid packet. It schedules `getParameters()` 0.5 s after the first packet per the FSD.
- On the first packet it also logs telemetry availability (Type 1 implies telemetry is ready).
- Switches on `messageType`:
  - **Type 0** (device status): logs a structured “📊 BLE PARSED (Type 0)” line; on parse failure logs raw fields.
  - **Type 1** (telemetry): logs both a debug (label=value) and info summary, performs plausibility checks (latitude/longitude bounds, altitude range, horizontal speed ≤150 m/s, vertical speed ≤100 m/s, battery percentage 0–100, battery mV 2500–5000). Failing fields emit a ⚠️ log. Calls `parseType1Message` to build `TelemetryData` and discards samples with latitude/longitude 0. Valid telemetry updates `latestTelemetry`, `lastTelemetryUpdateTime`, and pushes through `telemetryData`.
  - **Type 2** (name/status) and **Type 3** (device config) log structured output and update `deviceSettings`.
- Out-of-range or malformed packets (also la:0/lon:0) log `🔴` messages and are skipped. RSSI is reported as a positive number from BLE and is displayed as negative nummer.

**Command Interface**

- Dedicated helpers cover the major command groups:
  - `getParameters()` issues `o{?}o` to pull the latest Type‑3 configuration from the device.
  - `setFrequency(_:probeType:)` formats `o{f=/tipo=}`, writes it, and mirrors the change into `deviceSettings`, `latestTelemetry`, and persistence so the UI reflects the new value immediately (frequencies are rounded to 0.01 MHz to match the RadioSondyGo step size).
  - `setMute(_:)` toggles the buzzer via `o{mute=0|1}o` and keeps the cached mute flag aligned with the device.
  - `setSettings(_:)` wraps key/value configuration updates (e.g., APRS name mode, bandwidths, GPIO configuration) and delegates to the generic settings command builder.
- Each helper constructs the UART command, writes to TX (preferring `.withResponse`), and guards against attempts when TX is unavailable—emitting a log instead of mutating state.

**Telemetry Staleness Detection**

- `updateBLEStaleState()` runs every 3 seconds; if the latest Type‑1 packet is older than 3 seconds, logs "Telemetry LOST"; when telemetry resumes it logs "Telemetry GAINED".
- Note: This function only logs changes; actual telemetry availability state management is handled by `BalloonPositionService` which monitors BLE connection status and telemetry flow.

**Stability Notes**

- All CoreBluetooth errors are caught and logged without crashing the service.
- CSV logging for each telemetry sample is handled downstream (`BalloonTrackService` → `DebugCSVLogger`).
- Automatic settings requests happen once after the first valid packet; subsequent requests are user-driven via the settings UI.



### APRS Telemetry Service

**Purpose**  
Provide SondeHub-driven telemetry frames whenever BLE telemetry data is unavailable. It is also used to program the correct frequendy/sonde type in RadioSondyGo.

#### Input Triggers

- Startup
- Scheduler tick (5 s when BLE telemetry is stale, 60 s health-check cadence otherwise).
- Notification from the coordinator that BLE telemetry has resumed (stop polling).
- Station-ID changes in settings (e.g., switching to a different launch site).

#### Data it Consumes

1. SondeHub site data: `GET /sondes/site/<station_id>` (Payerne = `06610`). This single call provides both the latest sonde serial numbers and their most recent telemetry data.
2. Station configuration stored in user settings (defaults to Payerne).

#### Data it Publishes

- `TelemetryFrame` objects tagged with `.aprs` for the same consumers that read BLE frames.
- Service state (current station ID, last SondeHub serial, poll cadence) for diagnostics.
- The service should be compatible with th BLE telemetry service

#### Example Data

```swift
TelemetryFrame(
    source: .aprs,
    sondeName: "V4210201",
    latitude: 47.00093,
    longitude: 7.15809,
    altitude: 8928.4,
    horizontalSpeed: 22.8,
    verticalSpeed: 7.2,
    timestamp: Date()
)
```

#### Behavior

- On startup (and whenever the station ID changes), and during active polling, call `/sondes/site/<station_id>`.
- From the response, identify the most recent sonde by its timestamp.
- Convert the telemetry data for that sonde directly into a `TelemetryFrame` and publish it so `BalloonTrackService` treats it exactly like BLE telemetry. This single call replaces the previous two-step process.
- Poll every 15 seconds while BLE telemetry is stale; slow down to a 60-second health check when BLE is healthy.  
- Suspend polling as soon as fresh BLE telemetry resumes.  
- Flight-state decisions and landing detection are handled by `BalloonPositionService`, while smoothing remains with `BalloonTrackService`—the APRS service only supplies raw telemetry frames.

### Current Location Service

**Purpose**  
Keep track of the iPhone’s location and heading, swap automatically between low-power background tracking and precise “heading mode,” detect meaningful movement, and publish the raw distance to the balloon so the UI can render the overlay.

#### When it runs

- Whenever the user changes location permissions.
- Whenever iOS delivers new location updates (background mode roughly every 30 s, precision mode every few meters/seconds).
- Whenever the compass heading changes.
- Whenever the presenter/coordinator provides an updated balloon position.

#### What it listens to

- Location and heading events emitted by iOS.
- The current balloon coordinate supplied upstream.

#### What it shares

- `locationData`: latest user position with altitude/accuracy/heading/timestamp.
- `isLocationPermissionGranted`: current authorization state.
- `significantMovementLocation`: last position where the user moved ≥10 m.
- `distanceToBalloon`: straight-line distance in meters (nil if unknown).
- `isWithin200mOfBalloon`: proximity flag used by the UI to toggle navigation cues.

#### How it behaves

- Creates two location managers: one for background updates (10 m filter + 30 s timer) and one for heading mode (best accuracy, 2 m filter).
- Requests “When In Use,” then “Always,” and begins monitoring significant movement once permitted.
- `enableHeadingMode()` / `disableHeadingMode()` switch managers and log the change so diagnostics stay clear.
- Every location callback builds a new `LocationData`, throttles precision updates to at least 1 s apart, logs movement jumps (>20 m), updates the significant-movement marker, and recomputes both distance-to-balloon and the 200 m proximity flag.
- Heading callbacks keep the last known direction so future `LocationData` includes it.
- `updateDistanceToBalloon()` computes the raw meters from user to balloon; formatting (e.g., “123 m” vs “1.2 km”) is handled by the view.
- `updateBalloonDisplayPosition(_:)` is called whenever the presenter pushes a new balloon coordinate, so distance and proximity are refreshed immediately.
- Errors or denials are logged via `appLog`; routine health spam is muted. Timers are cleaned up automatically when the service is deallocated.

### Persistence Service

Purpose: Saves/loads data to UserDefaults. During development, and because user defaults are cleared when a new version is compiled, persistence uses the file system for storage. Ihis part has ot be encapsulated that it can easily be changed after develoment

####   Input Triggers:

1. App startup (load data)  

2. App backgrounding (save data)  
3. Settings changes  
4. Track updates  
5. Device setting updates

####   Data it Consumes:

  \- User settings (burst altitude, descent rates)  
  \- Device settings (MySondyGo configuration)  
  \- Balloon tracks (by sonde name)  
  \- Landing points (by sonde name)

####   Data it Publishes:

1. @Published var userSettings: UserSettings \- Prediction parameters  

2. @Published var deviceSettings: DeviceSettings? \- MySondyGo config  
3. Persistence completion events

####   Example Data:

  UserSettings(  
      burstAltitude: 30000.0, // meters  
      ascentRate: 5.0, // m/s  
      descentRate: 5.0 // m/s  
  )  
  DeviceSettings(  
      callsign: "HB9BLA",  
      frequency: 404.500, // MHz  
      power: 10, // dBm  
      bandwidth: 1,  
      spreadingFactor: 7  
  )

#### Types of data:

* Forecast Settings: It stores specific forecast parameters— burstAltitude (the altitude where the balloon is expected to burst), ascentRate (the rate at which the balloon rises), and descentRate (the rate at which the sonde falls back to Earth). These settings are kept so users don't have to re-enter them each time they open the app. They are stored in a simple key-value store.  
* Landing Predictions: Historical landing predictions are persisted for tracking purposes and map display, but not used as fallback landing points.  
* Balloon track: All balloon track data is stored together with a time stamp. Historic track data is persisted.

### Balloon Position Service

**Purpose**  
Store the most recent telemetry snapshot (coordinates, altitude, sonde name, vertical speed) and keep the current distance from the user to the balloon up to date.

#### Inputs

- Type 1 telemetry packets published by `BLECommunicationService`.
- User location updates from `CurrentLocationService`.

#### Publishes

- `currentTelemetry`, `currentPosition`, `currentAltitude`, `currentVerticalSpeed`, `currentBalloonName`.
- `distanceToUser` (meters), `timeSinceLastUpdate`, `hasReceivedTelemetry`.
- `bleTelemetryIsAvailable`, `aprsTelemetryIsAvailable` - telemetry availability state for the entire app.
- `burstKillerCountdown`, `burstKillerReferenceDate` - burst killer timing from BLE.

#### Behavior

- **Telemetry Management**: Subscribes to both BLE and APRS telemetry streams, implementing arbitration logic (APRS only used when BLE unavailable).
- **Availability State**: Manages `bleTelemetryIsAvailable` and `aprsTelemetryIsAvailable` based on connection status and telemetry flow.
- **Position Tracking**: Caches the latest packet, updating timestamp and derived values. Recomputes distance when user location changes.
- **Staleness Detection**: A 1 Hz timer updates `timeSinceLastUpdate` and `isTelemetryStale` for downstream consumers.
- **APRS Integration**: Automatically notifies APRSTelemetryService of BLE health changes to control APRS polling.
- **Burst Killer**: Manages burst killer countdown from BLE, with persistence fallback for APRS sessions.
- Exposes helper methods (`getBalloonLocation()`, `isWithinRange(_:)`, etc.) for downstream policies.

### Balloon Track Service

**Purpose**  
Build the flight history, smooth velocities, detect landings, derive descent metrics, and persist track data for the active sonde.

#### Inputs

- `BalloonPositionService.$currentTelemetry` for every telemetry sample.
- `PersistenceService` to load/save tracks keyed by sonde name.

#### Publishes

- `currentBalloonTrack`, `currentBalloonName`, `currentEffectiveDescentRate`.
- `trackUpdated` (Combine subject), `landingPosition`, `balloonPhase`.
- `motionMetrics` struct (raw horizontal/vertical speeds, smoothed horizontal/vertical speeds, adjusted descent rate).
- `isTelemetryStale` flag for UI highlighting.

#### Behavior

1. **Sonde management** — When a new sonde appears, the service attempts to load its persisted history. Switching sondes clears the previous track and counters before loading the new data (or starting fresh).
2. **Track updates** — Each telemetry sample is converted into a `BalloonTrackPoint`; if a previous point exists the service recomputes horizontal speed via great-circle distance and vertical speed via altitude delta for consistency. The point is appended, descent regression is updated, and observers receive `trackUpdated`.
3. **Speed smoothing** — Maintains Hampel buffers (window 10, k=3) to reject outliers, applies deadbands near zero, and feeds an exponential moving average (τ = 10 s) to publish smoothed horizontal/vertical speeds alongside the raw telemetry values within `motionMetrics`.
4. **Adjusted descent rate** — Looks back 60 s over the track, computes interval descent rates, takes the median, and keeps a 20-entry rolling average; the latest value is exposed through `motionMetrics` (and zeroed when the balloon is landed).
5. **Landing detection** — **MOVED TO BALLOONPOSITIONSERVICE**: Vector analysis algorithm calculates net movement across dynamic 5-20 packet windows. Landing detected when net speed < 3 km/h AND altitude < 3000m. Confidence ≥ 75 % flips `balloonPhase` to `.landed` and averages the buffered coordinates for the landing point; confidence < 40 % for three consecutive updates (or too few samples) returns the phase to the appropriate flight state. APRS packets older than 120 s also force `.landed` so stale data doesn’t masquerade as an in-flight balloon.
6. **Staleness** — A 1 Hz timer flips `isTelemetryStale = true` whenever the latest telemetry is more than 3 s old.
7. **Persistence** — Saves the track every 10 telemetry points via `saveBalloonTrack`. Helpers expose the full track for app-shutdown persistence (`saveOnAppClose`). CSV logging for each telemetry sample is routed to `DebugCSVLogger`.
8. **Motion metrics publishing** — After each telemetry sample the service emits a `BalloonMotionMetrics` snapshot so downstream consumers can pick either the raw or smoothed values without re-computing them; smoothed values and descent rate are reset to zero once the balloon is landed.

### Landing Point Tracking Service

**Purpose**  
Maintain the list of landing predictions for the active sonde, deduplicate noisy updates, and persist/restore the history for reuse in the tracking map.

#### Inputs

- Landing predictions (coordinate, prediction time, optional ETA) produced by `PredictionService` / coordinator.
- `BalloonTrackService.$currentBalloonName` to detect sonde changes.
- `PersistenceService` for load/save operations keyed by sonde name.

#### Publishes

- `landingHistory` (ordered `LandingPredictionPoint` array).
- `lastLandingPrediction` (latest entry, or `nil`).

#### Behavior

- When the active sonde changes, the previous history is cleared, the persisted history for the new sonde (if any) is loaded, and `lastLandingPrediction` is updated.
- New landing predictions are deduplicated against the last point (25 m threshold) to avoid jitter; if it’s a new location, it is appended and immediately saved.
- `persistCurrentHistory()` is invoked during app shutdown so the latest state is stored.
- `resetHistory()` wipes the array and published “last” value so each balloon starts with a clean slate.
- The tracking map observes `landingHistory` to draw the purple polyline and dots for historical landing estimates.

### Prediction Service

**Purpose**  
Call the SondeHub prediction API on demand (manual or scheduled), cache results to avoid redundant requests, and surface landing-distance/time strings for the UI.

#### Inputs

- Latest telemetry frame (`TelemetryData`).
- User settings (burst altitude, ascent/descent rates).
- Smoothed descent rate supplied by `BalloonTrackService` when the balloon is below 10 000 m.
- Cache key components (balloon ID, location, altitude, time bucket).
#### Triggers

- Manual: user taps the balloon annotation.
- Startup: first telemetry after launch.
- Timer: every 60 s while a valid prediction has not been generated recently.

#### Publishes

- `isRunning`, `hasValidPrediction`, `lastPredictionTime`, `predictionStatus`, `latestPrediction`.
- Formatted strings: `predictedLandingTimeString` (HH:mm) and `remainingFlightTimeString` (HH:mm).

#### Behavior

1. Builds a cache key using the balloon ID, quantized coordinate (two decimal places), altitude, and 5‑minute time bucket.
2. On each trigger:
   - Checks the `PredictionCache`; if a fresh entry exists and the call is not forced, emits the cached result.
   - Otherwise constructs a SondeHub request using the current telemetry, burst altitude (user default above 10 km; current altitude + 10 m below 10 km), ascent/descent rates, and a “now + 1 minute” timestamp.
   - Spins a non-blocking `URLSession` request with a 30 s timeout; interprets the JSON response into `PredictionData` (path, burst point, landing point/time). See [Prediction Service API (Sondehub)](#prediction-service-api-sondehub) for request/response details.
   - Updates `latestPrediction`, `predictedLandingTimeString`, `remainingFlightTimeString`, and caches the response for future use.
3. Logs API success/failure, tracks `apiCallCount`, and guards against overlapping calls.
4. Provides manual `triggerManualPrediction()` (used by coordinator/tap gesture) and internal scheduling via a 60 s timer.
5. Handles failures gracefully by updating `predictionStatus` and leaving `hasValidPrediction` false.

#### Notes

- Predictions are skipped entirely if no telemetry is available or the balloon is already marked as landed.
- The service lives on the main actor so published state updates remain synchronous with the UI.
- CSV logging and other long-term diagnostics remain outside this service to keep it focused on API orchestration.

### Route Calculation Service

**Purpose**  
Request a route from the user’s current location to the landing point using Apple Maps when possible, fall back to heuristics when it is not, and avoid redundant work via an in-memory cache.

#### Inputs

- User location (`LocationData`).
- Landing point coordinate (`CLLocationCoordinate2D`).
- Selected transport mode (`TransportationMode.car` or `.bike`).

#### Publishes

- Returns `RouteData` asynchronously (`coordinates`, `distance`, `expectedTravelTime`, `transportType`).
- `RoutingCache` actor stores recently computed routes keyed by origin/destination/mode.

#### Behavior

1. Logs each request, then builds an `MKDirections.Request` from the user location to the landing point using the preferred transport type (car → `.automobile`, bike → `.cycling` on iOS 17+ with a `.walking` fallback when cycling data is unavailable).
2. Attempts to calculate the route via `MKDirections`.
3. If a route is returned, converts the polyline to `[CLLocationCoordinate2D]`, adjusts the ETA for bike mode (multiplies by 0.7), and wraps everything in `RouteData`.
4. If `MKDirections` throws `MKError.directionsNotAvailable`:  
   • Tries up to ten random 500 m offsets around the destination.  
   • Runs a radial search (300/600/1200 m every 45°) while the error remains “directions not available”.  
   • If nothing succeeds, falls back to a straight-line segment with a heuristic speed (car ≈ 60any other services km/h, bike ≈ 20 km/h) to produce a distance and arrival estimate.
5. Any other error is propagated to the caller so the UI can handle failure states (e.g., hide the overlay).
6. Successful routes are cached in `RoutingCache` for 5 minutes (LRU eviction, capacity 100). Callers check the cache before invoking Apple Maps again.

#### Notes

- Bike travel times are shortened by 30 % to offset conservative Apple Maps (walking) estimates when MapKit directions are used; the native Maps hand-off still opens true cycling mode via the transport toggle.
- Straight-line fallback ensures the UI always has a path to display, even without Apple Maps coverage.
- `RoutingCache` entries expire automatically; metrics are logged for cache hits/misses.

### Service Coordinator

**Purpose**  
Act as the single orchestration layer: subscribe to all service publishers, manage prediction cadence and routing refresh triggers, mirror landing/phase updates from `BalloonTrackService`, and expose consolidated state to the UI.

#### Inputs

- Telemetry updates from `BalloonPositionService` / `BalloonTrackService`.
- User location updates from `CurrentLocationService`.
- Prediction responses (`PredictionService`), route results (`RouteCalculationService`).
- User intents coming from the presenter/views (toggle heading, mute buzzer, open settings, launch Apple Maps, etc.).
- Lifecycle events (startup sequence, app backgrounding).

#### Publishes

- Map overlays and annotations (balloon track, predictions, routes, landing point, user location).
- Aggregated telemetry (`balloonTelemetry`, `userLocation`, `balloonPhase`).
- UI flags (`isHeadingMode`, `isRouteVisible`, `isTelemetryStale`, button enablement state).
- Cached prediction/route data (`predictionData`, `routeData`) and derived strings (frequency, countdowns, etc.).

#### Behavior

1.  **Startup orchestration** — Drives the multi-step startup sequence: show logo, initialise services, attempt BLE connection/settings, load persisted track/landing data, and finally reveal the tracking map.

**Landing Point Prioritization**

The `ServiceCoordinator` is responsible for determining the single, authoritative landing point that is displayed on the map and used for route calculations. It selects the most appropriate coordinate based on the balloon's current flight phase, following these rules:

    1.  **When `balloonPhase` is `.landed`**:
        *   The `landingPoint` is set to the value of `balloonTrackService.landingPosition`. This is considered the most accurate position, as it is calculated by averaging the most recent telemetry coordinates after the balloon has stopped moving.
    
    2.  **When `balloonPhase` is `.ascending`, `.descendingAbove10k`, or `.descendingBelow10k`**:
        *   The `landingPoint` is set to the value of `predictionData.landingPoint` from the latest successful prediction made by the `PredictionService`.
    
    3.  **When `balloonPhase` is `.unknown` (e.g., at startup before telemetry is received)**:
    *   The `landingPoint` is `nil`. It will be populated once the first prediction is made or the balloon's landing is confirmed.
2. **Telemetry pipeline** — `BalloonTrackService` ingests BLE/APRS telemetry, performs smoothing, while `BalloonPositionService` maintains the authoritative `balloonPhase` (including forcing `.landed` when APRS packets are older than 120 s), and publishes both raw and smoothed motion metrics plus landing positions. The coordinator mirrors these updates to drive map overlays, Apple Maps tracking, proximity flags, and prediction cadence.
3. **Landing point workflow** — Mirrors landing positions published by `BalloonTrackService`/`LandingPointTrackingService` and keeps map overlays in sync.
4. **Prediction scheduling** — Hands telemetry and settings to `PredictionService`, reacts to completions/failures, and exposes landing/flight time strings for the data panel.
5. **Route management** — Requests routes when the landing point or user location changes, updates the green overlay, surfaces ETA/distance in the data panel, and honours cache hits to avoid redundant Apple Maps calls.
6. **UI state management** — Owns camera mode (`isHeadingMode`), overlay toggles, buzzer mute, centre-on-all logic, and guards against updates while sheets (settings) are open.
7. **Apple Maps hand-off** — `openInAppleMaps()` launches navigation using the selected transport mode (car → driving, bike → cycling on iOS 14+ with walking fallback). Tracks the last destination so the coordinator can detect navigation updates.
8. **Optional APRS bridge** — When an APRS provider is enabled, the coordinator brokers SondeHub serial prompts, pauses APRS polling whenever fresh BLE telemetry is available, and synchronises RadioSondyGo frequency/probe type to match APRS telemetry when the streams differ.

## Startup

The coordinator runs `performCompleteStartupSequence()` in 6 sequential steps with optimized parallel execution where possible.

1.  **Step 1: Services**
    *   The progress label is set to "Step 1: Services".
    *   Service initialization is confirmed as complete.

2.  **Step 2: BLE & APRS (Parallel)**
    *   The progress label is updated to "Step 2: BLE & APRS".
    *   **BLE Connection**: The system waits up to 5 seconds for Bluetooth to power on and then attempts to connect to a MySondyGo device for up to 5 more seconds.
    *   **APRS Priming**: In parallel, the `ServiceCoordinator` calls the `primeStartupData()` method to fetch the latest telemetry data.
    *   The sequence continues when both operations complete or their respective timeouts are reached.

3.  **Step 3: Telemetry**
    *   The progress label is updated to "Step 3: Telemetry".
    *   The system waits up to 3 seconds for the first BLE packet to establish initial telemetry availability.

4.  **Step 4: Data**
    *   The progress label is updated to "Step 4: Data".
    *   User settings, historic track data, and landing histories are loaded from `PersistenceService`.

5.  **Step 5: Landing Point**
    *   The progress label is updated to "Step 5: Landing Point".
    *   The ServiceCoordinator determines the landing point that is displayed on the map and used for route calculations.
    It selects the most appropriate coordinate based on the balloon's current flight phase
6.  **Step 6: Map Display**
    *   The progress label is updated to "Step 6: Map Display".
    *   `setupInitialMapDisplay()` is called to reveal the map, overlays, and data panel.
    *   The startup logo is hidden, `isStartupComplete` is set to `true`, and the app transitions into its steady-state tracking mode.

## Tracking View

No calculations or business logic in views. Search for an appropriate service to place and publish them.

### Buttons Row

A row for Buttons is placed above the map. It is fixed and covers the entire width of the screen. It contains (in the sequence of appearance):

* Settings  

* Mode of transportation: The transport mode (car or bicycle) shall be used to calculate the route and the predicted arrival time. Every time the mode is changed, a new calculation has to be done. Use icons to save horizontal space.  
* Apple Maps navigation: Opens Apple Maps with the current landing point pre-filled. Car mode launches driving directions; bicycle mode launches cycling directions on iOS 14+ and falls back to walking on older systems.  

* Prediction on/off. It toggles if the balloon predicted path is displayed.  

* If a landing point is available, The  button “All” is shown.  It maximizes  the zoom level so that all overlays (user location, balloon track, balloon landing point) are visible (showAnnotations())  

* A button “Free/Heading”: It toggles between the two camera positions:  

  * “Heading” where the map centers the position of the iPhone and aligns the map direction to meet its heading. The user can only zoom freely.  
  * “Free” where the user can zoom and pan freely.  

* The zoom level stays the same if switched between the two modes.  

* Buzzer mute: Buzzer mute: On a button press, the buzzer shall be muted or unmuted by the mute BLE command (o{mute=setMute}o). The buzzer button shall indicate the current mute state.


### Map

The map starts below the button row, and occupying approximately 70% of the vertical space.

### Map Overlays

No calculations or business logic in views. Search for an appropriate service to place and publish them.

The overlays must remain accurately positioned and correctly cropped within the displayed map area during all interactions. They should be updated independently and drawn as soon as available and when changed.

* User Position: The iPhone's current position is continuously displayed and updated on the map, represented by a runner.  
* Balloon Live Position: If Telemetry is available, the balloon's real-time position is displayed using a balloon marker(Balloon.fill). Its colour shall be green while ascending and red while descending.  
* Balloon Track: The map overlay shall show the current balloon track as a thin red line. At startup, this array was populated with the historic track data. New telemetry points are appended to the array as they are received. The array is automatically cleared and reset by the persistence service if a different sonde name is received (new sonde). It is updated when a new point is added to the track. The track should appear on the map when it is available.  
* Balloon Predicted Path: The complete predicted flight path from the Sondehub API is displayed as a thick blue line. While the balloon is ascending, a distinct marker indicates the predicted burst location. The burst location shall only be visible when the balloon is ascending. The display of this path is controlled by the button “Prediction on/off”. The path should appear on the map when it is available.  
* Landing point: Shall be visible if a valid landing point is available  
* Planned Route from User to Landing Point: The recommended route from the user's current location to the predicted landing point is retrieved from Apple Maps and displayed on the map as a green overlay path. When bicycle mode is selected the in-app overlay still uses walking directions (MapKit limitation) but the Apple Maps button launches native cycling navigation. The route should appear on the map when it is available.  

A new route calculation and presentation is triggered:

* After a new track prediction is received, and the predicted landing point is moved  
  * Every minute, when the user moves.   
  * When the transport mode is changed

It is not shown if the distance between the balloon and the iPhone is less than 100m.

### SondeHub Serial Confirmation Popup

A centered alert presented on the tracking map when SondeHub reports a serial different from the BLE telemetry name. The message reads “Use SondeHub serial T4630250 changed to V4210123?” with Confirm and Cancel buttons. Confirmation is required before APRS polling continues; the mapping is not persisted across app launches so the prompt reappears on the next run if needed.

### Data Panel
The data panel is displayed at the bottom of the screen and provides real-time telemetry and calculated data. It is implemented using a `Grid`-based layout for a compact and organized presentation.

No calculations or business logic in views. Search for an appropriate service to place and publish them.

This panel covers the full width of the display and the full height left by the map. It displays the following fields (font sizes adjusted to ensure all data fits within the view without a title):

    Connection status icon (BLE, APRS, or disconnected). 
* Sonde Identification: Sonde type, number, and frequency.  
* Altitude: From telemetry in meters  
* Speeds (smoothened): Horizontal speed in km/h and vertical speed in m/s. Vertical speed: Green indicates ascending, and Red indicates descending.   
* Signal & Battery: Signal strength of the balloon and the battery status of RadioSondyGo in percentage.  
* Time Estimates: Predicted balloon landing time (from prediction service) and user arrival time (from routing service), both displayed in wall clock time for the current time zone. These times are updated with each new prediction or route calculation.  
* Remaining Balloon Flight Time: Time in hours:minutes from now to the predicted landing time.  
* Distance: The distance of the calculated route in kilometers (from route calculation). The distance is updated with each new route calculation.

* Landed: A “target” icon is shown when the balloon is landed

* Adjusted descend rate: Provided via `motionMetrics.adjustedDescentRateMS` from the balloon track service (auto-zeroed once the balloon is landed).
* Burst killer countdown: Shows the device’s burst-killer timeout as a local clock time. The countdown value is received from the MySondyGo device via BLE. The `BalloonPositionService` processes this value, storing the countdown duration and the telemetry timestamp as a reference date. This data is then cached by the `PersistenceService` in a `BurstKillerRecord` for the specific sonde. The countdown persists across APRS fallback by reading this cached record. APRS updates, which do not contain burst killer information, never overwrite the cached value.

The data panel should get a red frame around if no telemetry data is received for the last 3 seconds

Layout:

Two tables, one below the other. All fonts the same

Table 1: 4 columns

| Column 1  | Column2      | Column 3   | Column 4  | Column 5 |
| :-------- | :----------- | :--------- | :-------- | :------- |
| Connection status | Flight State | Sonde Type | sondeName | Altitude |

Table 2: 3 columns

| Column 1       | Column 2         | Column 3     |
| :------------- | :--------------- | :----------- |
| Frequency      | Signal Strength  | Battery %    |
| Vertical speed | Horizontal speed | Distance     |
| Flight time    | Landing time     | Arrival time |
| Adjusted Descent Rate    | Burst killer expiry time| |
Text in Columns: left aligned  
• "V: ... m/s" for vertical speed  
• "H: ... km/h" for horizontal speed  
• " dB" for RSSI  
• " Batt%" for battery percentage  
• "Arrival: ..." for arrival time  
• "Flight: ..." for flight time  
• "Landing: ..." for landing time  
• "Dist: ... km" for distance

**Dynamic Elements**

*   **Frame Color**: The panel is surrounded by a colored frame that indicates the telemetry status:
    *   **Green**: Live BLE telemetry is being received.
    *   **Orange**: The app is in APRS fallback mode.
    *   **Red**: Telemetry is stale (no data received for more than 3 seconds).
*   **Speed Colors**: The vertical speed is colored green for ascending and red for descending.
*   **Descent Rate Color**: The adjusted descent rate is colored green when it is being used for predictions.

### Data Flow

The app's data flow is designed to be reactive, with SwiftUI views updating automatically as new data becomes available from the various services.

1.  **Data Ingestion**: Services like `BLECommunicationService`, `APRSTelemetryService`, and `CurrentLocationService` receive raw data from external sources (BLE device, SondeHub API, GPS).

2.  **Service Processing**: These services, along with `BalloonTrackService` and `PredictionService`, process the raw data, calculate derived values (e.g., smoothed speeds, predictions), and publish the results via `@Published` properties.

3.  **View Consumption**: SwiftUI views, such as `DataPanelView` and `TrackingMapView`, use the `@EnvironmentObject` property wrapper to subscribe directly to the services they need. They access the `@Published` properties of these services to get the data they need for display.

4.  **UI Updates**: Because the views are observing the services' published properties, they automatically re-render whenever the data changes, ensuring the UI is always up-to-date.

While the `MapPresenter` handles complex presentation logic for the map, simpler views like `DataPanelView` consume data directly from the services for a more direct and efficient data flow. Some minor formatting logic may reside within the views for simplicity.


## Settings

### Settings Views

No calculations or business logic in views. Search for an appropriate service to place and publish them.

### Secondary Settings Views

The following views are accessed from the top navigation bar of the main settings screen. Each is presented as a separate sub-view.

#### Prediction Settings
* **Purpose**: Allows the user to configure the parameters used for flight predictions.
* **Controls**: Provides fields for "Burst Altitude", "Ascent Rate", "Descent Rate", and "Station ID".
* **Navigation**: Accessed via "Prediction Settings" button in the top toolbar. Three buttons ("Prediction Settings", "Device Settings", "Tune") are arranged evenly across the toolbar using Spacer elements.
* **Saving**: This view has a "Done" button. When tapped or when the view disappears (via onDisappear), the values are saved to the UserSettings object via PersistenceService, and the user is returned to the main settings screen.

#### Device Settings
* **Purpose**: Allows for detailed configuration of the MySondyGo device hardware and radio parameters.
* **Layout**: This view is organized into tabs for "Pins", "Battery", "Radio", and "Other".
* **Navigation**: Accessed via "Device Settings" button in the top toolbar, evenly spaced with other buttons.
* **Saving**: This view has a "Done" button. When tapped or when the view disappears (via onDisappear), the app compares the modified settings to their initial values, sends the necessary update commands to the device, saves the complete configuration to PersistenceService, and returns the user to the main settings screen.

#### Tune View
* **Purpose**: Provides an interface for the AFC (Automatic Frequency Control) tune function.
* **Controls**: Displays the live AFC value, a "Transfer" button to copy the value, and an input field with a "Save" button to apply the new frequency correction.
* **Navigation**: Accessed via "Tune" button in the top toolbar, evenly spaced with other buttons. Has a "Done" button that returns the user to the main settings screen (selectedTab = 0).
* **Saving**: The "Save" button within the view is used to apply the tune value immediately to the device and PersistenceService. No onDisappear save needed as values are saved explicitly.

### Sonde Settings Window

In long range state, triggered by a swipe-up in the data panel. In final approach state, triggered by a swipe-up in the map.. 

When opened, this window will display the currently configured sonde type and frequency, allowing the user to change them. If no valid data is available, a message is displayed instead (Sonde not connected). The frequency input has to be done without keyboard. All digits with the exception of the first have to be selectable independently.

**Navigation**: The main settings screen shows three buttons evenly distributed across the top toolbar: "Prediction Settings", "Device Settings", and "Tune". These provide access to the secondary settings views.

**Revert Button**: A "Revert" button is located below the frequency selector in the main content area as a full-width button. This button resets the values to the values present when the screen was entered.

**Saving**: Settings are automatically saved when the view disappears (onDisappear). A BLE message to set the sonde type and its frequency "o{f=frequency/tipo=probeType}o" according to the MySondyGo specs is sent, and settings are persisted via PersistenceService.

5.2.1 Available sonde types (enum)

1 RS41

2 M20

3 M10

4 PILOT

5 DFM

The human readable text (e.g. RS41) should be used in the display. However, the single number (e.g. 1\) has to be transferred in the command

### Device Settings

**Access**: Triggered by the "Device Settings" button in the main settings toolbar (evenly spaced with "Prediction Settings" and "Tune" buttons).

**Layout**: Opens a new sheet with four tabs: "Pins", "Battery", "Radio", and "Other" (Note: "Prediction" tab was removed as those settings moved to the separate Prediction Settings view).

**Implementation**: Uses DeviceSettings struct with `@Published` properties and PersistenceService integration.

**Process Flow**:

* **onAppear**: The view calls `loadDeviceSettings()` which:
  - Requests current settings from MySondyGo via BLE `getParameters()` command
  - Loads persisted settings from PersistenceService as fallback
  - Initializes `deviceSettingsCopy` with current values and `initialDeviceSettings` for comparison

* **User Modifications**: Changes are made directly to `deviceSettingsCopy` which provides immediate UI feedback via SwiftUI bindings.

* **onDisappear**: The view calls `saveDeviceSettings()` which:
  - Compares `deviceSettingsCopy` against `initialDeviceSettings` to identify changes
  - Calls `sendDeviceSettingsToBLE()` to send only modified settings via BLE commands
  - Saves complete configuration to PersistenceService via `save(deviceSettings:)` and `save(userSettings:)`
  - Handles connection state validation (`guard deviceConfigReceived else { return }`)

**Navigation**: "Done" button calls `dismiss()` which triggers the onDisappear save process and returns to main settings.


### Tab Structure & Contents in Settings

Each tab contains logically grouped settings:

#### Pins Tab

* oled\_sda (oledSDA)  

* oled\_scl (oledSCL)  

* oled\_rst (oledRST)  

* led\_pout (ledPin)  

* buz\_pin (buzPin)  

* lcd (lcdType)


#### Battery Tab

* battery (batPin)  

* vBatMin (batMin)  

* vBatMax (batMax)  

* vBatType (batType)  

  * 0: Linear  
    1: Sigmoidal  
    2: Asigmoidal


#### Radio Tab

* myCall (callSign)  

* rs41.rxbw (RS41Bandwidth)  

* m20.rxbw (M20Bandwidth)  

* m10.rxbw (M10Bandwidth)  

* pilot.rxbw (PILOTBandwidth)  

* dfm.rxbw (DFMBandwidth)

  4. #### Others Tab

* lcdOn (lcdStatus)  

* blu (bluetoothStatus)  

* baud (serialSpeed)  

* com (serialPort)  

* aprsName (aprsName / nameType)


#### Prediction Tab

(These values are stored permanently on the iPhone via PersistenceService and are never transmitted to the device)

* burstAltitude  

* ascentRate  

* descentRate


### Tune Function

The "TUNE" function in MySondyGo is a calibration process designed to compensate for frequency shifts of the receiver. These shifts can be several kilohertz (KHz) and impact reception quality. The tune view shows a smoothened (20)  AFC value (freqofs). If we press the “Transfer” button (which is located right to the live updated field), the actual average value is copied to the input field. A “Save” button placed right to the input field stores the actual value of the input field is stored using the setFreqCorrection command. The view stays open to check the effect.

## Debugging

Debugging should be according the services. It should contain

* From where the trigger came (one line)  
* What was executed (one line)   
* What was delivered (one line per structure)

# Appendix: 

## Messages from RadioSondyGo

### Type 0 (No probe received)

* Format: 0/probeType/frequency/RSSI/batPercentage/batVoltage/buzmute/softwareVersion/o  
* Example: 0/RS41/403.500/117.5/100/4274/0/3.10/o  
* Field Count: 7 fields  

#### Field types

* 0: packet type (String) \- "0"  
* 1: probeType (String)  
* 2: frequency (Double)  
* 3: RSSI (Double)  
* 4: batPercentage (Int)  
* 5: batVoltage (Int)  
* 6: buzmute (Bool, 0 \= off, 1 \= on)  
* 7: softwareVersion (String)

#### Values:  

* probeType: e.g., RS41  

* frequency: e.g., 403.500 (MHz)  

* RSSI: e.g., \-90 (dBm)  

* batPercentage: e.g., 100 (%)  

* batVoltage: e.g., 4000 (mV)  

* buzmute: e.g., 0 (0 \= off, 1 \= on)  

* softwareVersion: e.g., 3.10


### Type 1 (Probe telemetry)

* Format: 1/probeType/frequency/sondeName/latitude/longitude/altitude/HorizontalSpeed/verticalSpeed/RSSI/batPercentage/afcFrequency/burstKillerEnabled/burstKillerTime/batVoltage/buzmute/reserved1/reserved2/reserved3/softwareVersion/o  
* Example: 1/RS41/403.500/V4210150/47.38/8.54/500/10/2/117.5/100/0/0/0/4274/0/0/0/0/3.10/o (Example values for dynamic fields added for clarity)  
* Field Count: 20 fields  
* Variable names:  

  * probeType: e.g., RS41  
  * frequency: e.g., 403.500 (MHz)  
  * sondeName: e.g., V4210150  
  * latitude: (dynamic) e.g., 47.38 (degrees)  
  * longitude: (dynamic) e.g., 8.54 (degrees)  
  * altitude: (dynamic) e.g., 500 (meters)  
  * horizontalSpeed: (dynamic) e.g., 10 (m/s)  
  * verticalSpeed: (dynamic) e.g., 2 (m/s)  
  * RSSI: e.g., \-90 (dBm)  
  * batPercentage: e.g., 100 (%)  
  * afcFrequency: e.g., 0  
  * burstKillerEnabled: e.g., 0 (0 \= disabled, 1 \= enabled)  
  * burstKillerTime: e.g., 0 (seconds)  
  * batVoltage: e.g., 4000 (mV)  
  * buzmute: e.g., 0 (0 \= off, 1 \= on)  
  * reserved1: e.g., 0  
  * reserved2: e.g., 0  
  * reserved3: e.g., 0  
  * softwareVersion: e.g., 3.10

#### Field Types

* 0: packet type (Int) \- "1"  

* 1: probeType (String)  

* 2: frequency (Double)  

* 3: sondeName (String)  

* 4: latitude (Double)  

* 5: longitude (Double)  

* 6: altitude (Double)  

* 7: horizontalSpeed (Double)  

* 8: verticalSpeed (Double)  

* 9: RSSI (Double)  

* 10: batPercentage (Int)  

* 11: afcFrequency (Int)  

* 12: burstKillerEnabled (Bool, 0 \= disabled, 1 \= enabled)  

* 13: burstKillerTime (Int)  

* 14: batVoltage (Int)  

* 15: buzmute (Bool, 0 \= off, 1 \= on)  

* 16: reserved1 (Int)  

* 17: reserved2 (Int)  

* 18: reserved3 (Int)  

* 19: softwareVersion (String)

### Type 2 (Name only, coordinates are not available)

* Corrected Format: 2/probeType/frequency/sondeName/RSSI/batPercentage/afcFrequency/batVoltage/buzmute/softwareVersion/o  
* Example: 2/RS41/403.500/V4210150/117.5/100/0/4274/0/3.10/o  
* Field Count: 10 fields  

#### Variable names:  

* probeType: e.g., RS41  
* frequency: e.g., 403.500 (MHz)  
* sondeName: e.g., V4210150  
* RSSI: e.g., \-90 (dBm)  
* batPercentage: e.g., 100 (%)  
* afcFrequency: e.g., 0  
* batVoltage: e.g., 4000 (mV)  
* buzmute: e.g., 0 (0 \= off, 1 \= on)  
* softwareVersion: e.g., 3.10

#### Field Types

* 0: packet type (Int) \- "2"  

* 1: probeType (String)  

* 2: frequency (Double)  

* 3: sondeName (String)  

* 4: RSSI (Double)  

* 5: batPercentage (Int)  

* 6: afcFrequency (Int)  

* 7: batVoltage (Int)  

* 8: buzmute (Bool, 0 \= off, 1 \= on)  

* 9: softwareVersion (String)

### Type 3 (Configuration)

* Format: 3/probeType/frequency/oledSDA/oledSCL/oledRST/ledPin/RS41Bandwidth/M20Bandwidth/M10Bandwidth/PILOTBandwidth/DFMBandwidth/callSign/frequencyCorrection/batPin/batMin/batMax/batType/lcdType/nameType/buzPin/softwareVersion/o  
* Example: 3/RS41/404.600/21/22/16/25/1/7/7/7/6/MYCALL/0/35/2950/4180/1/0/0/0/3.10/o  
* Field Count: 21 fields  

#### Variable names:  

* probeType: e.g., RS41  

* frequency: e.g., 404.600 (MHz)  

* oledSDA: e.g., 21 (GPIO pin number)  

* oledSCL: e.g., 22 (GPIO pin number)  

* oledRST: e.g., 16 (GPIO pin number)  

* ledPin: e.g., 25 (GPIO pin number)  

* RS41Bandwidth: e.g., 1 (kHz)  

* M20Bandwidth: e.g., 7 (kHz)  

* M10Bandwidth: e.g., 7 (kHz)  

* PILOTBandwidth: e.g., 7 (kHz)  

* DFMBandwidth: e.g., 6 (kHz)  

* callSign: e.g., MYCALL  

* frequencyCorrection: e.g., 0 (Hz)  

* batPin: e.g., 35 (GPIO pin number)  

* batMin: e.g., 2950 (mV)  

* batMax: e.g., 4180 (mV)  

* batType: e.g., 1 (0:Linear, 1:Sigmoidal, 2:Asigmoidal)  

* lcdType: e.g., 0 (0:SSD1306\_128X64, 1:SH1106\_128X64)  

* nameType: e.g., 0  

* buzPin: e.g., 0 (GPIO pin number)  

* softwareVersion: e.g., 3.10


#### Field Types

* 0: packet type (Int) \- "3"  

* 1: probeType (String)  

* 2: frequency (Double)  

* 3: oledSDA (Int)  

* 4: oledSCL (Int)  

* 5: oledRST (Int)  

* 6: ledPin (Int)  

* 7: RS41Bandwidth (Int)  

* 8: M20Bandwidth (Int)  

* 9: M10Bandwidth (Int)  

* 10: PILOTBandwidth (Int)  

* 11: DFMBandwidth (Int)  

* 12: callSign (String)  

* 13: frequencyCorrection (Int)  

* 14: batPin (Int)  

* 15: batMin (Int)  

* 16: batMax (Int)  

* 17: batType (Int)  

* 18: lcdType (Int)  

* 19: nameType (Int)  

* 20: buzPin (Int)  

* 21: softwareVersion (String)

  

## RadioSondyGo Commands

All commands sent to the RadioSondyGo device must be enclosed within o{...}o delimiters. You can send multiple settings in one command string, separated by /, or send them individually.

### Settings Command

This command is used to configure various aspects of the RadioSondyGo device. All settings are stored for future use.

* Syntax: o{setting1=value1/setting2=value2/...}o  
* Examples:  
  * o{lcd=0/blu=0}o (Sets LCD driver to SSD1306 and turns Bluetooth off)  
  * o{f=404.600/tipo=1}o (Sets frequency to 404.600 MHz and probe type to RS41)  
  * o{myCall=MYCALL}o (Sets the call sign displayed to MYCALL)

Available Settings:

| Variable Name | Description                                                  | Default Value | Reboot Required |
| :------------ | :----------------------------------------------------------- | :------------ | :-------------- |
| lcd           | Sets the LCD driver: 0 for SSD1306\_128X64, 1 for SH1106\_128X64. | 0             | Yes             |
| lcdOn         | Turns the LCD on or off: 0 for Off, 1 for On.                | 1             | Yes             |
| oled\_sda     | Sets the SDA OLED Pin.                                       | 21            | Yes             |
| oled\_scl     | Sets the SCL OLED Pin.                                       | 22            | Yes             |
| oled\_rst     | Sets the RST OLED Pin.                                       | 16            | Yes             |
| led\_pout     | Sets the onboard LED Pin; 0 switches it off.                 | 25            | Yes             |
| buz\_pin      | Sets the buzzer Pin: 0 for no buzzer installed, otherwise specify the pin. | 0             | Yes             |
| myCall        | Sets the call shown on the display (max 8 characters). Set empty to hide. | MYCALL        | No              |
| blu           | Turns BLE (Bluetooth Low Energy) on or off: 0 for off, 1 for on. | 1             | Yes             |
| baud          | Sets the Serial Baud Rate: 0 (4800), 1 (9600), ..., 5 (115200). | 1             | Yes             |
| com           | Sets the Serial Port: 0 for tx pin 1 – rx pin 3 – USB, 1 for tx pin 12 – rx pin 2 (3.3V logic). | 0             | Yes             |
| rs41.rxbw     | Sets the RS41 Rx Bandwidth (see bandwidth table below).      | 4             | No              |
| m20.rxbw      | Sets the M20 Rx Bandwidth (see bandwidth table below).       | 7             | No              |
| m10.rxbw      | Sets the M10 Rx Bandwidth (see bandwidth table below).       | 7             | No              |
| pilot.rxbw    | Sets the PILOT Rx Bandwidth (see bandwidth table below).     | 7             | No              |
| dfm.rxbw      | Sets the DFM Rx Bandwidth (see bandwidth table below).       | 6             | No              |
| aprsName      | Sets the Serial or APRS name: 0 for Serial, 1 for APRS NAME. | 0             | No              |
| freqofs       | Sets the frequency correction.                               | 0             | No              |
| battery       | Sets the battery measurement Pin; 0 means no battery and hides the icon. | 35            | Yes             |
| vBatMin       | Sets the low battery value (in mV).                          | 2950          | No              |
| vBatMax       | Sets the battery full value (in mV).                         | 4180          | No              |
| vBatType      | Sets the battery discharge type: 0 for Linear, 1 for Sigmoidal, 2 for Asigmoidal. | 1             | No              |

### Frequency Command (sent separately)

This command sets the receiving frequency and the type of radiosonde probe to listen for.

* Syntax: o{f=frequency/tipo=probeType}o  
* Example: o{f=404.35/tipo=1}o (Sets frequency to 404.35 MHz and probe type to RS41)

Available Sonde Types (enum):

* 1: RS41  

* 2: M20  

* 3: M10  

* 4: PILOT  

* 5: DFM


### Mute Command

This command controls the device's buzzer.

* Syntax: o{mute=setMute}o  

* Variable:  

  * setMute: 0 for off, 1 for on.  

* Example: o{mute=0}o (Turns the buzzer off)


### Request Status Command

This command requests the current status and configuration of the RadioSondyGo device.

* Syntax: o{?}o


### Bandwidth Table (enum):

| Value | Bandwidth (kHz) |
| :---- | :-------------- |
| 0     | 2.6             |
| 1     | 3.1             |
| 2     | 3.9             |
| 3     | 5.2             |
| 4     | 6.3             |
| 5     | 7.8             |
| 6     | 10.4            |
| 7     | 12.5            |
| 8     | 15.6            |
| 9     | 20.8            |
| 10    | 25.0            |
| 11    | 31.3            |
| 12    | 41.7            |
| 13    | 50.0            |
| 14    | 62.5            |
| 15    | 83.3            |
| 16    | 100.0           |
| 17    | 125.0           |
| 18    | 166.7           |
| 19    | 200.0           |

## Sample Response of the Sondehub API

{"metadata":{"complete\_datetime":"2025-08-26T22:03:03.430276Z","start\_datetime":"2025-08-26T22:03:03.307369Z"},"prediction":\[{"stage":"ascent","trajectory":\[{"altitude":847.0,"datetime":"2025-08-26T19:17:53Z","latitude":46.9046,"longitude":7.3112},{"altitude":1147.0,"datetime":"2025-08-26T19:18:53Z","latitude":46.90578839571984,"longitude":7.31464191069996},{"altitude":1447.0,"datetime":"2025-08-26T19:19:53Z","latitude":46.90738178436716,"longitude":7.31981095948984}{"altitude":10788.959899190435,"datetime":"2025-08-26T21:31:43.15625Z","latitude":47.02026733468673,"longitude":8.263008170483552},{"altitude":10256.937248646722,"datetime":"2025-08-26T21:32:43.15625Z","latitude":47.021786505448404,"longitude":8.28923951226291},{"altitude":9741.995036947832,"datetime":"2025-08-26T21:33:43.15625Z","latitude":47.02396145555836,"longitude":8.307239397517654},{"altitude":9242.839596842607,"datetime":"2025-08-26T21:34:43.15625Z","latitude":47.02613722448047,"longitude":8.322760393386368},{"altitude":8758.326844518546,"datetime":"2025-08-26T21:35:43.15625Z","latitude":47.028111647104396,"longitude":8.337707401779058},{"altitude":8287.43950854397,"datetime":"2025-08-26T21:36:43.15625Z","latitude":47.02974696093491,"longitude":8.352131412681159},{"altitude":7829.268592765354,"datetime":"2025-08-26T21:37:43.15625Z","latitude":47.0311409286152,"longitude":8.366009058541602},{"altitude":7382.998154071957,"datetime":"2025-08-26T21:38:43.15625Z","latitude":47.03235907618386,"longitude":8.379331881008719},{"altitude":6947.892701971685,"datetime":"2025-08-26T21:39:43.15625Z","latitude":47.03359996475082,"longitude":8.392157697045668},{"altitude":6523.28669130534,"datetime":"2025-08-26T21:40:43.15625Z","latitude":47.03520896935295,"longitude":8.404651470370947},{"altitude":6108.575700515145,"datetime":"2025-08-26T21:41:43.15625Z","latitude":47.037258694172024,"longitude":8.41695136310459},{"altitude":5703.208978139213,"datetime":"2025-08-26T21:42:43.15625Z","latitude":47.03928925553843,"longitude":8.428578406952507},{"altitude":5306.683108216105,"datetime":"2025-08-26T21:43:43.15625Z","latitude":47.04106403634041,"longitude":8.438958391369948},{"altitude":4918.53659705615,"datetime":"2025-08-26T21:44:43.15625Z","latitude":47.042834816940626,"longitude":8.447836532591719},{"altitude":4538.345223619866,"datetime":"2025-08-26T21:45:43.15625Z","latitude":47.04492666691228,"longitude":8.45520179874688},{"altitude":4165.7180265847755,"datetime":"2025-08-26T21:46:43.15625Z","latitude":47.04787297223529,"longitude":8.461030067123232},{"altitude":3800.2938252874983,"datetime":"2025-08-26T21:47:43.15625Z","latitude":47.05161301867342,"longitude":8.46540917482723},{"altitude":3441.7381907151316,"datetime":"2025-08-26T21:48:43.15625Z","latitude":47.0550365019147,"longitude":8.468771619167265},{"altitude":3089.7407977836633,"datetime":"2025-08-26T21:49:43.15625Z","latitude":47.05752477756667,"longitude":8.471863409068922},{"altitude":2744.0131021741126,"datetime":"2025-08-26T21:50:43.15625Z","latitude":47.059177735790925,"longitude":8.475280034829108},{"altitude":2404.286294670708,"datetime":"2025-08-26T21:51:43.15625Z","latitude":47.06015824553558,"longitude":8.479056798727747},{"altitude":2070.309493769621,"datetime":"2025-08-26T21:52:43.15625Z","latitude":47.06067439933653,"longitude":8.483039337670583},{"altitude":1741.8481436915101,"datetime":"2025-08-26T21:53:43.15625Z","latitude":47.06084732342465,"longitude":8.48702038862245},{"altitude":1418.6825901367554,"datetime":"2025-08-26T21:54:43.15625Z","latitude":47.06087288110848,"longitude":8.490506330028142},{"altitude":1113.0316455477905,"datetime":"2025-08-26T21:55:40.8125Z","latitude":47.06098256896306,"longitude":8.492911202660144}\]}\],"request":{"ascent\_rate":5.0,"burst\_altitude":35000.0,"dataset":"2025-08-26T12:00:00Z","descent\_rate":5.0,"format":"json","launch\_altitude":847.0,"launch\_datetime":"2025-08-26T19:17:53Z","launch\_latitude":46.9046,"launch\_longitude":7.3112,"profile":"standard\_profile","version":1},"warnings":{}}

## Prediction Service API (Sondehub)

### API structure

* Endpoint: The single endpoint for all requests is   
* [https://api.v2.sondehub.org/tawhiri](https://api.v2.sondehub.org/tawhiri)  
* Profiles: The API supports different flight profiles. The one detailed here is the Standard Profile, referred to as `standard_profile`. This profile is the default and is used for predicting a full flight path including ascent, burst, and descent to the ground.

---

### Request Parameters

All requests to the API for the Standard Profile must include the following parameters in the query string.

#### General Parameters

| Parameter          | Required | Default Value                | Description                                                  |
| :----------------- | :------- | :--------------------------- | :----------------------------------------------------------- |
| `profile`          | optional | `standard_profile`           | Set to `standard_profile` to use this prediction model (this is the default). |
| `launch_latitude`  | required | \-                           | Launch latitude in decimal degrees (-90.0 to 90.0).          |
| `launch_longitude` | required | \-                           | Launch longitude in decimal degrees (0.0 to 360.0).          |
| `launch_datetime`  | required | \-                           | Time and date of launch, formatted as a RFC3339 timestamp.   |
| `launch_altitude`  | optional | Elevation at launch location | Elevation of the launch location in meters above sea level.  |

#### Standard Profile Specific Parameters

| Parameter        | Required | Default Value | Description                                                  |
| :--------------- | :------- | :------------ | :----------------------------------------------------------- |
| `ascent_rate`    | required | \-            | The balloon's ascent rate in meters per second. Must be greater than 0.0. |
| `burst_altitude` | required | \-            | The altitude at which the balloon is expected to burst, in meters above sea level. Must be greater than `launch_altitude`. |
| `descent_rate`   | required | \-            | The descent rate of the payload under a parachute, in meters per second. Must be greater than 0.0. |

###  Input Data Structure

The parser must be designed to accept a single JSON object with the following top-level keys and data types:

* `metadata`: An object containing processing timestamps.  
* `prediction`: An array of objects, each representing a flight stage (e.g., "ascent", "descent").  
* `request`: An object containing the initial flight parameters.  
* `warnings`: An optional object for any warnings.

The most critical data is within the `prediction` array. Each element of this array is an object with a `stage` key (string) and a `trajectory` key (array). Each element of the `trajectory` array is an object with the following structure:

* `altitude`: Number (meters)  

* `datetime`: String (ISO 8601 format)  

* `latitude`: Number (degrees)  

* `longitude`: Number (degrees)


### Parsing Logic and Extraction

The parser should perform the following actions:

#### General Information Extraction

* Launch Details: Extract the `launch_latitude`, `launch_longitude`, `launch_datetime`, `ascent_rate`, and `descent_rate` directly from the top-level `request` object.


#### Trajectory Processing

* The parser must iterate through the `prediction` array to identify the `ascent` and `descent` stages.  

* For each stage, the entire `trajectory` array should be captured and stored.


#### Burst Point Identification

* The burst point is defined as the last data point in the `ascent` trajectory.  

* The parser must extract and store the `altitude`, `datetime`, `latitude`, and `longitude` of this final ascent point.


#### Landing Point Identification

* The landing point is defined as the last data point in the `descent` trajectory.  
* The parser must extract and store the `altitude`, `datetime`, `latitude`, and `longitude` of this final descent point.


#### Error Response

Error responses contain two fragments: `error` and `metadata`. The `error` fragment includes a `type` and a `description`. The API can return the following error types:

* `RequestException` (HTTP 400 Bad Request): Returned if the request is invalid (e.g., missing a required parameter).  
* `InvalidDatasetException` (HTTP 404 Not Found): Returned if the requested dataset does not exist.  
* `PredictionException` (HTTP 500 Internal Server Error): Returned if the predictor's solver encounters an exception.  
* `InternalException` (HTTP 500 Internal Server Error): Returned when a general internal error occurs.  
* `NotYetImplementedException` (HTTP 501 Not Implemented): Returned if the requested functionality is not yet available.

For a balloon launched from a specific latitude and longitude, at a particular time, and with defined ascent/descent rates and burst altitude, the API call would look like this:

`https://api.v2.sondehub.org/tawhiri/?launch_latitude=50.0&launch_longitude=0.01&launch_datetime=2014-08-19T23:00:00Z&ascent_rate=5.0&burst_altitude=30000.0&descent_rate=10.0`

`https://api.v2.sondehub.org/tawhiri/?launch_latitude=46.9046&launch_longitude=7.3112&launch_datetime=2025-08-26T19:17:53Z&ascent_rate=5.0&burst_altitude=35000.0&descent_rate=5.0&launch_altitude=847.0`

## Arduino (only as a reference, not to be used)

BLEAdvertising \*pAdvertising \= BLEDevice::getAdvertising();
    pAdvertising-\>addServiceUUID(SERVICE\_UUID);
    pAdvertising-\>setScanResponse(true);
    pAdvertising-\>setMinPreferred(0x06);
    pAdvertising-\>setMinPreferred(0x12);
    pAdvertising-\>setMinInterval(160);
    pAdvertising-\>setMaxInterval(170);
    BLEDevice::startAdvertising();

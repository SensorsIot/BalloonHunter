



# Functional Specifications Document (FSD) for the Balloon Hunter App

## Intro

This document outlines requirements for an iOS application designed to assist a person in hunting and recovering weather balloons. The app's design is centered around a single-screen, map-based interface that provides all critical information in real-time as they pursue a balloon.

The balloon carries a sonde that transmits its position signal. This signal is received by a device, called "MySondyGo". This device transmits the received telemetry data via BLE to our app. So, sonde and balloon are used interchangeable.

## Three-Channel Data Architecture - Published Messages Block Diagram

```
┌───────────────────────────────────────────────────────────────────────────────────────┐
│                                 BalloonHunter Data Flow Architecture                  │
└───────────────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────┐    ┌─────────────────────┐    ┌─────────────────────┐
│   BLE SERVICE       │    │  APRS SERVICE       │    │  LOCATION SERVICE   │
│  (MySondyGo Device) │    │  (SondeHub API)     │    │  (Core Location)    │
└─────────────────────┘    └─────────────────────┘    └─────────────────────┘
          │                          │                          │
          │ Type 0,1,2,3 BLE         │ APRS Telemetry          │ GPS Data
          │ Packets                  │ JSON Response           │
          │                          │                          │
          ▼                          ▼                          ▼
┌─────────────────────┐    ┌─────────────────────┐    ┌─────────────────────┐
│ PUBLISHED STREAMS   │    │ PUBLISHED STREAMS   │    │ PUBLISHED STREAMS   │
│                     │    │                     │    │                     │
│ 📍 positionDataStream│   │ 📍positionDataStream│   │📍 locationData     │
│    PositionData     │    │    PositionData     │    │    LocationData     │
│    • sondeName      │    │    • sondeName      │    │    • latitude       │
│    • lat/lon/alt    │    │    • lat/lon/alt    │    │    • longitude      │
│    • speeds         │    │    • speeds         │    │    • altitude       │
│    • environmental  │    │    • environmental  │    │    • accuracy       │
│                     │    │                     │    │                     │
│ 📻radioChannelStream│    │📻 radioChannelStream│    │ 📏distanceToBalloon│
│    RadioChannelData │    │    RadioChannelData │    │   CLLocationDistance│
│    • frequency      │    │    • frequency      │    │                     │
│    • probeType      │    │    • probeType      │    │ 📍 isWithin200m     │
│    • battery        │    │    • sondeName      │    │    Bool             │
│    • signal         │    │    • timestamp      │    │                     │
│    • afc/buzzer     │    │    • source=.aprs   │    │                     │
│                     │    │                     │    │                     │
│ ⚙️  settingsStream  │    │                     │    │                     │
│    SettingsData     │    │ (No settings from   │    │                     │
│    • oled pins      │    │  APRS - device only)│    │                     │
│    • hardware cfg   │    │                     │    │                     │
│    • callSign       │    │                     │    │                     │
│    • bandwidths     │    │                     │    │                     │
└─────────────────────┘    └─────────────────────┘    └─────────────────────┘
          │                          │                          │
          └──────────────┬───────────┴──────────────┬───────────┘
                         │                          │
                         ▼                          ▼
┌───────────────────────────────────────────────────────────────────────────────────────┐
│                           BALLOON POSITION SERVICE                                   │
│                              (State Machine Coordinator)                            │
│  📊 PUBLISHED STATE:                                                                  │
│  • currentPositionData: PositionData                                                 │
│  • currentState: DataState (7-state machine)                                        │
│  • balloonPhase: BalloonPhase                                                        │
│  • balloonDisplayPosition: CLLocationCoordinate2D                                   │
│  • dataSource: TelemetrySource (.ble or .aprs)                                      │
│  • aprsDataAvailable: Bool                                                           │
│                                                                                      │
│  🔄 STATE MACHINE TRIGGERS SERVICE COORDINATION:                                    │
│  • State changes → ServiceCoordinator → Landing Point Coordination                 │
│  • Flying states → ServiceCoordinator triggers PredictionService                   │
│  • ServiceCoordinator coordinates landing point from prediction or position        │
│                                                                                      │
│  🔄 STATES: startup → liveBLEFlying → waitingForAPRS → aprsFlying          │
│                    → liveBLELanded              → aprsLanded               │
│                                   → noTelemetry                                     │
└───────────────────────────────────────────────────────────────────────────────────────┘
                                           │
                         ┌─────────────────┼─────────────────┐
                         │                 │                 │
                         ▼                 ▼                 ▼
┌─────────────────────┐ ┌─────────────────────┐ ┌─────────────────────┐
│ PREDICTION SERVICE  │ │ LANDING POINT       │ │ ROUTE CALCULATION   │
│                     │ │ TRACKING SERVICE    │ │ SERVICE             │
│ 📊 PUBLISHED:       │ │                     │ │                     │
│ • latestPrediction  │ │ 📊 PUBLISHED:       │ │ 📊 PUBLISHED:       │
│ • flightTimeString  │ │ • currentLandingPt  │ │ • currentRoute      │
│ • landingTimeString │ │ • landingSource     │ │ • transportMode     │
│                     │ │ • updateTime        │ │ • routeMetrics      │
│ 🎯 FEATURES:        │ │                     │ │                     │
│ • Tawhiri API       │ │ 🎯 FEATURES:        │ │ 🎯 FEATURES:        │
│ • Smart caching     │ │ • Source tracking   │ │ • Apple Maps API    │
│ • Time formatting   │ │ • Point merging     │ │ • Multi-transport   │
│ • Auto-chaining     │ │ • Auto-chaining     │ │ • Route optimization│
│                     │ │                     │ │                     │
│        │            │ │        │            │ │                     │
│        ▼            │ │        ▼            │ │                     │
│   Chains to ────────┼─┼───▶ Chains to ─────┼─┼────▶                │
│   LandingPt         │ │   RouteCalc+Nav     │ │                     │
└─────────────────────┘ └─────────────────────┘ └─────────────────────┘
                                    │                    │
                                    ▼                    │
                         ┌─────────────────────┐         │
                         │ NAVIGATION SERVICE  │         │
                         │                     │         │
                         │ 🎯 FEATURES:        │         │
                         │ • Apple Maps launch │         │
                         │ • Change alerts     │         │
                         │ • CarPlay support   │         │
                         └─────────────────────┘         │
                                           │             │
                         ┌─────────────────┼─────────────┼─────────────┐
                         │                 │             │             │
                         ▼                 ▼             ▼             ▼
┌─────────────────────┐ ┌─────────────────────┐ ┌─────────────────────┐
│ MAP PRESENTER       │ │ DATA PANEL VIEW     │ │ TRACKING MAP VIEW   │
│ (UI Coordinator)    │ │                     │ │                     │
│                     │ │ 🎯 DISPLAYS:        │ │ 🎯 DISPLAYS:        │
│ 📊 UI STATE:        │ │ • Telemetry data    │ │ • Map with overlays │
│ • predictionData    │ │ • Motion metrics    │ │ • Balloon position  │
│ • landingPoint      │ │ • Flight times      │ │ • Prediction path   │
│ • currentRoute      │ │ • Battery status    │ │ • User route        │
│ • userLocation      │ │ • Signal strength   │ │ • Landing point     │
│ • connectionStatus  │ │ • Descent rate      │ │ • User controls     │
│ • cameraRegion      │ │                     │ │                     │
│                     │ │                     │ │                     │
│ 🎯 DIRECT SERVICE   │ │                     │ │                     │
│    SUBSCRIPTIONS:   │ │                     │ │                     │
│ • No middleman      │ │                     │ │                     │
│ • Reactive updates  │ │                     │ │                     │
└─────────────────────┘ └─────────────────────┘ └─────────────────────┘
```

### Data Structures

📍 **PositionData** (Type 1 BLE + APRS):
• sondeName, lat/lon/alt, speeds, heading
• temperature, humidity, pressure
• timestamp, burstKillerTime, telemetrySource

📻 **RadioChannelData** (Type 0,1,2 BLE + APRS):
• probeType, frequency, battery, signal
• buzmute, afcFrequency, softwareVersion
• burstKiller, timestamp, telemetrySource
• Note: Type 1 packets now properly emit deviceSettings.probeType (fixed from showing empty)

⚙️ **SettingsData** (Type 3 BLE only):
• Hardware config: oled pins, led pins
• Radio settings: bandwidths, correction
• Device config: battery, display, callSign
• NO overlap with Type 1 fields!

🎯 **Legacy TelemetryData** (Backward compatibility):
• Combination of Position + Radio data
• Used by state machine during transition
• Will be phased out for pure channels

### Packet Type Routing

- **BLE Type 0** (Device Status) → RadioChannelData only (radio parameters + device status)
- **BLE Type 1** (Full Telemetry) → PositionData + RadioChannelData (position, movement data, and radio parameters for three-channel consistency)
- **BLE Type 2** (Partial Status) → No stream emission (updates internal state only)
- **BLE Type 3** (Configuration) → SettingsData only (device configuration)
- **APRS Telemetry** → PositionData + RadioChannelData (position + radio parameters)

### Communication Patterns

🔄 **Service Chain Architecture:**
State Machine → Service A → Service B → Service C (automatic chaining via dependency injection)

🔄 **Direct UI Communication:**
Services @Published → MapPresenter @Published → Views @EnvironmentObject (no middleman)

🔄 **Service Coordination:**
ServiceCoordinator handles app infrastructure only, UI state handled by MapPresenter

## The State Machine

### Overview

The BalloonHunter app implements a sophisticated state machine that manages telemetry source selection, application behavior, and service coordination. This state machine is the central decision engine that determines which telemetry source to trust (BLE vs APRS), when to enable predictions, and how to respond to different flight phases.

### Architecture & Responsibilities

The telemetry system follows a clear separation of concerns between startup, state machine, and state-specific logic:

**1. Startup Responsibilities:**
- Start services
- Collect necessary telemetry, connection status, and other decision inputs
- Establish BLE connections and initial APRS polling
- Gather balloon phase, telemetry availability, and user location
- Provide decision points for state machine evaluation
- Exit criteria: When all decision info for th state machine is ready
- **No business logic**: Startup only prepares inputs, does not trigger predictions or handle application logic

**2. State Machine Responsibilities:**

- Use collected inputs to determine appropriate state (flying, landed, etc.)
- Manage state transitions based on telemetry availability and balloon phase
- Control which services have to be used in each state
- **Decision engine**: Pure state evaluation based on input signals

**3. State-Specific Logic:**

- Each state handles its own responsibilities (predictions, landing points, routing)
- Landed states handle route calculation and position tracking
- In addition to "Landed Sttes", Flying states manage prediction triggers and landing point calculation
- **Business logic**: All application functionality lives in state handlers

This architecture ensures that:
- Startup remains focused on input collection and never handles business logic
- State machine provides clean, testable state transitions
- All application behavior is properly encapsulated in state-specific handlers
- No redundant or competing logic exists between startup and states

### Telemetry Source Management

**BLE Telemetry State Management:**
- BLE connection and telemetry status is managed via `BLEConnectionState` enum with three states:
  - `notConnected`: No BLE connection established
  - `readyForCommands`: BLE connected but not receiving Type 1 telemetry packets (UI shows red BLE icon)
  - `dataReady`: BLE connected and actively receiving Type 1 telemetry packets with position data (UI shows green flashing animation)
- The enum provides computed properties: `isConnected`, `canReceiveCommands`, `hasTelemetry`
- **Connection State Transitions:**
  - `notConnected` → `readyForCommands`: When first BLE packet (any type) is received
  - `readyForCommands` → `dataReady`: When Type 1 packet (telemetry with position) is received
  - `dataReady` → `readyForCommands`: When no Type 1 packets received for 10 seconds (only Type 0/2/3 status packets)
  - Background staleness check runs every 3 seconds with 30-second threshold for final downgrade
- **Type 1 Packet Requirement:** `hasTelemetry` returns `true` only when in `dataReady` state (actively receiving Type 1 packets with position data). Type 0 (device status), Type 2 (partial telemetry), and Type 3 (settings) packets do NOT qualify as telemetry.
- **UI Integration**: BLE icon color reflects connection state - red for readyForCommands (connected but no position data), green flash animation for active telemetry reception

**APRS Telemetry:**
- `aprsTelemetryIsAvailable`: TRUE when the latest SondeHub call returned and was parsed successfully.

### State Machine Implementation

The telemetry availability scenarios are implemented as a formal state machine within `BalloonPositionService`. This state machine centralizes all telemetry source decision-making and ensures predictable, testable behavior.

#### States

The state machine defines seven distinct states based on telemetry source availability and balloon phase:

- `startup`: Initial application launch before any telemetry data is received.
- `liveBLEFlying`: BLE telemetry is active, and the balloon is in flight.
- `liveBLELanded`: BLE telemetry is active, and the balloon has landed.
- `waitingForAPRS`: An intermediate state when BLE telemetry is lost, and the system is waiting for an APRS response.
- `aprsFlying`: APRS telemetry is being used as a fallback, and the balloon is in flight.
- `aprsLanded`: APRS telemetry is being used as a fallback, and the balloon has landed.
- `noTelemetry`: No telemetry sources are available.

#### Input Signals

State transitions are driven by the following input signals:

- `bleTelemetryState`: The BLE telemetry state enum (`.BLEnotconnected`, `.readyForCommands`, `.BLEtelemetryIsReady`) from the BLE service.
- `aprsTelemetryIsAvailable`: `true` when the `APRSTelemetryService` has successfully fetched data.
- `balloonPhase`: The flight phase of the balloon (`.flying`, `.landed`,  `descendingAbove10k`, `descendingBelow10k`, `.unknown`), as determined by `BalloonPositionService` using vector analysis landing detection.

#### State Behaviors and Transitions

Each state defines explicit entry functionality and exit criteria:

**State: `startup`**
- **Functionality**:
  - Collects telemetry, connection status, and decision inputs
  - Establishes BLE connections and initial APRS polling
  - Disables predictions and landing detection (business logic handled by target states)
  - **Input collection only**: No prediction triggers or application logic
- **Transitions**:
  1. `bleTelemetryState.hasTelemetry` AND `balloonPhase == .landed` → `liveBLELanded`
  2. `bleTelemetryState.hasTelemetry AND balloonPhase == (not).landed` → `liveBLEFlying`
  3. `aprsTelemetryIsAvailable` AND `balloonPhase == .landed` → `aprsLanded`
  4. `aprsTelemetryIsAvailable AND balloonPhase == (not).landed` → `aprsFlying` 
  5. `ELSE` → `noTelemetry`

**State: `liveBLEFlying`**
- **Functionality**:
  - Disables APRS polling
  - Calls chain: Prediction with BLE balloon position - Landing point tracking - routing
  - Map shows balloon track, landing point, landing point track, predicted path, route
- **Transitions**:
  1. `balloonPhase == .landed` → `liveBLELanded`
  2. `NOT bleTelemetryState.hasTelemetry` → `waitingForAPRS`

**State: `liveBLELanded`**
- **Functionality**:
  - Disables APRS polling
  - **Updates landing point** to current balloon position and triggers route calculation — NEW
  - Calls chain: Landing point tracking with BLE balloon position → routing
  - Map shows balloon track, landing point, landing point track, predicted path, route
  - Data panel shows motion metrics as zero
- **Transitions**:
  1. `balloonPhase != .landed` → `liveBLEFlying`
  2. `NOT bleTelemetryState.hasTelemetry` → `waitingForAPRS`

**State: `waitingForAPRS`**
- **Functionality**:
  - Enables APRS polling
  - Disables predictions, routing, and landing detection while waiting for a response
- **Transitions**:
  1. `bleTelemetryState.hasTelemetry` → `liveBLEFlying` or `liveBLELanded` (based on `balloonPhase`)
  2. `aprsTelemetryIsAvailable` → `aprsFlying` or `aprsLanded` (based on `balloonPhase`)
  3. `APRS timeout` → `noTelemetry`

**State: `aprsFlying`**
- **Functionality**:
  - Enables APRS polling
  - **Triggers APRS track fill** (BalloonTrackService.fillTrackGapsFromAPRS()) — NEW
  - Calls chain: Prediction with APRS balloon position → Landing point tracking → Routing
  - Map shows balloon track, landing point, landing point track, predicted path, route
  - If RadioSondyGo is ready for commands, the app regularly checks its frequency/sonde type and issues a command to change its frequency/sondetype to the one reported from APRS
- **Transitions**:
  1. `bleTelemetryState.hasTelemetry` → `liveBLEFlying`
  2. `balloonPhase == .landed` → `aprsLanded`
  3. `APRS timeout` → `noTelemetry`

**State: `aprsLanded`**
- **Functionality**:
  - Enables APRS polling
  - **Updates landing point** to current balloon position and triggers route calculation — NEW
  - **Triggers APRS track fill** (BalloonTrackService.fillTrackGapsFromAPRS()) — NEW
  - Calls chain: Landing point tracking with APRS balloon position → Routing
  - Map shows balloon track, landing point, landing point track
  - Data panel shows motion metrics as zero
  - If RadioSondyGo is ready for commands, the app regularly checks its frequency/sonde type and issues a command to change its frequency/sondetype to the one reported from APRS
- **Transitions**:
  1. `bleTelemetryState.hasTelemetry` → `liveBLEFlying` or `liveBLELanded` (based on `balloonPhase`)
  2. `balloonPhase != .landed` → `aprsFlying`
  3. `APRS timeout` → `noTelemetry`

**State: `noTelemetry`**
- **Functionality**:
  - Enables APRS
  - On startup (before any BLE/APRS data) or after both feeds go silent
  - Data panel  shows placeholders (e.g., `"--"` distance, `"--:--"` arrival) while the red telemetry-stale frame
  - The flight state is set to unknown
  - Map shows balloon track, landing point, landing point track,
  - The last landing point is still valid and the tracking map (including routing) still works
- **Transitions**:
  1. `bleTelemetryState.hasTelemetry` AND `balloonPhase == .landed` → `liveBLELanded`
  2. `bleTelemetryState.hasTelemetry` → `liveBLEFlying`
  3. `aprsTelemetryIsAvailable` AND `balloonPhase == .landed` → `aprsLanded`
  4. `aprsTelemetryIsAvailable` → `aprsFlying`

### Key Design Principles

- **Input-Driven Transitions**: State changes occur only when input signals change.
- **No Debouncing**: State transitions between BLE and APRS sources occur immediately when telemetry availability changes. The 30-second BLE staleness threshold provides sufficient delay to prevent false positives, eliminating the need for additional debouncing.
- **APRS Polling Control**: The `APRSTelemetryService` handles polling frequency internally; the state machine enables/disables it. Exception: APRS polling starts immediately during startup (Step 2) 



## Architecture

Architecture enforces a clean separation of responsibilities while embracing a modular service layout, a coordinator, and a map presenter.

  - Separation of Concerns
  - Business logic lives in services and the coordinator; SwiftUI views remain declarative, consuming ready-to-render state from environment objects without reaching into data sources directly.
  - Coordinator as Orchestrator
    ServiceCoordinator only is used if it adds value. It listens to service publishers, applies cross-cutting rules that cannot be handled by one service alone, and publishes the mergrf result.
  - Modular Services
    Each service file bundles one domain: location tracking, balloon telemetry smoothing, persistence, routing, or prediction. Grouping the related caches (PredictionCache, RoutingCache) alongside their services keeps the surface area small and reduces coupling.
  - Presenter Layer for Complex Views
    The MapPresenter map-specific state transformations (overlay generation, formatted strings, user intents) so TrackingMapView does not need to manipulate coordinator or services state directly. This keeps the coordinator focused on orchestration and the view focused on layout.
  - Combine-Driven Data Flow
    Services publish changes via @Published properties or actors; the coordinator and presenter subscribe, transform, and re-publish derived values. This provides a single reactive pipeline from BLE/APRS/location inputs to UI outputs.
  - Environment-Driven UI: Views observe the coordinator, presenter, and settings objects through @EnvironmentObject. User actions (toggle heading, trigger prediction, open Maps) bubble up through intent methods defined on the presenter/coordinator instead of mutating state locally.
  - Persistence & Caching: PersistenceService handles simple file-based persistence (current track, landing history, user settings) using a single-sonde snapshot model. Caching actors prevent redundant prediction/route work. Both are injected once through AppServices, reinforcing a single source of truth.

#### Direct vs Coordinated Communication Patterns

The app uses a hybrid architecture that supports both direct service communication and ServiceCoordinator orchestration. The choice depends on the complexity and scope of the operation:

**✅ Use Direct Service Communication When:**
- Single service owns the data exclusively
- Simple one-to-one data binding needed
- View needs immediate service state access
- No cross-service coordination required
- Performance-critical data updates

**Examples:**
```swift
// ✅ Direct: Single service data display
@EnvironmentObject var balloonPositionService: BalloonPositionService
Text("Altitude: \(balloonPositionService.altitude)")

// ✅ Direct: Service-specific operations
balloonPositionService.manualLocationUpdate()
```

**✅ Use ServiceCoordinator When:**
- Multiple services must work together
- Complex state combining different sources
- Application-wide state management needed
- Startup sequences and lifecycle events
- Cross-cutting concerns (logging, caching, routing)

**Examples:**
```swift
// ✅ Coordinated: Cross-service operations
serviceCoordinator.triggerCompleteStartupSequence()
serviceCoordinator.openInAppleMaps() // Uses location + routing + settings

// ✅ Coordinated: Multi-service state
@Published var consolidatedFlightData: FlightData // Combines BLE + APRS + predictions
```

**Decision Matrix:**
| Scenario | Pattern | Reasoning |
|----------|---------|-----------|
| Display telemetry data | Direct | Single service ownership |
| Trigger predictions | Direct | PredictionService operation |
| Startup sequence | Coordinated | Multiple services coordination |
| Route calculation | Coordinated | Requires location + settings |
| Map camera updates | Direct via MapPresenter | Map-specific coordination |

**Anti-Patterns to Avoid:**
- Using ServiceCoordinator as simple data passthrough for single-service decisions
- Creating unnecessary coordination layers when direct access is simpler
- Views making direct service calls when coordination is needed

### File Structure

Do not open a new file without asking the user

#### Complete Service Layer Organization (22 Swift Files)

The codebase is organized into logical layers with clear separation of responsibilities:

**Infrastructure Layer:**
- `AppServices.swift` - Dependency injection container and service lifecycle management
- `CoreModels.swift` - Shared data structures, enums, and logging utilities
- `PersistenceService.swift` - Core Data persistence, file storage, and document management

**Communication Layer:**
- `BLEService.swift` - MySondyGo BLE protocol implementation and device communication
- `APRSTelemetryService.swift` - SondeHub API integration and APRS data management
- `LocationServices.swift` - GPS tracking, location services, and proximity detection

**Processing Layer:**
- `BalloonTrackingServices.swift` - Telemetry state machine, position tracking, and motion analysis
- `PredictionService.swift` - Tawhiri API integration with sophisticated caching (co-located PredictionCache)
- `RoutingServices.swift` - Apple Maps integration with performance-optimized RoutingCache

**Coordination Layer:**
- `Coordinator.swift` - ServiceCoordinator orchestration and cross-service state management
- `CoordinatorServices.swift` - Startup sequence and complex coordination operations
- `MapPresenter.swift` - Map-specific presentation logic and hybrid service access

**UI Layer:**
- `BalloonHunterApp.swift` - App entry point and environment object injection
- `TrackingMapView.swift` - Primary map interface (70% of screen) with 8 annotation types
- `DataPanelView.swift` - Telemetry display panel (30% of screen) with 2-table layout
- `SettingsView.swift` - Configuration interface with tabbed device settings

**Utility Layer:**
- `Settings.swift` - UserSettings and AppSettings with persistence management
- `DebugCSVLogger.swift` - Development telemetry logging and debugging support

**Service Communication Matrix:**
| Service | Access Pattern | Coordinator Integration |
|---------|---------------|------------------------|
| BLECommunicationService | Direct + Coordinated | Startup, frequency sync |
| BalloonPositionService | Direct | State machine updates |
| PredictionService | Direct | Timer control only |
| CurrentLocationService | Coordinated | Route calculations |
| PersistenceService | Direct | Background operations |

#### BalloonHunterApp.swift:

The main entry point of the application. It initializes the dependency container (`AppServices`), creates the `ServiceCoordinator`, injects both (plus shared services such as `LandingPointTrackingService`) into the SwiftUI environment, and manages scene lifecycle tasks like persistence saves and notification routing.

####  AppServices.swift:

A dependency injection container that wires up the core infrastructure: `PersistenceService`, `BLECommunicationService`, `CurrentLocationService`, `BalloonPositionService`, `BalloonTrackService`, `LandingPointTrackingService`, the caching actors, and other singletons used across the app.

#### ServiceCoordinator.swift:

The central architectural component that coordinates all services, manages application state, arbitrates telemetry between BLE and APRS providers, and contains the main business logic that was originally intended for the policy layer in the FSD.

#### CoordinatorServices.swift:

An extension to ServiceCoordinator that specifically contains the detailed 8-step startup sequence logic, keeping the main ServiceCoordinator file cleaner. Includes parallel APRS priming, state machine initialization, and startup map zoom functionality.

#### CoreModels.swift:

Centralizes the shared data types (`TelemetryData`, `BalloonTrackPoint`, `PredictionData`, etc.) plus logging helpers so every service can import the same model definitions without circular references.

#### LocationServices.swift:

Houses the `CurrentLocationService` and related helpers that manage background/precision GPS updates, distance overlays, and proximity checks against the balloon.

#### BalloonTrackingServices.swift:

Contains `BalloonPositionService`, `BalloonTrackService`, and `LandingPointTrackingService`. These coordinate telemetry parsing, track smoothing, landing detection, and persistence of historic track/landing data.

#### RoutingServices.swift:

**Apple Maps Integration with Performance Optimization:**

Comprehensive routing service with sophisticated caching and proximity-aware behavior:

**Cache Strategy:**
```swift
private func generateCacheKey(start: CLLocationCoordinate2D,
                             end: CLLocationCoordinate2D,
                             mode: TransportationMode) -> String {
    let startKey = "\(round(start.latitude * 100)/100)-\(round(start.longitude * 100)/100)"
    let endKey = "\(round(end.latitude * 100)/100)-\(round(end.longitude * 100)/100)"
    return "route-\(startKey)-\(endKey)-\(mode.rawValue)"
}
```

**Proximity Rules:**
- **200m Threshold**: Route visibility automatically hidden when user within 200m of landed balloon
- **Recalculation Triggers**: User movement >100m, transport mode change, landing point updates
- **Performance Optimization**: Cache prevents redundant Apple Maps API calls

**Transport Mode Support:**
```swift
enum TransportationMode: String, CaseIterable {
    case car = "car"
    case bike = "bike"

    var directionsMode: String {
        switch self {
        case .car: return MKLaunchOptionsDirectionsModeDriving
        case .bike: return MKLaunchOptionsDirectionsModeCycling
        }
    }
}
```

**Advanced Features:**
- **Bike Mode Optimization**: 30% time reduction for conservative Apple Maps bicycle estimates
- **Straight-line Fallback**: Ensures UI always has path display even without Apple Maps coverage
- **Cache Performance**: TTL-based expiration, LRU eviction, coordinate quantization
- **iOS Version Handling**: Cycling directions on iOS 14+, walking fallback for older versions

**Integration Points:**
- **Apple Maps Hand-off**: Direct navigation launch with transport mode preservation
- **Map Overlay**: Green route line (3px) with real-time updates
- **Data Panel**: ETA and distance calculations for recovery planning
- **Notification System**: Updated destination handling for background navigation

#### PersistenceService.swift:

Dedicated file for the `PersistenceService`, responsible for simple file-based persistence of current sonde state (track, landing history) and user settings. Uses single-sonde snapshot model with 3 JSON files.

#### BLEService.swift:

Contains the `BLECommunicationService`, which is responsible for all Bluetooth Low Energy communication, including device scanning, connection, and parsing incoming data packets from the MySondyGo device.

#### MapPresenter.swift:

**Hybrid Architecture Pattern**: MapPresenter uses both direct service access and ServiceCoordinator integration strategically:

- **Direct Service Access**: Single-service data that's map-specific (balloon position, track points, landing points)
- **Coordinated Access**: Cross-service operations requiring multiple services (prediction paths, user routes)
- **Map-Specific Coordination**: Aggregates, transforms, and republishes map state without duplicating coordinator logic

**Implementation Pattern:**
```swift
@MainActor
final class MapPresenter: ObservableObject {
    // DIRECT ACCESS: Single-service data
    private let balloonPositionService: BalloonPositionService
    private let balloonTrackService: BalloonTrackService

    // COORDINATED ACCESS: Cross-service operations
    private let coordinator: ServiceCoordinator

    // MAP-SPECIFIC STATE: Transformed for map display
    @Published private(set) var annotations: [MapAnnotationItem] = []
    @Published private(set) var region: MKCoordinateRegion?

    private func bindServices() {
        // Direct subscription to single services
        balloonPositionService.$landingPoint
            .sink { [weak self] point in
                self?.landingPoint = point
                self?.refreshAnnotations() // Map-specific transformation
            }
            .store(in: &cancellables)

        // Coordinated access for complex operations
        coordinator.$predictionPath
            .sink { [weak self] path in
                self?.predictionPath = path
            }
            .store(in: &cancellables)
    }
}
```

**Responsibilities:**
- Map annotation generation and management
- Camera position and zoom level coordination
- Map overlay state transformation (track lines, prediction paths, routes)
- User intent handling (toggle heading mode, trigger predictions, open Apple Maps)
- Distance calculations and formatting for map display

#### TrackingMapView.swift:

**Primary Map Interface (70% of Screen):**

Comprehensive map view with sophisticated overlay system and user controls:

**Layout Structure:**
```swift
VStack(spacing: 0) {
    // Top control panel with horizontal scroll
    ScrollView(.horizontal) {
        HStack(spacing: 12) {
            Button("Settings") // Gear icon
            Picker("Transport Mode") // Car/Bike segmented control
            Button("All/Point") // Show all annotations or set landing point
            Button("Heading Mode") // Location/compass toggle
            Button("Buzzer") // Speaker mute control
            Button("Apple Maps") // External navigation (when landing point available)
        }
    }

    // Map with 8 annotation types (70% height)
    Map(position: $position, interactionModes: mapPresenter.isHeadingMode ? .zoom : .all) {
        // 1. Balloon Track: Historic track as thin red line (2px)
        // 2. Balloon Predicted Path: Thick blue line (4px, flying mode only)
        // 3. Planned Route: Green path from user to landing point (3px)
        // 4. Landing History: Purple polyline connecting Sondehub estimates (2px)
        // 5. User Position: Runner icon (figure.run) with blue circle background
        // 6. Balloon Live Position: balloon.fill icon, color-coded by phase
        // 7. Burst Point: burst.fill icon, orange (ascending mode only)
        // 8. Landing Point: target icon, purple background (when available)
    }

    // Map type toggle overlay (top-right corner)
    Button("Map Type") // map/map.fill icon - toggles between standard and satellite view

    // Distance overlay (landing mode only)
    if isLanded {
        DistanceOverlayView(distanceMeters: mapPresenter.distanceToBalloon)
    }
}
```

**Color Coding System:**
- **Green**: Ascending balloon phase
- **Orange**: Descending above 10k altitude
- **Red**: Descending below 10k altitude
- **Purple**: Landed balloon phase
- **Blue**: Prediction paths and user position
- **Gray**: Unknown phase

**Interactive Features:**
- Heading mode: User location tracking with compass orientation
- Free mode: Full pan/zoom interaction
- Map controls: Scale, user location button (compass removed - functionality covered by heading mode button)
- Map type toggle: Standard/satellite view switcher overlaid on top-right corner of map
- Zoom preservation between mode switches

#### DataPanelView.swift:

**Telemetry Display Panel (30% of Screen):**

Two-table layout providing comprehensive real-time data display:

**Left Table - Live Telemetry:**
```
Row 1: Serial Name    | Altitude (m)     | Timestamp
Row 2: Position       | Speed (m/s)      | Course (°)
Row 3: Environment    | Signal (dBm)     | Battery (%)
Row 4: Descent Rate   | Distance (km)    | Status
```

**Right Table - Predictions & Route:**
```
Row 1: Burst Alt (m)  | Landing Time     | Route Info
Row 2: Flight Time    | Distance (km)    | ETA
Row 3: Prediction     | Transport Mode   | Status
Row 4: Cache Stats    | Last Updated     | Version
```

**Data Sources:**
- **ServiceCoordinator**: Consolidated cross-service data (route, predictions)
- **Direct Service Access**: Single-service data for performance
- **Real-time Updates**: Combine-driven reactive updates
- **Formatted Strings**: Pre-formatted by services for display consistency

**Layout Implementation:**
- Grid-based responsive layout adapting to screen size
- Automatic text scaling for accessibility
- Color-coded status indicators
- Smooth animation transitions for data changes

#### SettingsView.swift:

Contains the UI for all settings, including the main "Sonde Settings" and the tabbed "Device Settings" sheet (with inlined numeric text field control).

#### PredictionService.swift:

**Tawhiri API Integration with Advanced Caching:**

Implements sophisticated trajectory prediction using the Tawhiri API with performance-optimized caching:

**Caching Strategy:**
```swift
// 5-minute time bucket caching with coordinate rounding
private func generateCacheKey(lat: Double, lon: Double, altitude: Double, time: Date) -> String {
    let roundedLat = round(lat * 100) / 100  // 0.01° precision (~1km)
    let roundedLon = round(lon * 100) / 100
    let roundedAlt = round(altitude / 1000) * 1000  // 1km precision
    let timeBucket = Int(time.timeIntervalSince1970 / 300) * 300  // 5-min buckets
    return "pred-\(roundedLat)-\(roundedLon)-\(roundedAlt)-\(timeBucket)"
}
```

**Dual Descent Rate Logic:**
- **Below 10,000m**: Uses smoothed rate from actual balloon data for accuracy
- **Above 10,000m**: Uses user-configured descent rate settings
- Automatic switching provides optimal prediction accuracy throughout flight

**State Machine Control:**
- Predictions enabled only in flying states (ascending, descending)
- Manual prediction triggers available via user interface
- Timer paused during landed state to conserve API quota

**Cache Performance:**
- TTL-based expiration (5-minute default)
- LRU eviction for memory management
- Hit/miss metrics tracking for optimization
- Coordinate quantization reduces cache misses

**API Integration:**
- Request throttling and error handling
- Graceful degradation for network failures
- Response validation and plausibility checking
- Time calculation strings published directly for UI consumption

#### DebugCSVLogger.swift:

Utility that records incoming telemetry frames (excluding development sondes) to a CSV file in the app’s documents directory for offline analysis.

#### Settings.swift:

Defines `UserSettings`, `DeviceSettings`, and app-level configuration structures. UserSettings (prediction defaults) are persisted. DeviceSettings and transportMode are ephemeral (not persisted).



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

**Note**: BLE telemetry state is managed by `BLECommunicationService` via the `BLETelemetryState` enum. APRS availability is managed by `BalloonPositionService` via `aprsTelemetryIsAvailable` for proper separation of concerns.

**Central Manager Lifecycle**

- `centralManagerDidUpdateState` logs state transitions. When `.poweredOn`, emits `centralManagerPoweredOn` and marks BLE healthy; when powered off/unauthorized, sets `connectionStatus = .disconnected` and publishes an unhealthy event.
- `startScanning()` runs only when Bluetooth is powered on. Scans for peripherals advertising the UART service whose name contains "MySondy"; duplicate discovery is disabled. **Continuous scanning**: When not connected, scanning runs continuously with automatic retry (10s delay after timeout) to enable automatic device discovery and reconnection.

**Peripheral Discovery & Connection**

- `didDiscover` accepts devices whose name contains “MySondy”. Stops scanning, assigns `connectedPeripheral`, sets the delegate, and calls `connect`.
- `didConnect` logs success, sets `connectionStatus = .connected`, and starts `discoverServices([UART_SERVICE_UUID])`.
- `didFailToConnect` logs an error and restarts scanning.
- `didDisconnect` logs whether the disconnect was clean or error-driven, flips `connectionStatus` to `.notConnected`, and immediately restarts scanning to enable automatic reconnection.

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
  - `setFrequency(_:probeType:)` formats `o{f=/tipo=}`, writes it, and mirrors the change into `deviceSettings` and `latestTelemetry` so the UI reflects the new value immediately (frequencies are rounded to 0.01 MHz to match the RadioSondyGo step size).
  - `setMute(_:)` toggles the buzzer via `o{mute=0|1}o` and keeps the cached mute flag aligned with the device.
  - `setSettings(_:)` wraps key/value configuration updates (e.g., APRS name mode, bandwidths, GPIO configuration) and delegates to the generic settings command builder.
- Each helper constructs the UART command, writes to TX (preferring `.withResponse`), and guards against attempts when TX is unavailable—emitting a log instead of mutating state.

**Telemetry Staleness Detection**

- `updateBLEStaleState()` runs every 3 seconds; if the latest Type‑1 packet is older than 30 seconds, logs "Telemetry LOST" and downgrades connection state from `dataReady` to `readyForCommands`; when telemetry resumes it logs "Telemetry GAINED".
- Note: This function manages the BLE connection state transitions based on telemetry age. The state machine in `BalloonPositionService` monitors these connection state changes to trigger APRS fallback.

**Stability Notes**

- All CoreBluetooth errors are caught and logged without crashing the service.
- CSV logging for each telemetry sample is handled downstream (`BalloonTrackService` → `DebugCSVLogger`).
- Automatic settings requests happen once after the first valid packet; subsequent requests are user-driven via the settings UI.



### APRS Service

**Purpose**
Provide SondeHub-driven telemetry frames whenever BLE telemetry data is unavailable. It is also used to program the correct frequendy/sonde type in RadioSondyGo.

#### Input Triggers

- Startup
- State machine
- Station-ID changes in settings (e.g., switching to a different launch site).

#### Ground Test Sonde Filtering

The APRS service filters out ground-based test sondes to prevent them from being selected as the target balloon:
- **Distance Filtering**: Sondes within 1 km of the uploader position are automatically filtered out
- **Uploader Position Source**: Uses the `uploader_position` field from SondeHub API (format: "latitude,longitude")
- **Haversine Calculation**: Accurate distance calculation between sonde and uploader using Earth's curvature
- **Logging**: Filtered ground test sondes are logged with their distance from uploader for debugging

#### Data it Consumes

1. SondeHub site data: `GET /sondes/site/<station_id>` (Payerne = `06610`). This single call provides both the latest sonde serial numbers and their most recent telemetry data.
2. Station configuration stored in user settings (defaults to Payerne).

#### Data it Publishes

- `positionData` objects tagged with `.aprs` for the same consumers that read BLE frames.
- Service state (current station ID, last SondeHub serial, poll cadence) for diagnostics.
- The service shall be compatible with th BLE telemetry service and use the same communication channel for telemetry

#### Behavior

- Call `/sondes/site/<station_id>`.
- From the response, identify the most recent sonde by its timestamp.
- Convert the telemetry data for that sonde directly into `positionData` and publish it so `BalloonTrackService` treats it exactly like BLE telemetry. 
- Intelligent polling for API efficiency based on telemetry age:
  - Fresh data (< 2 minutes): 15-second polling
  - Stale data (2-30 minutes): 5-minute polling
  - Very old data (> 30 minutes): 1-hour polling  
- Suspend polling when asked
- The APRS service only supplies raw telemetry frames

#### APRS Telemetry Gap Filling

**Purpose**: The APRS service fetches complete APRS track data from SondeHub to fill gaps in the local BLE track. This ensures the user always receives all available telemetry data for the current sonde, even if BLE connection was interrupted or established mid-flight.

**API Endpoint**: `GET /sondes/telemetry?serial=<serial>&duration=<duration>`
- Default duration: `3d` (SondeHub retains data for ~3 days)
- Returns nested JSON: `{ "serial": { "timestamp": { telemetry_fields } } }`
- Response size: ~9.6 MB uncompressed (685 KB gzipped) for 10,000 points
- Response time: ~9 seconds (server processing ~9s, download <0.2s)

**APRS Point Fields** (parsed from SondeHub response):
- Essential tracking: `serial`, `datetime`, `lat`, `lon`, `alt`
- Motion data: `vel_v` (vertical speed), `vel_h` (horizontal speed)
- *Note*: Only essential fields are extracted for efficiency; environmental/hardware metadata is discarded

**Timeout Configuration**:
- Regular polling: 5 seconds (for quick site endpoint responses)
- APRS telemetry: 30 seconds (allows for 9s typical response + network buffer)

**Gap Filling Process**:
1. Fetch complete APRS track for current sonde serial number
2. Compare local track timestamps with APRS telemetry timestamps
3. Filter to only new points (not already in local track)
4. Convert to `BalloonTrackPoint` format (lat/lon/alt/timestamp/speeds)
5. Merge into local track and sort by timestamp
6. Persist combined track for future sessions

This mechanism ensures users see the complete balloon flight path even if they connect to MySondyGo after launch.

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

**Purpose:** Manages simple file-based persistence for the current sonde's state and user settings. Persists data during app run (batched) and at app shutdown to survive forced close.

**Architecture:** Single-sonde state snapshot model. The app only works with ONE sonde at a time. Past flight data is handled separately by CSV logger (write-only, never loaded at startup).

####   Input Triggers:

1. **App startup** - Load persisted state into services
2. **During run** - Save track (batched), landing points (immediate on each new point), sonde name (immediate on change)
3. **Settings changes** - Save userSettings immediately
4. **App shutdown** - Final save of all state

####   Persisted Files (4 total):

1. **userSettings.json** - UserSettings (immediate save on change)
2. **sondeName.json** - Current sonde name String (must always match balloontrack.json data)
3. **balloontrack.json** - Current sonde's `[BalloonTrackPoint]` (batched saves)
4. **landingPoints.json** - Current sonde's `[LandingPredictionPoint]` (immediate save on each new point)

**Consistency constraint:** sondeName.json and balloontrack.json must always correspond to the same sonde. When sonde changes, both files are overwritten together.

####   Data it Publishes:

1. @Published var userSettings: UserSettings - Prediction parameters

####   Example Data:

UserSettings(
    burstAltitude: 30000.0, // meters
    ascentRate: 5.0, // m/s
    descentRate: 5.0, // m/s
    stationId: "06610" // Payerne
)

#### Ephemeral Data (NOT persisted):

* **deviceSettings** - Stored in MySondyGo device, not persisted in app
* **radioSettings** - Stored in MySondyGo device, read from telemetry packets
* **transportMode** - Defaults to .car each launch
* **burstKiller** - Calculated each session, not persisted
* **Past flight tracks** - Handled by CSV logger separately (write-only)

#### Types of Data:

* **User Settings:** Forecast parameters (burstAltitude, ascentRate, descentRate, stationId) persist across sessions so users don't re-enter them.
* **Sonde Name:** Current sonde name - must always correspond to the track data in balloontrack.json.
* **Current Track:** Single sonde's track points with timestamps. Batched saves during run survive forced close. Always paired with sondeName.json.
* **Landing Predictions:** Single sonde's landing prediction history for map display. Each new landing point saved immediately.

### Balloon Position Service

**Purpose**  
Store the most recent telemetry snapshot (coordinates, altitude, sonde name, vertical speed) and keep the current distance from the user to the balloon up to date.

#### Inputs

- Type 1 telemetry packets published by `BLECommunicationService`.
- User location updates from `CurrentLocationService`.

#### Publishes

- `currentTelemetry`, `currentPosition`, `currentAltitude`, `currentVerticalSpeed`, `currentBalloonName`.
- `distanceToUser` (meters), `timeSinceLastUpdate`, `hasReceivedTelemetry`.
- `aprsTelemetryIsAvailable` - APRS telemetry availability state for the entire app.
- `burstKillerCountdown`, `burstKillerReferenceDate` - burst killer timing from BLE.

#### Behavior

- **Telemetry Management**: Subscribes to both BLE and APRS telemetry streams, implementing arbitration logic (APRS only used when BLE unavailable).
- **Availability State**: Manages `aprsTelemetryIsAvailable` based on APRS connection status and telemetry flow. BLE state managed by BLECommunicationService.
- **Position Tracking**: Caches the latest packet, updating timestamp and derived values. Recomputes distance when user location changes.
- **Balloon Phase Detection**: Determines flight phase with priority order:
  1. `landed` (highest priority): Track-based landing detected (BalloonTrackService.trackBasedLandingDetected) — NEW
  2. `landed`: APRS age > 120s
  3. `landed`: Vector analysis (BalloonTrackService) - net speed < 3 km/h AND altitude < 3000m
  4. `ascending`: vertical speed > 0
  5. `descendingAbove10k`: vertical speed < 0 AND altitude ≥ 10,000m
  6. `descendingBelow10k`: vertical speed < 0 AND altitude < 10,000m
  7. `unknown`: vertical speed = 0
- **Staleness Detection**: A 1 Hz timer updates `timeSinceLastUpdate` and `isTelemetryStale` for downstream consumers.
- **APRS Integration**: Automatically notifies APRSTelemetryService of BLE health changes to control APRS polling.
- **Burst Killer**: Manages burst killer countdown from BLE, retaining last known value in memory during APRS sessions.
- Exposes helper methods (`getBalloonLocation()`, `isWithinRange(_:)`, etc.) for downstream policies.

### Balloon Track Service

**Purpose**  
Build the flight history, smooth velocities, detect landings, derive descent metrics, and persist track data for the active sonde.

#### Inputs

- `BalloonPositionService.$currentTelemetry` for every telemetry sample.
- `PersistenceService` to load/save current track (single-sonde snapshot).

#### Publishes

- `currentBalloonTrack`, `currentBalloonName`, `currentEffectiveDescentRate`.
- `trackUpdated` (Combine subject), `landingPosition`, `balloonPhase`.
- `trackBasedLandingDetected` (Bool), `trackBasedLandingTime` (Date?) — NEW: Flags for track-based landing detection.
- `motionMetrics` struct (raw horizontal/vertical speeds, smoothed horizontal/vertical speeds, adjusted descent rate).
- `isTelemetryStale` flag for UI highlighting.

#### Behavior

1. **Sonde management** — When a new sonde appears, the service clears the previous track and counters, then starts fresh. At app startup, persisted track from previous session (if any) is loaded from balloontrack.json.
2. **Track updates with slot-based deduplication** — Each telemetry sample is converted into a `BalloonTrackPoint`; if a previous point exists the service recomputes horizontal speed via great-circle distance and vertical speed via altitude delta for consistency. **Slot-based deduplication**: Track stores maximum 1 point per second (identified by rounded timestamp). Before insertion, checks if slot is occupied. BLE points (arriving chronologically) simply append if slot empty. APRS batch points check all slots, append points to empty slots only (no sorting needed - points naturally stay chronological). This prevents duplicate points when BLE and APRS report same second, with BLE naturally taking priority. Map updates immediately on each BLE point and once per APRS batch. Descent regression is updated, and observers receive `trackUpdated`.

2a. **APRS track filling** — `fillTrackGapsFromAPRS(sondeName: String? = nil, forceDetection: Bool = false)` fetches APRS telemetry from SondeHub API and inserts missing points into the track using slot-based deduplication. Called automatically when state machine transitions to APRS states (`aprsFlying`, `aprsLanded`), during sonde changes, and when app returns from background during flight. Function validates sonde name hasn't changed during async fetch, captures track size before insertion for scenario detection, inserts APRS points into empty slots only (BLE takes priority), saves track, then conditionally runs track-based landing detection based on two triggers: (1) **Historical track load**: track exists before fetch AND last packet timestamp is older than 20 minutes (`lastPacketAge > 1200 seconds`), OR (2) **Background return**: `forceDetection = true` flag passed from foreground resume handler. If either condition is true, `detectTrackBasedLanding()` executes to analyze complete track for blackout gaps or stationary periods. Detection is skipped for incremental APRS updates to avoid unnecessary CPU-intensive processing (1.5+ seconds on 10K+ point tracks). **Task cancellation**: Tracks `currentAPRSFillTask` and cancels any existing fill operation before starting a new one, or when `clearAllData()` is called during sonde changes. Running tasks check `Task.checkCancellation()` after API fetch and before processing results to exit cleanly with `CancellationError` when cancelled. This prevents stale APRS data from old sondes being processed after sonde change completes.

3. **Speed smoothing** — Maintains Hampel buffers (window 10, k=3) to reject outliers, applies deadbands near zero, and feeds an exponential moving average (τ = 10 s) to publish smoothed horizontal/vertical speeds alongside the raw telemetry values within `motionMetrics`.
4. **Adjusted descent rate** — Looks back 60 s over the track, computes interval descent rates, takes the median, and keeps a 20-entry rolling average; the latest value is exposed through `motionMetrics` (and zeroed when the balloon is landed).

5. **Landing detection** — **MOVED TO BALLOONPOSITIONSERVICE**: Vector analysis algorithm calculates net movement across dynamic 5-20 packet windows. Landing detected when net speed < 3 km/h AND altitude < 3000m. Confidence ≥ 75 % flips `balloonPhase` to `.landed` and averages the buffered coordinates for the landing point; confidence < 40 % for three consecutive updates (or too few samples) returns the phase to the appropriate flight state. APRS packets older than 120 s also force `.landed` so stale data doesn’t masquerade as an in-flight balloon.

5a. **Track-based landing detection and automatic track removal after landing position**  — `detectTrackBasedLanding()` analyzes the entire track after APRS fill completes to find landing point and remove post-landing data. 
**Standard case**: Balloon lands and stays at landing location - track naturally ends at landing, no truncation needed (handled by real-time landing detection). **Special cases requiring track truncation** (checked in order):

   - **Telemetry blackout scenario**: Balloon lands, signal lost for >20 minutes after burst, then recovered/moved and transmits again from different location. Landing = last point before gap. Track truncated at gap - everything after is post-recovery transmission from recovery team. User is notified via local notification that post-landing track points were removed due to detected blackout.
   - **Stationary period scenario**: Balloon lands and transmits stationary position for 20+ minutes, then moved (recovery/transport) while still transmitting. Uses 1200-point sliding window to calculate moving averages of lat/lon/altitude changes **only after burst**. If all three averages below threshold (lat/lon < 0.0001° ≈ 11m, altitude < 0.3 m/point), balloon marked as landed and track truncated. **Altitude detection prevents false positives during descent** where balloon falls nearly straight down. This takes **highest priority** over all other landing detection methods in BalloonPositionService. Triggers state machine evaluation to transition to landed state. Runs automatically after APRS telemetry fill and on restored persisted tracks at startup. User is notified via local notification that post-landing track points were removed due to detected stationary period.

**User notification**: When track truncation occurs, the app sends a short local notification explaining why points were removed (e.g., "Landing detected: Removed 147 post-landing track points from recovery period"). This helps the user understand track changes and confirms the landing detection worked correctly.

5b. **Track-based landing detection trigger scenarios** — To avoid unnecessary CPU-intensive analysis (1.5+ seconds on 10K+ point tracks), track-based landing detection runs conditionally based on specific scenarios rather than on every APRS poll. The following scenarios determine when detection should run and when track recording should continue or stop:

   **Scenario 1: Track Load when the last packet is older than 20 minutes (App started After Flight ended)**
   When the app hasn't run during the flight and the user launches it, the persisted track contains historical data where the last packet timestamp is more than 20 minutes old. This indicates the app wasn't running during the recent flight period. During startup, when the state machine transitions to an APRS state (Step 5), `fillTrackGapsFromAPRS()` is called automatically. Inside this function, detection logic checks: (1) track has data before APRS fetch (`trackSizeBeforeInsertion > 0`), and (2) last packet timestamp is older than 20 minutes (`lastPacketAge > 1200 seconds`). If both conditions are true, track-based landing detection runs on the complete track to analyze the entire historical flight path for blackout gaps or stationary periods that indicate where the balloon landed. If a new/different sonde is detected during APRS fetch, the sonde change flow clears all old data first. Track recording continues normally for all telemetry sources after detection completes.

   **Scenario 2: APRS-Only Mode After Landing Detected (No BLE)**
   When the balloon has landed and BLE is not available (state machine is in `aprsLanded`), APRS polling continues at a reduced frequency to confirm the balloon remains landed, but track recording must stop to prevent unnecessary data accumulation. The hunter no longer needs continuous track updates once the balloon is stationary on the ground with no BLE connection. Detection method: The state machine has already transitioned to `aprsLanded` based on age-based landing detection (APRS telemetry older than 120 seconds) or track-based landing detection. In `processPositionData()`, check the current state before recording track points. If state is `aprsLanded`, skip appending the point to `currentBalloonTrack`. APRS polling remains enabled (not disabled) to periodically verify landing status.

   **Scenario 3: App Returns from Background During Flight**
   When the user backgrounds the app during an active flight and later returns to the foreground, the app must fetch any APRS data accumulated during the background period and run track-based landing detection to determine if the balloon landed while the app was inactive. Detection method: Monitor app lifecycle using SwiftUI's `scenePhase` environment variable. When `scenePhase` transitions from `.background` to `.active`, check if the current state is a flying state (`liveBLEFlying` or `aprsFlying`). If flying, set a flag indicating "background return during flight" and trigger `balloonPositionService.refreshCurrentState()`, which calls `fillTrackGapsFromAPRS()`. Pass this flag to `fillTrackGapsFromAPRS()` so it knows to run track-based detection regardless of the number of points added. Track recording continues normally for all telemetry sources.

   **Scenario 5: Landing Detected with BLE Active**
   When the balloon has landed but BLE remains connected and active (state machine is in `liveBLELanded`), track recording must continue because the hunter needs real-time position updates as they approach the balloon on foot or by vehicle. BLE provides live telemetry as the hunter gets closer, which is critical for final navigation to the landing site. Detection method: The state machine has already transitioned to `liveBLELanded` based on real-time BLE landing detection (5-packet window showing net speed below 3 km/h and altitude below 3000 meters). APRS polling stops (already implemented via `aprsService.disablePolling()` in the `liveBLELanded` state handler). In `processPositionData()`, the state check allows track recording to continue for all states except `startup`, `waitingForAPRS`, and `noTelemetry`. Since `liveBLELanded` is not in the exclusion list, BLE track points continue to be recorded and published. Track recording continues as long as BLE remains active, regardless of landing status.

   **Summary**: Track-based landing detection runs conditionally (Scenarios 1 and 3 only). Track recording behavior depends on data source availability: stops in `aprsLanded` (Scenario 2) when no BLE available, continues in `liveBLELanded` (Scenario 5) when BLE active because hunter needs live updates during approach.

6. **Staleness** — A 1 Hz timer flips `isTelemetryStale = true` whenever the latest telemetry is more than 3 s old.
7. **Persistence** — Saves the track every 10 telemetry points via `saveBalloonTrack`. Helpers expose the full track for app-shutdown persistence (`saveOnAppClose`). CSV logging for each telemetry sample is routed to `DebugCSVLogger`.
8. **Motion metrics publishing** — After each telemetry sample the service emits a `BalloonMotionMetrics` snapshot so downstream consumers can pick either the raw or smoothed values without re-computing them; smoothed values and descent rate are reset to zero once the balloon is landed.

### Landing Point Tracking Service

**Purpose**  
Maintain the list of landing predictions for the active sonde, deduplicate noisy updates, and persist/restore the history for reuse in the tracking map.

#### Inputs

- Landing predictions (coordinate, prediction time, optional ETA) produced by `PredictionService` / coordinator.
- `BalloonTrackService.$currentBalloonName` to detect sonde changes.
- `PersistenceService` for load/save operations (single-sonde snapshot).

#### Publishes

- `landingHistory` (ordered `LandingPredictionPoint` array).
- `lastLandingPrediction` (latest entry, or `nil`).

#### Behavior

- When the active sonde changes, the previous history is cleared (new sonde starts with empty landing history), and `lastLandingPrediction` is updated.
- New landing predictions are deduplicated against the last point (25 m threshold) to avoid jitter; if it's a new location, it is appended and immediately saved to landingPoints.json.
- Each new landing point triggers immediate persistence (not batched).
- `resetHistory()` wipes the array and published “last” value so each balloon starts with a clean slate.
- The tracking map observes `landingHistory` to draw the purple polyline and dots for past landing predictions.

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
6. **Task cancellation**: Tracks `currentPredictionTask` and cancels it immediately when starting a new prediction or when `clearAllData()` is called during sonde changes. Running tasks check `Task.checkCancellation()` before cache lookup, API call, and result publishing to exit cleanly with `CancellationError` when cancelled. This prevents stale results from old sondes being published after sonde change completes.

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
7. **Task cancellation**: Tracks `currentRouteTask` and cancels it immediately when starting a new route calculation or when `clearAllData()` is called during sonde changes. Running tasks check `Task.checkCancellation()` before route calculation and before publishing results to exit cleanly with `CancellationError` when cancelled. This prevents stale routes to old sonde landing points being published after sonde change completes.

#### Smart Route Recalculation

The service implements intelligent route recalculation to minimize API calls while maintaining accuracy:

**Recalculation Triggers**:
1. **Landing Point Movement** (≥100m threshold):
   - When predicted landing point moves ≥100 meters, route is recalculated
   - Minor prediction updates (<100m) keep existing route to prevent excessive API calls
   - Typical balloon chase: 2-5 recalculations as landing point converges during descent

2. **Off-Route Detection** (≥50m threshold):
   - User's current position is continuously compared to planned route polyline
   - Perpendicular distance to nearest route segment is calculated using point-to-line geometry
   - If user deviates ≥50 meters from route, automatic recalculation is triggered
   - Follows navigation best practices similar to commercial navigation apps

3. **Transport Mode Changes**:
   - Switching between car/bike modes immediately recalculates route with new transport type
   - Mode is preserved across all automatic recalculations

**Off-Route Detection Implementation**:
- Route polyline is stored in `CurrentLocationService` for deviation monitoring
- On each location update (every 10m in normal mode, 2m in heading mode):
  - Calculates minimum perpendicular distance from user position to route segments
  - Uses dot product projection to find closest point on each line segment
  - Triggers `shouldUpdateRoute` flag when threshold exceeded
- `RouteCalculationService` subscribes to off-route events and recalculates automatically

**API Efficiency**:
- Typical balloon chase: 3-8 total API calls (initial + landing point moves + off-route corrections)
- No time-based periodic recalculation (eliminates ~360 calls/hour overhead)
- No redundant calls when user stays on route and landing point is stable

#### Automatic Route Calculation on GPS Availability

The service includes a retry mechanism for when route calculation is triggered before user location is available (common during startup):

**Location Subscription**:
- Subscribes to `CurrentLocationService.$locationData` in `init()`
- Monitors for GPS location becoming available

**Automatic Retry Logic**:
1. When `calculateRoute(to:)` is called without user location available:
   - Stores destination in `lastDestination`
   - Logs info message about pending route calculation
   - Returns early (no error)
2. When user location becomes available (via publisher):
   - Checks if destination is stored AND no route exists yet
   - Automatically calculates route to stored destination
   - Logs success with ✅ emoji marker
3. If user location is lost after being available:
   - Clears current route
   - Logs warning

**Startup Optimization**:
- User location request moved to Step 1 of startup sequence (before track loading)
- Gives GPS maximum time (~7s typical) to get fix before route calculation is needed
- Route appears automatically when both location and landing point are available

#### Notes

- Bike travel times are shortened by 30 % to offset conservative Apple Maps (walking) estimates when MapKit directions are used; the native Maps hand-off still opens true cycling mode via the transport toggle.
- Straight-line fallback ensures the UI always has a path to display, even without Apple Maps coverage.
- `RoutingCache` entries expire automatically; metrics are logged for cache hits/misses.

### Navigation Service

**Purpose**
Manage external navigation integration with Apple Maps and provide landing point change notifications for users navigating with CarPlay or external navigation apps.

#### Inputs

- Landing point coordinates for Apple Maps launch
- New landing point coordinates for change detection

#### Publishes

- None (triggers external actions: Apple Maps launch, iOS notifications)

#### Behavior

**Apple Maps Integration**:
1. Receives landing point coordinate from ServiceCoordinator
2. Creates `MKMapItem` with "Balloon Landing Site" label
3. Launches Apple Maps with transport mode matching RouteCalculationService setting:
   - Car mode → Driving directions
   - Bike mode → Cycling directions (iOS 14+, falls back to walking)

**Landing Point Change Notifications**:
1. Stores last landing point for comparison on each update
2. When landing point changes:
   - Calculates distance between old and new landing points
   - If movement >300m → Sends iOS notification
   - Updates stored landing point for next comparison
3. Notification includes:
   - Title: "Landing Prediction Updated"
   - Body: Distance moved in meters
   - User info: New destination coordinates for tap handling

**Reset Handling**:
- `resetForNewSonde()` clears stored landing point when new sonde detected
- Prevents false notifications when switching between different balloon sondes

#### Integration

**Service Chain**:
```
LandingPointTrackingService.updateLandingPoint()
    ↓ auto-chains
NavigationService.checkForNavigationUpdate()
    ↓ if moved >300m
iOS Notification System
```

**CarPlay Use Case**:
- BalloonHunter runs in foreground on iPhone screen
- Apple Maps displays on CarPlay screen (separate process)
- Notifications alert user to significant landing point changes while driving
- User can glance at iPhone to see updated landing prediction

#### Notes

- Notifications only fire when app is in foreground (background predictions suspended per BACKGROUND_TRACKING.md)
- 300m threshold prevents spurious alerts from minor prediction adjustments
- First landing point stored without notification (baseline for comparison)
- Sonde change resets tracking to prevent false alerts when switching balloons

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

**Landing Point Coordination**

The `ServiceCoordinator` is responsible for cross-service coordination to determine the single, authoritative landing point. It subscribes to state machine changes and data updates, then updates `LandingPointTrackingService` which serves as the single source of truth for all consumers. This follows the coordinator pattern for cross-service decision-making:

    1.  **Single Source of Truth**:
        *   `LandingPointTrackingService.currentLandingPoint` is the only published landing point property
        *   All services and views consume from this single source (no duplicate landing point properties)
    
    2.  **ServiceCoordinator Subscriptions** (cross-service coordination):
        *   Subscribes to `balloonPositionService.$currentState` (state machine changes)
        *   Subscribes to `balloonPositionService.$currentPositionData` (telemetry updates)
        *   Subscribes to `predictionService.$latestPrediction` (prediction updates)
    
    3.  **Landing Point Source Selection** (based on state machine):
        *   **Flying States** (`.liveBLEFlying`, `.aprsFlying`, `.waitingForAPRS`):
            - Uses `predictionService.latestPrediction.landingPoint`
            - ServiceCoordinator updates `LandingPointTrackingService` with `.prediction` source
        *   **Landed States** (`.liveBLELanded`, `.aprsLanded`):
            - Uses `balloonPositionService.currentPositionData` (lat/lon)
            - ServiceCoordinator updates `LandingPointTrackingService` with `.currentPosition` source
        *   **No Telemetry States** (`.startup`, `.noTelemetry`):
            - Landing point is `nil`
    
    4.  **Automatic Updates**:
        *   When state changes, ServiceCoordinator immediately evaluates and updates landing point
        *   When position data updates (in landed states), ServiceCoordinator updates landing point
        *   When prediction updates (in flying states), ServiceCoordinator updates landing point
        *   LandingPointTrackingService automatically chains to RouteCalculationService
2. **Telemetry pipeline** — `BalloonTrackService` ingests BLE/APRS telemetry, performs smoothing, while `BalloonPositionService` maintains the authoritative `balloonPhase` (including forcing `.landed` when APRS packets are older than 120 s), and publishes both raw and smoothed motion metrics. ServiceCoordinator monitors state changes to coordinate landing point updates.
3. **Landing point workflow** — ServiceCoordinator subscribes to state machine, position data, and predictions, then coordinates landing point updates to `LandingPointTrackingService` which automatically chains to route calculation and map updates.
4. **Prediction scheduling** — Hands telemetry and settings to `PredictionService`, reacts to completions/failures, and exposes landing/flight time strings for the data panel.
5. **Route management** — Requests routes when the landing point or user location changes, updates the green overlay, surfaces ETA/distance in the data panel, and honours cache hits to avoid redundant Apple Maps calls.
6. **UI state management** — Owns camera mode (`isHeadingMode`), overlay toggles, buzzer mute (with automatic sync from `buzmute` field in BLE Type 0/1/2 messages), centre-on-all logic, and guards against updates while sheets (settings) are open.
7. **Apple Maps hand-off & navigation notifications** — `openInAppleMaps()` launches navigation using the selected transport mode (car → driving, bike → cycling on iOS 14+ with walking fallback). Landing point updates automatically trigger NavigationService to check for significant changes (>300m) and send iOS notifications to alert users during CarPlay navigation.
8. **Optional APRS bridge** — When an APRS provider is enabled, the coordinator brokers SondeHub serial prompts, pauses APRS polling whenever fresh BLE telemetry is available, and synchronises RadioSondyGo frequency/probe type to match APRS telemetry when the streams differ.
9. **Frequency Mismatch** - If a RadioSondyGo is connected, it compares its freuqncy with the APRS frequency and, if a mismatch is detected, a confirmation alert appears on screen. This screen asks if the user wants to accept the frequency change of the RadioSondyGo to the APRS frequency. If accepted, APRS frequency is transmittes via the BLE command, while cancelling defers the change for a period of 5 minutes.

### Sonde Change Flow

When new telemetry arrives with a different sonde name, the app clears all old sonde data and seamlessly transitions to tracking the new sonde. This ensures each sonde's data remains isolated and prevents mixing of telemetry from different balloons.

#### Detection (BalloonPositionService.handlePositionUpdate)

Sequential steps when sonde name change is detected:

1. **Detect** sonde name change: `incomingName != currentBalloonName`
2. **Stash** the new telemetry packet (with new sonde name/data)
3. **Call** `coordinator.clearAllSondeData()` - wait for completion (clears ALL old sonde data)
4. **Update** `currentBalloonName = incomingName` (prevents infinite loop)
5. **Trigger** async APRS track fetch: `balloonTrackService.fillTrackGapsFromAPRS(sondeName: incomingName)` (fetches new sonde's APRS track with explicit sonde name)
6. **Process** stashed telemetry packet normally (publishes to all subscribers, adds first point to track)
7. **Continue** normal operation (state machine evaluates, services react to new telemetry)

#### Clearing (Coordinator.clearAllSondeData)

Sequential steps to clear all old sonde data:

1. **Call `clearAllData()` on each service:**
   - `balloonPositionService.clearAllData()` - clears currentBalloonName (enables next sonde detection)
   - `balloonTrackService.clearAllData()` - clears track arrays, descent history, filter windows, motion metrics; **cancels in-flight APRS fill task**
   - `landingPointTrackingService.clearAllData()` - clears landing history array
   - `predictionService.clearAllData()` - clears prediction data (including flight path array); **cancels in-flight prediction task**
   - `routeCalculationService.clearAllData()` - clears route data (including route polyline array); **cancels in-flight route calculation task**
   - `navigationService.clearAllData()` - clears last landing point reference

2. **Clear caches (async):**
   - `predictionCache.purgeAll()` - clears cached predictions
   - `routingCache.purgeAll()` - clears cached routes

3. **Return** to BalloonPositionService

**Architecture principle:** Each service encapsulates its own clearing logic via `clearAllData()`. Coordinator orchestrates but doesn't manipulate service internals.

**Async operation cancellation:** Services with long-running async operations (predictions, route calculations, APRS fetches) track their current task using Swift's structured concurrency. When `clearAllData()` is called, each service immediately cancels its in-flight task via `currentTask?.cancel()` without waiting for completion. The running task checks for cancellation at key points using `Task.checkCancellation()` and exits cleanly with `CancellationError`. This prevents stale results from old sondes being published after the sonde change completes. Cancellation is instantaneous - the coordinator doesn't wait for tasks to finish, they clean up asynchronously.

#### Key Principles

- **Transparent to other services** - Services see telemetry stop, then start again with new sonde name
- **State machine continues normally** - No special state transitions; evaluates based on current inputs
- **APRS fetch happens after clearing** - Loads APRS track for new sonde asynchronously
- **Stashing preserves first packet** - New sonde's triggering telemetry becomes its first data point
- **Service encapsulation** - Each service owns its clearing logic via `clearAllData()`
- **Coordinator orchestration** - Coordinator calls each service but doesn't manipulate internals
- **Separation of concerns**:
  - Each service's `clearAllData()` clears its own arrays, state, metrics
  - Coordinator clears shared caches (prediction, routing)
  - Persistence automatically overwrites old sonde data on next save (no explicit purge needed)
  - Critical: `balloonPositionService.clearAllData()` sets `currentBalloonName = nil` so new sonde can be detected

#### Persistence Data

The following data is persisted as simple JSON files (single-sonde snapshot model):
- **sondeName.json** - Current sonde name String (must match balloontrack.json)
- **balloontrack.json** - Current sonde's track points `[BalloonTrackPoint]` (must match sondeName.json)
- **landingPoints.json** - Current sonde's landing prediction history `[LandingPredictionPoint]`
- **userSettings.json** - User prediction parameters (not sonde-specific)

**Consistency:** sondeName.json and balloontrack.json are always updated together as a pair. When sonde changes, both files are overwritten with the new sonde's data. Previous sonde's data is preserved only in CSV logs (write-only, never loaded).

## Startup

The coordinator runs `performCompleteStartupSequence()` in 5 streamlined steps, waiting for definitive service answers before handing control to the state machine.

### Service Answer Detection
- **BLE Service Answer**: Connection state enum published after first packet is parsed (any state except `.scanning`)
- **APRS Service Answer**: Data received OR network error occurred
- **15-Second Safety Timeout**: If either service fails to answer, displays "💀 Something horrible happened"

### Startup Steps
1.  **Step 1: Load Persisted Data**
    *   Progress label: "Step 1: Loading Data"
    *   **Load from disk**: Read all 4 JSON files (userSettings.json, sondeName.json, balloontrack.json, landingPoints.json)
    *   **Validate consistency**: Verify sondeName.json matches balloontrack.json (same sonde)
    *   **Handle errors**: If corrupted or inconsistent, start with clean state
    *   **No injection yet**: Data loaded but not yet injected into services

2.  **Step 2: Service Initialization (0-100ms)**
    *   Progress label: "Step 2: Services"
    *   AppServices dependency injection and core service instantiation
    *   Initial property setup across all services
    *   **Services constructed with empty state** (no data loading in init)

3.  **Step 3: Inject Persisted Data**
    *   Progress label: "Step 3: Restoring State"
    *   **Inject persisted data**: Load validated data from Step 1 into services
    *   **Track loaded**: BalloonTrackService now has persisted track points
    *   **Landing history loaded**: LandingPointTrackingService has previous predictions
    *   **Critical**: Track MUST be populated before APRS starts (gap filling requires existing track)

4.  **Step 4: Service Startup + Answer Detection (100ms-~4s) [PARALLEL]**
    *   Progress label: "Step 4: BLE & APRS"
    *   **BLE Service**: Start scanning (if Bluetooth powered on)
    *   **APRS Service**: Start polling station data (gap filling now works on persisted track)
    *   **Frequency Management**: APRS radio data subscription established for startup frequency sync comparison
    *   **Wait for both definitive answers**:
        - BLE: Bluetooth off OR connection state enum published (after first packet)
        - APRS: Telemetry data received OR network error
    *   **Frequency Sync Detection**: Enhanced startup frequency sync compares APRS-BLE frequencies with comprehensive logging
    *   **No individual timeouts** - let each service handle its own timing
    *   **Coordinator timeout**: 15 seconds maximum (only if services don't answer)

5.  **Step 5: State Machine Handoff & UI Transition**
    *   Progress label: "Step 5: Startup Complete"
    *   **State Machine**: Call `balloonPositionService.completeStartup()`
    *   **Service answers available** - state machine can make informed decisions
    *   **Startup Complete**: Set `isStartupComplete = true`
    *   **UI Transition**: Hide logo, show tracking map
    *   **State Machine Control**: All timeout and source decisions now handled by state machine
    *   **Service Coordination**: 60-second prediction timer controlled by state machine state

### Key Improvements
- **Separated data loading from service construction**: Persisted data loaded in Step 1, services constructed clean in Step 2
- **No artificial timeouts**: Coordinator waits for actual service responses
- **Parallel service startup**: BLE and APRS start simultaneously
- **Immediate handoff**: Once both services answer, control goes to state machine
- **Fault tolerance**: Handles BLE disconnects, network failures, device unavailability, and corrupted persistence
- **Consistent ~4-second startup**: Fast persistence load (~50ms) + optimized service startup

## Tracking View

No calculations or business logic in views. Search for an appropriate service to place and publish them.

### Buttons Row

A row for Buttons is placed above the map. It is fixed and covers the entire width of the screen. It contains (in the sequence of appearance):

* Settings  

* Mode of transportation: The transport mode (car or bicycle) shall be used to calculate the route and the predicted arrival time. Every time the mode is changed, a new calculation has to be done. Use icons to save horizontal space.  
* Apple Maps navigation: Opens Apple Maps with the current landing point pre-filled. Car mode launches driving directions; bicycle mode launches cycling directions on iOS 14+ and falls back to walking on older systems.  

* **Settings Button**: Gear icon that opens device configuration interface and requests current device parameters via BLE.

* **Transport Mode Picker**: Segmented control with car/bicycle icons for selecting navigation mode (affects routing calculations and Apple Maps integration).

* **Point/All/Cancel Button**: Dynamic button functionality:
  - When **no landing point** exists: Shows "Point" button to enter manual landing point selection mode
  - In **point selection mode**: Shows "Cancel" button (red) to exit selection mode
  - When **landing point exists**: Shows "All" button to zoom map to show all annotations
  - **Point selection workflow**: Tap "Point" → tap on map → landing point is set automatically

* **Heading Mode Toggle**: Location icon button that toggles between camera positions:
  - **"Heading" mode**: Map centers on iPhone position and aligns to device heading (zoom-only interaction)
  - **"Free" mode**: Full pan and zoom interaction enabled
  - **Zoom preservation**: Zoom level maintained when switching between modes

* **Buzzer Mute Toggle**: Speaker icon button with haptic feedback that sends BLE mute command (o{mute=setMute}o). Icon reflects current mute state with immediate UI feedback. **Automatic state synchronization**: When BLE connects and sends Type 0/1/2 messages, the `buzmute` field automatically syncs the UI button state to match the actual device setting, ensuring the button always reflects the true device state at startup and during operation.

* **Apple Maps Button**: Navigation icon (only visible when landing point available) that opens Apple Maps with pre-configured directions using selected transport mode.

**Note**: Prediction path visibility toggle is not currently implemented - prediction paths are always shown when available during flight phases.


### Map

The map starts below the button row, and occupying approximately 70% of the vertical space.

### Map Overlays

No calculations or business logic in views. Search for an appropriate service to place and publish them.

The overlays must remain accurately positioned and correctly cropped within the displayed map area during all interactions. They should be updated independently and drawn as soon as available and when changed.

* User Position: The iPhone's current position is continuously displayed and updated on the map, represented by a runner.  
* Balloon Live Position: If Telemetry is available, the balloon's real-time position is displayed using a balloon marker(Balloon.fill). Its colour shall be green while ascending and red while descending.  
* Balloon Track: The map overlay shall show the current balloon track as a thin red line. At startup, persisted track (if any) is loaded from balloontrack.json. New telemetry points are appended to the array as they are received. The array is automatically cleared if a different sonde name is received (new sonde). It is updated when a new point is added to the track. The track should appear on the map when it is available.  
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
  * **BLE Icon (antenna)**: Shown in `liveBLEFlying` and `liveBLELanded` states. Green when data is fresh (< 3s), red when stale or in `waitingForAPRS`/`noTelemetry` states
  * **APRS Icon (globe)**: Shown in `aprsFlying` and `aprsLanded` states. Color reflects API status: green (connected), red (failed), yellow (in progress)
  * **Flash Animation**: Green flashing animation triggers only when telemetry data received (dataReady state), providing visual feedback for active telemetry reception
  * **iOS 17 Compatibility**: Fixed deprecated onChange method syntax for proper iOS 17 support
* Sonde Identification: Sonde type, number, and frequency.  
* Altitude: From telemetry in meters  
* Speeds (smoothened): Horizontal speed in km/h and vertical speed in m/s. Vertical speed: Green indicates ascending, and Red indicates descending.   
* Signal & Battery: Signal strength of the balloon and the battery status of RadioSondyGo in percentage.  
* Time Estimates: Predicted balloon landing time (from prediction service) and user arrival time (from routing service), both displayed in wall clock time for the current time zone. These times are updated with each new prediction or route calculation.  
* Remaining Balloon Flight Time: Time in hours:minutes from now to the predicted landing time.  
* Distance: The distance of the calculated route in kilometers (from route calculation). The distance is updated with each new route calculation.

* Landed: A “target” icon is shown when the balloon is landed

* Adjusted descend rate: Provided via `motionMetrics.adjustedDescentRateMS` from the balloon track service (auto-zeroed once the balloon is landed).
* Burst killer countdown: Shows the device's burst-killer timeout as a local clock time. The countdown value is received from the MySondyGo device via BLE. The `BalloonPositionService` processes this value, storing the countdown duration and the telemetry timestamp as a reference date in memory for the current session. During APRS fallback, the last known BLE burst killer value is retained. APRS updates, which do not contain burst killer information, never overwrite the cached value. Burst killer data is not persisted across app sessions.

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

The settings window is triggered by a button in the button bar. It enters the Sonde Settings window and, with a swipe down, saves the sonde settings (frequency and sonde type). If a mismatch with the current settings exists, transmits it to the device via BLE command ("o{f=frequency/tipo=probeType}o"),  and closes the window.  If no sonde is for command or transmitting telemetry, it displays a red warning text.

### Sonde Settings Window

When opened, this window displays the currently configured sonde type and frequency, allowing the user to change them. 

#### Keyboard-free interface: 

 \- **5 Independent Wheel Pickers**: Each digit of the frequency (XXX.XX MHz) has its own wheel picker

 \- **Large Font Display**: Each digit displays in 40pt bold font for clear visibility

 \- **Horizontal Layout**: The 5 pickers are arranged horizontally with "MHz" label at the end

 \- **Fixed Height**: Each picker has a 180pt height with clipped overflow

 \- **Restricted Range**: Only 400-406 MHz frequencies are allowed

 \- **Real-time Validation**: Invalid digits show in gray, valid ones in primary color

 \- **Cascading Adjustments**: When a digit changes, dependent positions auto-adjust

 \- **Reversion Protection**: Invalid selections automatically revert to previous valid value

**Navigation**: The main settings screen shows three buttons evenly distributed across the top toolbar: "Prediction Settings", "Device Settings", and "Tune". These provide access to the secondary settings views.

**Revert Button**: A "Revert" button is located below the frequency selector in the main content area as a full-width button. This button resets the values to the values present when the screen was entered.

#### Sonde types (enum)

1 RS41

2 M20

3 M10

4 PILOT

5 DFM

The human readable text (e.g. RS41) should be used in the display. However, the single number (e.g. 1\) has to be transferred in the command

### Secondary Settings Views

The following views are accessed from the top navigation bar of the main settings screen. Each is presented as a separate sub-view.

#### Prediction Settings
* **Purpose**: Allows the user to configure the parameters used for flight predictions.
* **Controls**: Provides fields for "Burst Altitude", "Ascent Rate", "Descent Rate", and "Station ID".
* **Navigation**: Accessed via "Prediction Settings" button in the top toolbar. Three buttons ("Prediction Settings", "Device Settings", "Tune") are arranged evenly across the toolbar using Spacer elements.
* **Saving**: This view has a "Done" button. When tapped or when the view disappears (via onDisappear), the values are saved to the UserSettings object via PersistenceService, and the user is returned to the main settings screen.

#### Tune View
* **Purpose**: Provides an interface for the AFC (Automatic Frequency Control) tune function.
* **Controls**: Displays the live AFC value, a "Transfer" button to copy the value, and an input field with a "Save" button to apply the new frequency correction.
* **Navigation**: Accessed via "Tune" button in the top toolbar, evenly spaced with other buttons. Has a "Done" button that returns the user to the main settings screen (selectedTab = 0).
* **Saving**: The "Save" button within the view is used to apply the tune value immediately to the device. Device settings are not persisted (stored in MySondyGo device).

#### Device Settings

**Access**: Triggered by the "Device Settings" button in the main settings toolbar.

**Startup**: The device settings have to be read from RadioSondyGo via BLE command and the cache has to be updated

**Layout**: Opens a new sheet with four tabs: "Pins", "Battery", "Radio", and "Other" 

**Done**: "Done" button  saves the changed settings to RadioSondyGo via BLE and returns to main settings.


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

  0: Linear  
  1: Sigmoidal  
  2: Asigmoidal


#### Radio Tab

* myCall (callSign)  

* rs41.rxbw (RS41Bandwidth)  

* m20.rxbw (M20Bandwidth)  

* m10.rxbw (M10Bandwidth)  

* pilot.rxbw (PILOTBandwidth)  

* dfm.rxbw (DFMBandwidth)


#### Others Tab

* lcdOn (lcdStatus)  

* blu (bluetoothStatus)  

* baud (serialSpeed)  

* com (serialPort)  

* aprsName (aprsName / nameType)


#### Prediction View

(These values are stored permanently on the iPhone via PersistenceService and are never transmitted to the device)

* burstAltitude  
* ascentRate  
* descentRate
* Station ID (shown in a different block)

The values are saved when the Done button is pressed


### Tune Function

The "TUNE" function in MySondyGo is a calibration process designed to compensate for frequency shifts of the receiver. These shifts can be several kilohertz (KHz) and impact reception quality. The tune view shows a smoothened (20)  AFC value (freqofs). If we press the “Transfer” button (which is located right to the live updated field), the actual average value is copied to the input field. A “Save” button placed right to the input field stores the actual value of the input field is stored using the setFreqCorrection command. The view stays open to check the effect.

## Debugging

Debugging should be according the services. It should contain

* From where the trigger came (one line)  
* What was executed (one line)   
* What was delivered (one line per structure)

# Appendix: 

## Messages from RadioSondyGo

**MySondyGo BLE Protocol Implementation Details:**

The app implements a robust BLE communication system with comprehensive message validation and error handling:

**Message Parsing Strategy:**
- All messages use forward-slash (/) delimited format
- Message validation includes field count verification and type checking
- Plausibility checks prevent invalid data from corrupting the system
- Failed parsing attempts are logged with raw field data for debugging

**Validation Rules:**
- **Coordinates**: Latitude [-90, 90], Longitude [-180, 180]
- **Altitude**: Reasonable range checks for balloon telemetry
- **Speeds**: Horizontal ≤ 150 m/s, Vertical ≤ 100 m/s
- **Battery**: Percentage [0, 100], Voltage [2500, 5000] mV
- **Signal**: RSSI typically negative dBm values

**Command Protocol:**
```
Frequency Change: o{f=403.50/tipo=1}o
Device Configuration: o{conf}o
Mute Control: o{mute=1}o
```

**Error Handling:**
- Parse failures log ⚠️ warnings with field details
- Invalid coordinates (0,0) are automatically discarded
- Missing or malformed fields trigger graceful degradation
- Connection timeouts use 5-second limits per startup requirements

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

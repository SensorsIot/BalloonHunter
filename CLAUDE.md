# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

This is an iOS app is built with Xcode outside of Claude. No separate linting or testing commands are configured.

## Architecture Overview

BalloonHunter is a SwiftUI-based iOS app for tracking weather balloons via BLE communication. The app uses a **simplified direct architecture** with ServiceCoordinator as the single source of truth.

### Simplified Direct Architecture

The app follows a clean direct communication pattern:
**UI** → **ServiceCoordinator** ← **Services**

**Core Components:**

1. **ServiceCoordinator** - Single source of truth and service coordinator:
   - Holds ALL application state via @Published properties
   - Manages all service instances and their dependencies
   - Provides direct communication hub between services and UI
   - Eliminates complex event systems and separate state layers
   - Services observe and update ServiceCoordinator directly

2. **Services** - Pure business logic with direct ServiceCoordinator communication:
   - `BLECommunicationService` - Bluetooth communication with @Published telemetry
   - `CurrentLocationService` - Location/heading tracking updates
   - `PredictionService` - API calls for balloon trajectory predictions
   - `RouteCalculationService` - Route calculations using Apple Maps
   - `BalloonPositionService` - Processes real-time telemetry data
   - `BalloonTrackService` - Track history and landing detection
   - `PersistenceService` - UserDefaults-based data storage

3. **BalloonTrackPredictionService** - Independent prediction coordinator:
   - Observes telemetry changes in ServiceCoordinator
   - Handles prediction timing logic (60-second intervals, startup, manual triggers)
   - Updates ServiceCoordinator directly with prediction results
   - Manages prediction caching and effective descent rate calculation

4. **UI (Observer Only)** - Pure SwiftUI reactive rendering:
   - `TrackingMapView` observes ServiceCoordinator @Published properties
   - `DataPanelView` displays real-time data from ServiceCoordinator
   - User interactions call ServiceCoordinator methods directly
   - No business logic in UI - purely reactive presentation layer

5. **AppServices** - Dependency injection container:
   - Creates and manages service instances
   - Provides clean service initialization and lifecycle
   - Services injected into ServiceCoordinator for coordination

### Key Eliminated Components

**Removed over-engineered layers:**
- ❌ **EventBus** - Complex event system eliminated for direct communication
- ❌ **MapState** - Separate state layer eliminated, merged into ServiceCoordinator
- ❌ **Policy classes** - Business logic moved directly into services
- ❌ **LandingPointService** - Over-engineered wrapper eliminated, logic moved to ServiceCoordinator
- ❌ **Complex event flow** - Direct method calls and property observation

### Data Models

Key data structures defined in `AppModels.swift`:
- `TelemetryData` - Real-time balloon telemetry from BLE
- `BalloonTrackPoint` - Serializable track point for persistence
- `PredictionData` - API response data with flight path predictions
- `RouteData` - Apple Maps route information
- `MapAnnotationItem` - Map annotation with dynamic views

### ServiceCoordinator State Properties

ServiceCoordinator holds ALL application state:

**Map Visual Elements:**
- `annotations: [MapAnnotationItem]` - All map annotations
- `balloonTrackPath: MKPolyline?` - Historical balloon track
- `predictionPath: MKPolyline?` - Predicted flight path
- `userRoute: MKPolyline?` - Navigation route to landing point
- `region: MKCoordinateRegion?` - Map camera region

**Core Data State:**
- `balloonTelemetry: TelemetryData?` - Current balloon data
- `userLocation: LocationData?` - Current user position
- `landingPoint: CLLocationCoordinate2D?` - Predicted/actual landing point
- `burstPoint: CLLocationCoordinate2D?` - Balloon burst point

**UI State:**
- `transportMode: TransportationMode` - Car/bicycle routing mode
- `isHeadingMode: Bool` - Map follows user heading
- `isPredictionPathVisible: Bool` - Show/hide prediction overlay
- `isBuzzerMuted: Bool` - Device buzzer state

### Advanced Features

**Caching System** - High-performance caching:
- **PredictionCache** - TTL/LRU eviction, spatial key quantization
- **RoutingCache** - User location and destination bucketing
- **Automatic cache management** - Services handle cache lifecycle

**BLE Communication** - Robust MySondyGo device integration:
- **Comprehensive debugging** - Detailed logging at every BLE step
- **Automatic reconnection** - Handles device disconnections gracefully
- **Protocol parsing** - Support for telemetry, status, and settings messages

**Direct State Updates** - Simplified data flow:
- Services update ServiceCoordinator properties directly
- SwiftUI automatically re-renders on @Published changes
- No complex event processing or state synchronization

### Key Design Patterns

1. **Direct communication**: Services call ServiceCoordinator methods directly
2. **Single source of truth**: ServiceCoordinator holds ALL state
3. **Property observation**: UI observes ServiceCoordinator @Published properties
4. **Dependency injection**: AppServices manages service lifecycle
5. **Reactive UI**: SwiftUI automatically updates on state changes
6. **Service autonomy**: Each service has clear, focused responsibilities
7. **MainActor isolation**: All UI updates guaranteed on main thread

## Development Guidelines

### From BalloonHunterApp.swift Comments

The main app file contains comprehensive AI assistant guidelines:

- **Follow the FSD**: The Functional Specification Document is the source of truth
- **Modern Swift**: Use async/await, SwiftData, SwiftUI property wrappers
- **Apple-native tools**: Prefer built-in frameworks over third-party dependencies
- **Clear separation**: Keep views, models, and services properly separated
- **Minimal comments**: Only for non-obvious logic, TODOs, or FIXMEs

### Simplified Architecture Development Guidelines

**ServiceCoordinator (Central Hub):**
- ServiceCoordinator MUST hold ALL application state via @Published properties
- ServiceCoordinator MUST provide direct methods for service updates
- ServiceCoordinator MUST coordinate between services when needed
- ServiceCoordinator SHOULD consolidate related state updates atomically
- ServiceCoordinator MUST NOT contain complex business logic (delegate to services)

**Services (Pure Business Logic):**
- Services MUST have clear, single responsibilities
- Services MUST update ServiceCoordinator directly via method calls
- Services MUST expose their state via @Published properties when needed
- Services MUST NOT communicate with each other directly (use ServiceCoordinator)
- Services SHOULD use dependency injection rather than singletons
- Services MUST use @MainActor isolation for UI-related operations

**UI (Pure Reactive Rendering):**
- UI MUST only observe ServiceCoordinator @Published properties
- UI MUST call ServiceCoordinator methods directly for user interactions  
- UI MUST NOT contain any business logic or state management
- UI SHOULD use SwiftUI's reactive system for all updates

**General Rules:**
- NO event systems - use direct method calls and property observation
- NO separate state layers - ServiceCoordinator holds everything
- NO over-engineered abstractions - prefer simple, direct patterns
- USE dependency injection through AppServices
- MAINTAIN clean service boundaries and single responsibilities
- PREFER simplicity over complex architectural patterns

### BLE Communication Protocol

The app communicates with MySondyGo devices using a custom protocol:
- Message types: 0 (status), 1 (telemetry), 2 (minimal), 3 (settings)
- All messages are forward-slash delimited strings
- Device settings are bidirectional (read/write)
- Telemetry data includes position, speed, signal strength, and device status

### Data Persistence Strategy

Uses UserDefaults for all persistence:
- User prediction settings (burst altitude, ascent/descent rates)
- Balloon track history (keyed by sonde name)  
- Landing points (keyed by sonde name)
- Device settings from BLE configuration

### Data Flow Examples

**Telemetry Update Flow:**
1. MySondyGo device → BLECommunicationService receives BLE data
2. BLECommunicationService publishes via @Published latestTelemetry
3. BalloonTrackPredictionService observes telemetry changes
4. BalloonTrackPredictionService calls ServiceCoordinator.updatePrediction() directly
5. ServiceCoordinator updates predictionPath and other state properties
6. TrackingMapView observes ServiceCoordinator @Published properties and re-renders

**User Interaction Flow:**
1. User taps balloon annotation in TrackingMapView
2. TrackingMapView calls serviceCoordinator.triggerManualPrediction() directly  
3. ServiceCoordinator calls balloonTrackPredictionService.triggerManualPrediction()
4. BalloonTrackPredictionService performs prediction and updates ServiceCoordinator
5. TrackingMapView observes ServiceCoordinator state changes and updates UI

**Service Coordination Flow:**
1. BLECommunicationService receives telemetry and updates @Published latestTelemetry
2. BalloonPositionService observes telemetry and processes position data
3. BalloonTrackService observes telemetry and manages track history
4. BalloonTrackService determines landing and calls ServiceCoordinator.setLandingPoint()
5. ServiceCoordinator updates landingPoint property
6. UI observes landingPoint change and displays landing annotation

**Route Calculation Flow:**
1. ServiceCoordinator detects new landing point and user location
2. ServiceCoordinator calls RouteCalculationService.calculateRoute() directly
3. RouteCalculationService returns route data
4. ServiceCoordinator updates userRoute property
5. TrackingMapView observes userRoute change and displays navigation overlay

## Service Functions and Triggers (FSD Reference)

### Core Services and Functions

**Bluetooth Communication Service**
- Function: Manages wireless communication with the balloon tracking device
- Triggers: Automatic connection attempts when devices are discovered, incoming data packets from the balloon device, user commands sent to configure device settings, connection status changes (connect/disconnect events)

**Location Tracking Service**
- Function: Monitors the user's geographic position and movement
- Triggers: Significant location changes (movement threshold exceeded), heading/compass direction changes, location accuracy improvements, system location permission changes

**Balloon Position Service**
- Function: Processes and interprets real-time balloon telemetry data
- Triggers: New telemetry data received from bluetooth communication, data validation and filtering requirements, signal strength and quality assessments

**Track Management Service**
- Function: Maintains historical balloon flight path data
- Triggers: New position data points received, track persistence requirements (save/load operations), track analysis requests (distance, altitude, speed calculations)

**Prediction Service**
- Function: Calculates future balloon flight paths using atmospheric models
- Triggers: BalloonTrackPredictionService requests based on timing intervals, significant balloon movement or altitude changes, user manual prediction requests

**Route Calculation Service**  
- Function: Determines optimal travel paths to predicted landing locations
- Triggers: ServiceCoordinator requests when new landing points are available, user location changes beyond distance thresholds, transportation method changes (car vs bicycle)

**Data Persistence Service**
- Function: Stores and retrieves application data and user preferences
- Triggers: Application lifecycle events (startup, shutdown, background), configuration changes requiring permanent storage, track data updates for historical preservation, user settings modifications

### Prediction Triggers (BalloonTrackPredictionService)

**Time-Based Triggers:**
- 60-second interval predictions during active tracking
- Startup prediction after first valid telemetry received
- Manual prediction requests from user balloon taps

**State-Change Triggers:**
- Significant movement or altitude changes (threshold-based)
- Device connection/disconnection events
- Application lifecycle state changes

**Adaptive Behavior:**
- Effective descent rate calculation below 10000m altitude
- Burst altitude logic (current + 10m for descent, settings value for ascent)
- Cache-based deduplication to prevent redundant API calls

# important-instruction-reminders
Do what has been asked; nothing more, nothing less.
NEVER create files unless they're absolutely necessary for achieving your goal.
ALWAYS prefer editing an existing file to creating a new one.
NEVER proactively create documentation files (*.md) or README files. Only create documentation files if explicitly requested by the User.
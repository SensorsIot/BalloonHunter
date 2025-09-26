# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

BalloonHunter is an iOS weather balloon tracking app built in SwiftUI that connects to MySondyGo devices via Bluetooth Low Energy to track balloon sondes in real-time. The app provides prediction, routing, and mapping functionality for balloon recovery.

## Development Commands

### Build and Run
- **Build**: `xcodebuild -project BalloonHunter.xcodeproj -scheme BalloonHunter -destination 'platform=iOS Simulator,name=iPhone 15' build`
- **Run in Simulator**: Open `BalloonHunter.xcodeproj` in Xcode and run on iOS Simulator
- **Archive for App Store**: `xcodebuild -project BalloonHunter.xcodeproj -scheme BalloonHunter -archivePath build/BalloonHunter.xcarchive archive`

### Testing
- **Run Tests**: `xcodebuild -project BalloonHunter.xcodeproj -scheme BalloonHunter -destination 'platform=iOS Simulator,name=iPhone 15' test`
- **Test on Device**: Tests require physical iOS device due to Bluetooth and location dependencies

### Code Validation
- **Swift Syntax Check**: `swift -syntax-test BalloonHunter/*.swift`
- **Build Warnings Check**: Monitor build output for warnings and deprecations

## Architecture Overview

### High-Level Architecture
The app follows a modular service-coordinator architecture with clean separation of responsibilities:

```
Services (Domain Logic) ← ServiceCoordinator (Orchestrator) → Views (Presentation)
     ↓                           ↓                         ↓
BLEService, PredictionService → Published Properties → TrackingMapView, DataPanelView
```

#### Architecture Principles (from FSD)
- **Separation of Concerns**: Business logic lives in services and coordinator; SwiftUI views remain declarative consumers of published state
- **Coordinator as Orchestrator**: ServiceCoordinator listens to service publishers, applies cross-cutting rules, and republishes merged state
- **Modular Services**: Each domain (location, tracking, prediction, persistence) lives in separate files with co-located caches
- **Combine-Driven Data Flow**: Services publish via `@Published`; coordinator/presenter subscribe, transform, and re-publish
- **Environment-Driven UI**: Views observe coordinator/presenter/settings through `@EnvironmentObject`; actions bubble up through intent methods
- **Presenter Layer**: MapPresenter handles complex map-specific transformations, keeping views as pure SwiftUI layout

### Key Components

#### Core Services (Modular Design)
- **BLECommunicationService** (BLEService.swift): BLE discovery, connection, packet parsing for MySondyGo devices
- **CurrentLocationService** (LocationServices.swift): GPS tracking, distance calculations, proximity detection
- **BalloonPositionService** (BalloonTrackingServices.swift): Telemetry state machine with 7 states (startup, liveBLE, APRS fallback, etc.)
- **BalloonTrackService** (BalloonTrackingServices.swift): Track smoothing, motion metrics, landing detection
- **PredictionService** (PredictionService.swift): Tawhiri API integration with caching (co-located PredictionCache)
- **RouteCalculationService** (RoutingServices.swift): Apple Maps integration with RoutingCache
- **PersistenceService** (PersistenceService.swift): Core Data persistence, document directory management

#### Service Coordination
- **ServiceCoordinator** (ServiceCoordinator.swift): Orchestrates services, manages startup sequence, publishes merged app state
- **MapPresenter** (MapPresenter.swift): Map-specific state transformations, overlay generation, user intent handling
- **AppServices** (AppServices.swift): Dependency injection container for service initialization
- **UserSettings** (Settings.swift): User preferences (ascent/descent rates, burst altitude, transport mode)

#### Data Models (CoreModels.swift)
- **TelemetryData**: Balloon position, altitude, speeds, sensor data, timestamps
- **PredictionData**: Trajectory paths, burst/landing points, flight time calculations
- **RouteData**: Navigation routes with coordinates, distance, travel time
- **BalloonTrackPoint**: Historical track data with motion metrics
- **DeviceSettings**: MySondyGo device configuration and status

#### Telemetry State Machine
BalloonPositionService implements a formal 7-state machine for telemetry source management:
- **startup** → **liveBLEFlying** → **liveBLELanded** (primary BLE path)
- **waitingForAPRS** → **aprsFallbackFlying** → **aprsFallbackLanded** (fallback path)
- **noTelemetry** (when both sources unavailable)
- 30-second debouncing prevents oscillation between BLE/APRS sources

### Key Views
- **BalloonHunterApp**: Main app entry point with service initialization
- **TrackingMapView**: Primary map interface (70% of screen) with balloon tracking
- **DataPanelView**: Lower panel (30% of screen) showing telemetry data in two tables
- **SettingsView**: Configuration interface for user parameters
- **StartupView**: Initial loading screen with logo and service initialization

## Development Guidelines

### Service Integration Pattern
**PREFER DIRECT COMMUNICATION**: Use ServiceCoordinator only when it adds clear architectural value.

#### Direct Service-to-View Communication (Preferred)
For simple data flows, connect services directly to views:
1. Create service in `Services.swift` with `@Published` properties
2. Inject service into views via `@EnvironmentObject`
3. Views observe service state directly
4. Use when: Single service owns the data, no cross-service coordination needed

#### ServiceCoordinator Communication (Use Sparingly)
Only use ServiceCoordinator when it provides clear value:
1. Cross-service coordination (e.g., startup sequences)
2. Complex state combining multiple services
3. Operations requiring multiple services working together
4. Application-wide state management

**AVOID**: Using ServiceCoordinator as a simple data passthrough for single-service decisions

### Separation of Concerns Architecture
**CRITICAL PRINCIPLE**: True separation of concerns with views handling only presentation logic and services managing all business operations.

#### Data Flow Requirements
- Services publish data changes via Combine `@Published` properties
- **Direct Flow**: Views can observe services directly for simple single-service data
- **Coordinated Flow**: ServiceCoordinator consolidates state only when cross-service coordination is needed
- Choose the simplest pattern that meets the architectural requirements

#### View Layer Responsibilities (Presentation Only)
- Display UI elements and handle user interactions
- Observe and react to service state changes (directly or via ServiceCoordinator)
- NO business logic, calculations, data processing, or service calls
- NO timer management, data validation, or persistence operations
- Use @EnvironmentObject to access service or ServiceCoordinator state as appropriate

#### Service Layer Responsibilities (Business Logic)
- All data processing, calculations, and business rules
- API calls, BLE communication, and external service interactions
- Data validation, transformation, and persistence operations
- Timer management and background task coordination
- Direct service-to-service communication when possible, ServiceCoordinator when needed

#### ServiceCoordinator Responsibilities (Coordination Only)
- Manages service lifecycle and startup sequences
- Coordinates complex operations requiring multiple services
- Consolidates state only when combining multiple services adds value
- **NOT a data passthrough**: Avoid storing single-service decisions
- Focus on true coordination, not simple state forwarding

### BLE Communication
- MySondyGo devices communicate via custom BLE protocol with 4 message types (0-3)
- Type 1 messages contain telemetry data for balloon tracking
- BLE service handles scanning, connection, and message parsing automatically
- Connection timeout is 5 seconds per startup requirements

### Startup Sequence (Critical Implementation Detail)
**IMPORTANT**: ServiceCoordinator controls the entire startup sequence. StartupView only handles presentation.

The app follows a specific 7-step startup sequence managed by `ServiceCoordinator.performCompleteStartupSequence()`:
1. **Initial Map**: Location service activation with 25km zoom, show tracking map
2. **Connect Device**: BLE connection attempt (5-second timeout)
3. **Publish Telemetry**: Wait for first BLE package and telemetry status
4. **Read Settings**: Issue settings command to MySondyGo device
5. **Read Persistence**: Load persistence data (tracks, landing points, parameters)  
6. **Landing Point Determination**: Determine landing point using 4-priority system
7. **Final Map Display**: Display initial map with all annotations at maximum zoom

StartupView responsibilities limited to:
- Display logo and progress updates from ServiceCoordinator state
- Show TrackingMapView when ServiceCoordinator sets `showTrackingMap = true`
- Trigger startup sequence via `serviceCoordinator.performCompleteStartupSequence()`

### Landing Point Priority System
Landing points are determined using this priority order:
1. **Priority 1**: Current balloon position if landed (verticalSpeed ≥ -0.5, altitude < 500m)
2. **Priority 2**: Predicted landing position if balloon in flight
3. **Priority 3**: Parse coordinates from clipboard (OpenStreetMap URLs)
4. **Priority 4**: Use persisted landing point from previous session

### Prediction System
- Uses Tawhiri API (predict.sondehub.org) for trajectory calculations
- Automatic predictions every 60 seconds when telemetry available
- Manual predictions triggered via button press
- Results cached with coordinate/time-based keys
- Effective descent rate: smoothed calculation below 10000m, user settings above

### Map Display Requirements
- **70% vertical space** for map, **30% for data panel**
- Button row fixed at bottom of map area
- Color coding: Green (ascending), Red (descending), Blue (prediction path)
- Icons: `balloon.fill` for balloon, `figure.run` for user, specific pins for markers
- Route hidden when balloon within 100m of user position

### Zoom Level Management
The app implements a zoom preservation system between heading and free modes:
- **Startup Zoom**: 25km (0.225° span) for initial overview
- **Mode Switching**: Preserves user's zoom level when toggling between heading/free modes
- **User Control**: Users can zoom in/out in both modes (zoom is not locked)
- **Debugging**: Comprehensive 🔍 ZOOM logs track all zoom operations
- **State Management**: `savedZoomLevel` variable maintains zoom across mode switches
- **Conditional Display**: `triggerShowAllAnnotations` only called when landing point is available

#### Known Zoom Issues (To Be Addressed)
- **Heading Mode Zoom**: Currently has limitations due to `.userLocation(followsHeading: true)` forcing zoom behavior
- **Inconsistent Behavior**: Zoom may reset unexpectedly when switching to heading mode
- **Planned Improvement**: Migrate to professional compass architecture using MKMapCamera and CLLocationDistance

### Testing Considerations
- Requires iOS device for full BLE functionality
- Location services need actual GPS or simulator location
- Prediction API requires network connectivity
- Use mock data for automated testing scenarios

## Important Notes

### Current Development Status
The project has undergone significant architectural simplification, removing complex EventBus and Policy systems in favor of direct service coordination. Recent changes focused on:
- Simplified ServiceCoordinator with direct subscriptions
- Consolidated service layer in Services.swift
- Startup sequence implementation per requirements
- Data panel refactoring to use ServiceCoordinator state
- **StartupView refactored**: Moved all business logic to ServiceCoordinator, now handles only presentation
- **DataPanelView refactored**: Removed all calculations and business logic, now only displays pre-formatted strings
- **Descent rate logic**: Always calculated and displayed regardless of altitude; API usage decision moved to PredictionService
- **BLE Communication**: Fixed isReadyForCommands to trigger on first valid BLE packet (any type)
- **Zoom Level System**: Implemented zoom preservation between heading/free modes with comprehensive debugging
- **Map Display Logic**: Added conditional triggerShowAllAnnotations based on landing point availability

### Known Architecture Improvements Needed
The codebase currently has some separation of concerns violations that require refactoring:

#### High Priority Refactoring Required
- **SettingsView**: Contains BLE command generation, device configuration, and data format conversion
- **TrackingMapView**: Makes direct service calls instead of using ServiceCoordinator methods
- **Map Zoom System**: Current approach fights against MapKit; needs professional compass architecture

#### Services to Extract
Based on analysis, these new services should be created:
- **DeviceConfigurationService**: Manage BLE commands and device settings
- **MapStateService**: Handle map positioning and region management with proper MKMapCamera control
- **CompassService**: Professional compass integration with Core Location heading updates
- **SettingsService**: Unified settings persistence and management

#### Architectural Patterns to Implement
- **Command Pattern**: For user actions (mute, prediction, settings changes)
- **Strategy Pattern**: For different calculation algorithms
- **Enhanced Observer Pattern**: For improved view-service communication
- **Professional Compass Architecture**: MKMapCamera-based system with CLLocationDistance zoom preservation

### Planned Compass Architecture Improvements
The current zoom system will be replaced with a professional compass architecture:

#### State Management
- `mode: .free | .heading` - Explicit mode tracking
- `currentDistance: CLLocationDistance` - Proper zoom preservation using MapKit's distance units
- `userCoord: CLLocationCoordinate2D` - User position tracking
- `displayHeading: CLLocationDirection` - Processed compass heading
- `headingQualityOK: Bool` - Compass accuracy validation

#### Compass Integration
- Core Location `startUpdatingHeading()` with proper filtering
- Quality controls: `headingAccuracy` validation, ignore poor readings
- Smoothing: Circular low-pass filter with throttling to 10-20Hz
- Fallback: Use `CLLocation.course` when speed ≥ 2-3 m/s for poor compass

#### MapKit Implementation
- **Free Mode**: `isScrollEnabled = true`, `isZoomEnabled = true`, heading = 0° (north-up)
- **Heading Mode**: `isScrollEnabled = false`, `isZoomEnabled = true`, compass-aligned
- **Camera Control**: `MKMapCamera` with preserved `currentDistance` for seamless zoom
- **Zoom Tracking**: `regionDidChangeAnimated` to update `currentDistance` on pinch gestures

### Critical Implementation Details
- All services must be initialized through AppServices factory
- ServiceCoordinator manages all cross-service communication
- Views should never directly access services (use ServiceCoordinator only)
- Startup sequence timing is critical for proper initialization
- BLE service runs non-blocking background process
- Prediction caching essential for performance with API limits

### iOS Specific Requirements
- Minimum iOS 17.6 deployment target
- Requires Bluetooth and Location permissions
- App Sandbox enabled for App Store distribution
- Development team ID: 2REN69VTQ3
- Bundle ID: HB9BLA.BalloonHunter
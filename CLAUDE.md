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
The app follows a simplified service-coordinator pattern with direct subscriptions replacing the previous complex EventBus architecture:

```
Services (Data Sources) → ServiceCoordinator (Coordinator) → Views (SwiftUI)
     ↓                           ↓                         ↓
BLEService, LocationService → Published Properties → TrackingMapView, DataPanelView
```

### Key Components

#### Core Services (in Services.swift)
- **BLECommunicationService**: Manages Bluetooth connectivity to MySondyGo devices
- **CurrentLocationService**: Handles user location tracking with CoreLocation
- **PredictionService**: Calculates balloon trajectory and landing predictions using Tawhiri API
- **RouteCalculationService**: Generates navigation routes using Apple Maps
- **PersistenceService**: Manages Core Data storage for tracks, settings, and landing points

#### Service Coordination
- **ServiceCoordinator**: Central coordinator that manages service interactions and publishes combined state
- **AppServices**: Factory class that initializes and provides service instances
- **UserSettings**: ObservableObject for user preferences (ascent/descent rates, burst altitude)

#### Data Models
- **TelemetryData**: Contains balloon position, altitude, speeds, and sensor data
- **PredictionData**: Trajectory prediction results including landing point and burst point
- **RouteData**: Navigation route with coordinates, distance, and travel time
- **LocationData**: User position data from GPS

#### Caching System
- **PredictionCache**: Caches prediction results to reduce API calls
- **RoutingCache**: Caches route calculations for performance

### Key Views
- **BalloonHunterApp**: Main app entry point with service initialization
- **TrackingMapView**: Primary map interface (70% of screen) with balloon tracking
- **DataPanelView**: Lower panel (30% of screen) showing telemetry data in two tables
- **SettingsView**: Configuration interface for user parameters
- **StartupView**: Initial loading screen with logo and service initialization

## Development Guidelines

### Service Integration Pattern
When adding new functionality, follow the established service pattern:
1. Create service in `Services.swift` with `@Published` properties
2. Inject service into `ServiceCoordinator` via `AppServices`
3. Subscribe to service updates in `ServiceCoordinator.setupDirectSubscriptions()`
4. Update published state in ServiceCoordinator
5. Bind to state in SwiftUI views via `@EnvironmentObject`

### Separation of Concerns Architecture
**CRITICAL PRINCIPLE**: True separation of concerns with views handling only presentation logic and services managing all business operations.

#### Data Flow Requirements
- Services publish data changes via Combine `@Published` properties
- ServiceCoordinator subscribes to service changes and consolidates state
- Views observe ServiceCoordinator state only (no direct service access)
- All UI updates must go through ServiceCoordinator published properties

#### View Layer Responsibilities (Presentation Only)
- Display UI elements and handle user interactions
- Observe and react to ServiceCoordinator state changes
- NO business logic, calculations, data processing, or service calls
- NO timer management, data validation, or persistence operations
- Use @EnvironmentObject to access ServiceCoordinator state only

#### Service Layer Responsibilities (Business Logic)
- All data processing, calculations, and business rules
- API calls, BLE communication, and external service interactions
- Data validation, transformation, and persistence operations
- Timer management and background task coordination
- Cross-service communication through ServiceCoordinator

#### ServiceCoordinator Responsibilities (Coordination)
- Manages all service interactions and lifecycle
- Controls startup sequence and application flow
- Consolidates and publishes combined state for views
- Handles complex operations requiring multiple services
- Exposes high-level methods to reduce view complexity

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

### Known Architecture Improvements Needed
The codebase currently has some separation of concerns violations that require refactoring:

#### High Priority Refactoring Required
- **DataPanelView**: Contains business logic for data smoothing, time calculations, and staleness detection
- **SettingsView**: Contains BLE command generation, device configuration, and data format conversion
- **TrackingMapView**: Makes direct service calls instead of using ServiceCoordinator methods

#### Services to Extract
Based on analysis, these new services should be created:
- **DataProcessingService**: Handle all calculations and data transformations
- **DeviceConfigurationService**: Manage BLE commands and device settings
- **TelemetryValidationService**: Handle data validation and staleness detection
- **FlightTimeService**: Manage time-based calculations and predictions
- **MapStateService**: Handle map positioning and region management
- **SettingsService**: Unified settings persistence and management

#### Architectural Patterns to Implement
- **Command Pattern**: For user actions (mute, prediction, settings changes)
- **Strategy Pattern**: For different calculation algorithms
- **Enhanced Observer Pattern**: For improved view-service communication

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
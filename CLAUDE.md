# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

This is an iOS app is built with Xcode outside of Claude. No separate linting or testing commands are configured.

## Architecture Overview

BalloonHunter is a SwiftUI-based iOS app for tracking weather balloons via BLE communication. The app uses an **event-driven architecture** with strict separation of concerns and policy-based orchestration.

### Event-Driven Architecture (Revised)

The app follows a clean event-driven pattern:
**Services** → (typed events) → **Policies** → **MapState** → **UI**

**Core Components:**

1. **EventBus** - Central event publishing system with typed events:
   - `TelemetryEvent` - Real-time balloon data from BLE
   - `UserLocationEvent` - iPhone location and heading updates
   - `UIEvent` - User interactions (taps, mode switches, etc.)
   - `MapStateUpdate` - Atomic map state changes from policies
   - `ServiceHealthEvent` - Service health monitoring

2. **Services (Pure Event Producers)** - No UI knowledge, no cross-service dependencies:
   - `BLECommunicationService` - Bluetooth communication, publishes TelemetryEvents
   - `CurrentLocationService` - Location/heading tracking, publishes UserLocationEvents
   - `PredictionService` - API calls (called by policies, not autonomous)
   - `RouteCalculationService` - Route calculations (called by policies)
   - `BalloonTrackingService` - Telemetry processing and track management
   - `LandingPointService` - Landing point determination
   - `PersistenceService` - UserDefaults-based data storage

3. **Policies (Decision Logic & Side Effects)** - Subscribe to events, emit MapState updates:
   - `PredictionPolicy` - Intelligent prediction triggering with caching and backoff
   - `RoutingPolicy` - Route calculation with distance thresholds and caching
   - `CameraPolicy` - Map camera control with debouncing
   - All policies use `PolicyScheduler` for consistent timing behavior

4. **MapState (Single Source of Truth)** - Atomic state updates with versioning:
   - Receives `MapStateUpdate` events from policies
   - Version conflict resolution prevents UI regressions
   - Contains annotations, overlays, region, camera updates, and UI state

5. **UI (Pure Consumer)** - Only observes MapState, publishes UIEvents:
   - `TrackingMapView` observes MapState for all map rendering
   - User interactions publish UIEvents to EventBus
   - No direct service coupling or business logic

### Data Models

Key data structures defined in `AppModels.swift`:
- `TelemetryData` - Real-time balloon telemetry from BLE
- `BalloonTrackPoint` - Serializable track point for persistence
- `PredictionData` - API response data with flight path predictions
- `RouteData` - Apple Maps route information
- `MapAnnotationItem` - Map annotation with dynamic views

### Advanced Features

**PolicyScheduler** - Sophisticated timing control for all policies:
- **Debouncing** - Prevent rapid-fire triggers
- **Throttling** - Rate limiting with leading/trailing options
- **Cooldowns** - Minimum time between executions
- **Exponential Backoff** - Progressive delays for failing operations
- **Coalescing** - Latest-wins for high-frequency updates
- **Latest-wins Cancellation** - Cancel pending operations when new ones arrive

**Caching System** - High-performance caching with comprehensive metrics:
- **PredictionCache** - TTL/LRU eviction, spatial/temporal key quantization
- **RoutingCache** - User location and balloon position bucketing
- **Versioning** - Prevents stale data from overriding fresh results
- **Metrics** - Hit rates, evictions, access patterns, cache performance

**Mode State Machine** - Three-mode adaptive behavior:
- **Explore Mode** - Light fetching, routing disabled, 5-minute prediction intervals
- **Follow Mode** - Active tracking, routing enabled, 2-minute intervals
- **Final Approach Mode** - High-frequency updates (30s), landing detection
- **Automatic Transitions** - Based on telemetry, signal strength, altitude, proximity
- **Hysteresis** - Prevents mode flapping with time-based delays

**Health Monitoring** - Comprehensive service health tracking:
- **Service Health Events** - Real-time health status propagation
- **Progressive Backoff** - Automatic retry with exponential delays
- **Circuit Breaker Pattern** - Prevent cascading failures
- **Structured Logging** - Decision rationale and execution metrics

### Key Design Patterns

1. **Event-driven execution**: No direct service coupling, all communication through EventBus
2. **Policy-centralized triggers**: All timing logic and thresholds live in policies only
3. **Atomic state updates**: MapState prevents partial updates and race conditions
4. **Versioned updates**: Late/stale results are discarded to prevent UI regressions
5. **Pure services**: Services have no UI knowledge and no internal timers/triggers
6. **Lazy initialization**: Complex dependency chains resolved on-demand
7. **MainActor isolation**: UI updates guaranteed on main thread

## Development Guidelines

### From BalloonHunterApp.swift Comments

The main app file contains comprehensive AI assistant guidelines:

- **Follow the FSD**: The Functional Specification Document is the source of truth
- **Modern Swift**: Use async/await, SwiftData, SwiftUI property wrappers
- **Apple-native tools**: Prefer built-in frameworks over third-party dependencies
- **Clear separation**: Keep views, models, and services properly separated
- **Minimal comments**: Only for non-obvious logic, TODOs, or FIXMEs

### Event-Driven Development Guidelines

When working with the event-driven architecture:

**Services (Event Producers):**
- Services MUST be pure event producers with no UI knowledge
- Services MUST NOT have timers or autonomous triggers
- Services MUST publish events to EventBus, not to other services directly
- Services MUST expose health status through ServiceHealthEvents
- Services SHOULD use @MainActor isolation for UI-related services

**Policies (Event Consumers & Decision Logic):**
- Policies MUST subscribe to EventBus events, not service properties
- Policies MUST contain ALL trigger logic and thresholds
- Policies MUST use PolicyScheduler for consistent timing behavior
- Policies MUST emit versioned MapStateUpdate events
- Policies SHOULD implement caching and backoff strategies

**UI (State Observers):**
- UI MUST only observe MapState for all rendering decisions
- UI MUST publish user interactions as UIEvents to EventBus
- UI MUST NOT have direct service dependencies or business logic
- UI SHOULD handle MapState updates atomically

**General Rules:**
- NO direct service-to-service communication
- ALL triggers and thresholds live in policies only
- USE versioning to prevent stale data from corrupting fresh results
- USE structured logging for decision rationale and debugging

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

### Event Flow Examples

**Telemetry Update Flow:**
1. MySondyGo device → BLECommunicationService receives BLE data
2. BLECommunicationService publishes TelemetryEvent to EventBus
3. PredictionPolicy evaluates trigger conditions (movement, time, mode)
4. PredictionPolicy calls PredictionService with caching/backoff via PolicyScheduler
5. PredictionPolicy publishes MapStateUpdate with new prediction polyline
6. MapState applies versioned update atomically
7. TrackingMapView observes MapState change and re-renders map

**User Interaction Flow:**
1. User taps balloon annotation in TrackingMapView
2. TrackingMapView publishes UIEvent.manualPredictionTriggered to EventBus
3. PredictionPolicy receives event and forces immediate prediction
4. Same flow as above, bypassing time/movement checks

**Mode Transition Flow:**
1. ModeStateMachine observes telemetry and location events
2. ModeStateMachine evaluates transition conditions (altitude, speed, distance)
3. ModeStateMachine transitions to new mode with hysteresis protection
4. PredictionPolicy adjusts prediction interval based on new mode
5. All policies adapt their behavior to new mode configuration

**Health Monitoring Flow:**
1. Service encounters error (BLE disconnect, API failure, etc.)
2. Service publishes ServiceHealthEvent with degraded/unhealthy status
3. Policies observe health events and implement backoff strategies
4. Progressive retry delays prevent hammering failing services
5. Service recovery publishes healthy status to resume normal operation

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
- Triggers: Policy-determined prediction intervals (time-based), significant balloon movement or altitude changes, user manual prediction requests, mode transitions requiring updated predictions

**Route Calculation Service**
- Function: Determines optimal travel paths to predicted landing locations
- Triggers: New landing point predictions available, user location changes beyond distance thresholds, transportation method changes (car vs bicycle), route optimization requests

**Landing Point Service**
- Function: Determines probable balloon landing locations
- Triggers: Updated flight predictions received, balloon altitude approaching landing threshold, final approach mode activation, historical landing data analysis needs

**Data Persistence Service**
- Function: Stores and retrieves application data and user preferences
- Triggers: Application lifecycle events (startup, shutdown, background), configuration changes requiring permanent storage, track data updates for historical preservation, user settings modifications

### Policy Services (Decision Logic)

**Prediction Policy**
- Function: Orchestrates when and how flight predictions are requested
- Triggers: Time intervals based on current tracking mode, balloon movement distance thresholds, altitude change significance, user interaction requests, caching and performance optimization needs

**Routing Policy**
- Function: Manages route calculation timing and optimization
- Triggers: Distance changes between user and target locations, transportation method modifications, route cache expiration or invalidation, navigation accuracy requirements

**Camera Control Policy**
- Function: Manages map view positioning and zoom behavior
- Triggers: Balloon position updates requiring view adjustments, user location changes affecting optimal view, mode transitions requiring different zoom levels, user interaction with map controls

**User Interface Event Policy**
- Function: Handles user interactions and translates them to system events
- Triggers: Button presses and touch interactions, settings modifications, mode switches and preference changes, manual override requests

### Mode State Machine

**Explore Mode**
- Function: Low-intensity monitoring for initial balloon detection
- Triggers: Application startup, no active balloon tracking, balloon signal lost for extended periods, user manual mode selection

**Follow Mode**
- Function: Active tracking with regular updates and routing
- Triggers: Stable balloon signal established, balloon altitude and movement indicating active flight, user proximity to balloon within tracking range, automatic transition from explore mode

**Final Approach Mode**
- Function: High-frequency updates for landing phase tracking
- Triggers: Balloon altitude below landing threshold, descent rate indicating imminent landing, user proximity to predicted landing area, critical phase timing requirements

### Event Flow Triggers

**Time-Based Triggers**
- Prediction intervals (30 seconds to 5 minutes depending on mode)
- Cache expiration and cleanup cycles
- Health monitoring and status updates
- Background data persistence operations

**Threshold-Based Triggers**
- Movement distance minimums for updates
- Altitude change significance levels
- Signal strength and quality thresholds
- User proximity boundaries for mode transitions

**State-Change Triggers**
- Device connection/disconnection events
- Application lifecycle state changes
- User permission grants or revocations
- System resource availability changes

**User-Initiated Triggers**
- Manual prediction requests
- Settings and configuration changes
- Mode override selections
- Navigation and route requests

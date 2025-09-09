# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

This is an iOS app is built with Xcode outside of Claude. No separate linting or testing commands are configured.

## Architecture Overview

BalloonHunter is a SwiftUI-based iOS app for tracking weather balloons via BLE communication. The app uses a service-oriented architecture with policy-based orchestration.

### Core Services Architecture

The app is built around several key services managed by `ServiceManager`:

**Data Flow Services:**
- `BLECommunicationService` - Handles Bluetooth communication with MySondyGo devices
- `BalloonTrackingService` - Processes telemetry data and tracks balloon flight path
- `CurrentLocationService` - Manages iPhone location and heading data
- `PersistenceService` - Handles UserDefaults-based data storage

**Processing Services:**
- `PredictionService` - Calls Sondehub API for balloon trajectory prediction
- `RouteCalculationService` - Calculates routes using Apple Maps
- `LandingPointService` - Determines valid landing points from multiple sources
- `AnnotationService` - Manages map annotations and overlays

**Orchestration:**
- `ServiceManager` - Central coordinator with lazy-loaded service dependencies
- `PolicyScheduler` - Event-driven service orchestration (not timer-based)
- `PredictionPolicy`, `RoutingPolicy`, `CameraPolicy` - Policy implementations

### Data Models

Key data structures defined in `AppModels.swift`:
- `TelemetryData` - Real-time balloon telemetry from BLE
- `BalloonTrackPoint` - Serializable track point for persistence
- `PredictionData` - API response data with flight path predictions
- `RouteData` - Apple Maps route information
- `MapAnnotationItem` - Map annotation with dynamic views

### Service Communication

Services communicate through:
- **Published properties** (@Published) for reactive UI updates
- **Event publishers** (telemetryPublisher, userLocationPublisher, uiEventPublisher) in ServiceManager
- **Combine subscriptions** for cross-service coordination
- **Weak references** to prevent circular dependencies

### Key Design Patterns

1. **Policy-driven execution**: Services are "pure" (no internal timers) and only execute when triggered by policies
2. **Lazy service initialization**: Services are created on-demand to handle complex dependency chains  
3. **Publisher-subscriber pattern**: Extensive use of Combine for reactive data flow
4. **Environment object injection**: SwiftUI views receive services via @EnvironmentObject

## Development Guidelines

### From BalloonHunterApp.swift Comments

The main app file contains comprehensive AI assistant guidelines:

- **Follow the FSD**: The Functional Specification Document is the source of truth
- **Modern Swift**: Use async/await, SwiftData, SwiftUI property wrappers
- **Apple-native tools**: Prefer built-in frameworks over third-party dependencies
- **Clear separation**: Keep views, models, and services properly separated
- **Minimal comments**: Only for non-obvious logic, TODOs, or FIXMEs

### Service Dependencies

When modifying services, be aware of the dependency chain:
- ServiceManager creates all services with proper weak references
- Services should not directly instantiate other services
- Use ServiceManager for cross-service communication
- Maintain @MainActor isolation for UI-related services

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

### Policy System Integration

The app uses a sophisticated policy system for service orchestration:
- `PredictionPolicy` - Manages prediction API calls with caching
- `RoutingPolicy` - Handles route calculations with caching  
- `CameraPolicy` - Controls map camera behavior
- `PolicyScheduler` - Central coordinator for policy execution

This replaces direct timer-based triggers and provides better control over service execution.

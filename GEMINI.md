# GEMINI.md

This file provides guidance to Gemini when working with code in this repository.

## Project Overview

BalloonHunter is a SwiftUI-based iOS app for tracking weather balloons. The app communicates with a custom BLE device ("MySondyGo") to receive telemetry data from weather balloons. It displays the balloon's real-time location on a map, predicts its flight path and landing zone, and calculates a route for the user to the landing site.

The app is built using a service-oriented architecture with a central `ServiceManager` that coordinates various services. It uses a policy-based system for orchestrating service execution, which is managed by a `PolicyScheduler`.

## Key Technologies

*   **UI Framework:** SwiftUI
*   **Concurrency:** Combine, async/await
*   **Networking:** URLSession for API calls, CoreBluetooth for BLE communication
*   **Mapping:** MapKit
*   **Persistence:** UserDefaults

## Architecture

The application's architecture is based on a set of services, each with a specific responsibility:

*   **`ServiceManager`**: The central coordinator that initializes and manages all other services.
*   **`BLECommunicationService`**: Handles all communication with the MySondyGo BLE device.
*   **`BalloonTrackingService`**: Processes telemetry data, tracks the balloon's flight path, and detects landing.
*   **`PredictionService`**: Fetches trajectory predictions from the Sondehub API.
*   **`RouteCalculationService`**: Calculates routes to the balloon's predicted landing site using Apple Maps.
*   **`AnnotationService`**: Manages map annotations and overlays.
*   **`PersistenceService`**: Handles data persistence using UserDefaults.
*   **`PolicyScheduler`**: Manages the execution of policies for service orchestration.
*   **`PredictionPolicy`**, **`RoutingPolicy`**, **`CameraPolicy`**: Implement the logic for when and how to execute predictions, routing, and camera updates.

## Data Models

The core data models are defined in `AppModels.swift`:

*   **`TelemetryData`**: Represents a single telemetry data point received from the BLE device.
*   **`BalloonTrackPoint`**: A serializable representation of a point in the balloon's track.
*   **`PredictionData`**: Contains the predicted flight path, burst point, and landing point.
*   **`RouteData`**: Represents a calculated route with path, distance, and travel time.
*   **`DeviceSettings`**: Configuration parameters for the MySondyGo device.
*   **`UserSettings`**: User-configurable settings for prediction parameters.

## Building and Running

This is an iOS application built with Xcode. To build and run the project:

1.  Open `BalloonHunter.xcodeproj` in Xcode.
2.  Select a target device or simulator.
3.  Click the "Run" button.

There are no specific command-line build commands, linting, or testing configurations.

## Development Conventions

*   **Modern Swift:** The project uses modern Swift features like `async/await` and Combine.
*   **Apple-Native Tools:** The project prefers native Apple frameworks over third-party dependencies.
*   **Separation of Concerns:** The code is organized into views, models, and services to maintain a clear separation of concerns.
*   **Policy-Driven Execution:** Services are designed to be "pure" and are triggered by policies rather than internal timers.
*   **Lazy Initialization:** Services are loaded on-demand to manage dependencies.
*   **Reactive Data Flow:** The app uses Combine's publisher-subscriber pattern for data flow between services and views.
*   **Environment Objects:** SwiftUI views receive services and settings via `@EnvironmentObject`.

# 🎈 BalloonHunter

A sophisticated iOS application for tracking and recovering weather balloons in real-time. BalloonHunter connects to MySondyGo devices via Bluetooth Low Energy to receive telemetry data and provides intelligent prediction, routing, and mapping for successful balloon recovery operations.

![iOS](https://img.shields.io/badge/iOS-17.6+-blue.svg)
![Swift](https://img.shields.io/badge/Swift-5.9+-orange.svg)
![Xcode](https://img.shields.io/badge/Xcode-15.0+-blue.svg)
![License](https://img.shields.io/badge/license-MIT-green.svg)

## ✨ Features

### 🔗 Real-Time Connectivity
- **Bluetooth Low Energy**: Seamless connection to MySondyGo devices
- **APRS Fallback**: Automatic failover to SondeHub APRS data when BLE unavailable
- **Intelligent Polling**: API-efficient polling with age-based cadence (15s → 5min → 1hr)

### 📍 Advanced Tracking
- **Live Telemetry**: Real-time position, altitude, speed, and sensor data
- **Flight Phase Detection**: Automatic detection of ascending/descending/landed states
- **Smart Landing Detection**: 5-packet movement analysis for BLE, 2-minute timeout for APRS
- **Motion Smoothing**: Advanced EMA filtering for accurate speed calculations

### 🗺️ Intelligent Mapping
- **70/30 Split Interface**: Map-focused design with compact data panel
- **Dual Camera Modes**: Free navigation and heading-locked modes with zoom preservation
- **Dynamic Overlays**: Balloon track, prediction path, landing zones, and user position
- **Apple Maps Integration**: One-tap navigation with transport mode selection

### 🎯 Predictive Analytics
- **Tawhiri Integration**: Professional trajectory prediction via SondeHub API
- **Automatic Updates**: 60-second prediction refresh during flight
- **Smart Caching**: Coordinate and time-based cache for API efficiency
- **Adjustable Parameters**: Configurable ascent/descent rates and burst altitude

### ⚙️ Smart Automation
- **Automatic Frequency Sync**: RadioSondyGo synchronization with APRS data
- **State Machine**: 7-state telemetry management with 30s debouncing
- **Burst Killer Support**: Countdown timer with cross-session persistence
- **Background Resilience**: Maintains state through app lifecycle events

## 🏗️ Architecture

BalloonHunter follows a modern service-coordinator architecture with clean separation of concerns:

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   SwiftUI Views │◄──►│ ServiceCoordinator │◄──►│    Services     │
│                 │    │                 │    │                 │
│ • TrackingMapView│    │ • State Management│    │ • BLEService    │
│ • DataPanelView  │    │ • Cross-Service   │    │ • APRSService   │
│ • SettingsView   │    │   Coordination    │    │ • PredictionSvc │
└─────────────────┘    └─────────────────┘    └─────────────────┘
```

### Key Components

- **BLECommunicationService**: MySondyGo device management with state enum
- **APRSTelemetryService**: SondeHub integration with intelligent polling
- **BalloonPositionService**: Telemetry arbitration and state machine
- **PredictionService**: Tawhiri API integration with caching
- **CurrentLocationService**: GPS tracking and proximity detection

## 🚀 Getting Started

### Prerequisites

- iOS 17.6+ device (required for Bluetooth and location features)
- Xcode 15.0+
- Active internet connection for APRS and prediction services
- MySondyGo device (optional - app works with APRS-only mode)

### Installation

1. Clone the repository:
```bash
git clone https://github.com/your-username/BalloonHunter.git
cd BalloonHunter
```

2. Open in Xcode:
```bash
open BalloonHunter.xcodeproj
```

3. Configure your development team:
   - Select the project in Xcode
   - Update "Team" in Signing & Capabilities
   - Ensure Bundle Identifier is unique

4. Build and run on device:
   - Select your iOS device as the target
   - Press ⌘+R to build and run

### First Launch Setup

1. **Permissions**: Grant Bluetooth and Location permissions when prompted
2. **Station ID**: Configure your SondeHub station ID in Settings
3. **MySondyGo**: Pair your device via Settings → BLE Configuration
4. **Test Mode**: Use APRS-only mode for testing without hardware

## 📱 Usage

### Basic Operation

1. **Startup**: App automatically initializes services and attempts BLE connection
2. **Tracking**: View real-time balloon position on the map
3. **Navigation**: Tap balloon annotation for Apple Maps navigation
4. **Settings**: Access configuration via gear icon

### Data Panel

The lower panel displays critical information in two tables:

**Status Row**: Connection • Flight Phase • Sonde Type • Name • Altitude
**Metrics**: Frequency/Signal/Battery • Speeds/Distance • Times/Descent Rate

### Camera Modes

- **Free Mode**: Manual map navigation with pinch/zoom
- **Heading Mode**: Locked to user heading with preserved zoom levels

## ⚙️ Configuration

### Key Settings

- **Station ID**: SondeHub station for APRS fallback
- **Ascent/Descent Rates**: Prediction parameters
- **Burst Altitude**: Flight termination altitude
- **Transport Mode**: Navigation preferences (car/bike)

### BLE Configuration

- **Device Discovery**: Automatic MySondyGo scanning
- **Frequency Sync**: Automatic RadioSondyGo frequency matching
- **Command Interface**: Manual device control and tuning

## 🛠️ Development

### Build Commands

```bash
# Build for simulator
xcodebuild -project BalloonHunter.xcodeproj -scheme BalloonHunter \
  -destination 'platform=iOS Simulator,name=iPhone 15' build

# Run tests
xcodebuild -project BalloonHunter.xcodeproj -scheme BalloonHunter \
  -destination 'platform=iOS Simulator,name=iPhone 15' test

# Archive for distribution
xcodebuild -project BalloonHunter.xcodeproj -scheme BalloonHunter \
  -archivePath build/BalloonHunter.xcarchive archive
```

### Code Validation

```bash
# Swift syntax check
find . -name "*.swift" -exec swift -parse {} \;

# Check for warnings
xcodebuild -project BalloonHunter.xcodeproj -scheme BalloonHunter build | grep warning
```

### Architecture Guidelines

- **Services**: Domain logic and data management
- **Coordinator**: Cross-service orchestration and state coordination
- **Views**: Presentation-only SwiftUI components
- **Separation**: Clear boundaries between business logic and UI

## 📡 API Integration

### SondeHub APRS
- **Endpoint**: `https://api.v2.sondehub.org/sondes/site/{station_id}`
- **Rate Limiting**: Intelligent cadence based on data freshness
- **Data Format**: Standard sonde telemetry with ISO8601 timestamps

### Tawhiri Predictions
- **Endpoint**: `https://predict.sondehub.org/`
- **Parameters**: Launch point, rates, burst altitude
- **Caching**: Coordinate and time-based cache strategy

## 🏅 Key Achievements

- **Zero Memory Leaks**: Comprehensive weak reference management
- **Battery Efficient**: Intelligent polling and background optimization
- **Offline Resilient**: Graceful degradation when services unavailable
- **Professional UX**: Map-focused interface optimized for field use
- **State Machine**: Robust 7-state telemetry management
- **Type Safety**: Full Swift enum adoption for state management

## 📋 Requirements

- **Target**: iOS 17.6+
- **Language**: Swift 5.9+
- **Frameworks**: SwiftUI, Combine, CoreLocation, CoreBluetooth, MapKit
- **Permissions**: Bluetooth LE, Location Services
- **Network**: Internet required for APRS and predictions

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Follow the existing code style and architecture patterns
4. Add tests for new functionality
5. Commit your changes (`git commit -m 'Add amazing feature'`)
6. Push to the branch (`git push origin feature/amazing-feature`)
7. Open a Pull Request

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- **SondeHub Community**: APRS data and prediction services
- **MySondyGo Project**: BLE telemetry hardware
- **CUSF**: Tawhiri prediction engine
- **Weather Balloon Community**: Field testing and feedback

---

**Built with ❤️ for the weather balloon tracking community**
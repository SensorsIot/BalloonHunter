# BalloonHunter iOS

iOS version of BalloonHunter - a weather balloon tracking and recovery app.

> **See also**: [Main README](../README.md) | [Android Version](../android/README.md)

![iOS](https://img.shields.io/badge/iOS-17.6+-blue.svg)
![Swift](https://img.shields.io/badge/Swift-5.9+-orange.svg)
![SwiftUI](https://img.shields.io/badge/SwiftUI-5.0-blue.svg)

## Status

**App Store**: Pending Review (Submitted November 21, 2025)

- Version: 1.0
- Bundle ID: HB9BLA.BalloonHunter
- Platform: iPhone

## Requirements

- iOS 17.6+
- Xcode 16.1+
- Apple Developer account (for device deployment)

## Build

```bash
cd ios
open BalloonHunter.xcodeproj
# Or from command line:
xcodebuild -project BalloonHunter.xcodeproj -scheme BalloonHunter \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
```

## Architecture

- **UI**: SwiftUI with environment objects
- **State**: Service-coordinator pattern with 7-state telemetry state machine
- **Networking**: URLSession for API calls
- **Maps**: Apple MapKit
- **BLE**: CoreBluetooth

### Key Components

```
BalloonHunter/
├── Services/
│   ├── BLEService.swift          # MySondyGo Bluetooth communication
│   ├── APRSService.swift         # SondeHub APRS polling
│   ├── PredictionService.swift   # Tawhiri trajectory predictions
│   ├── LocationService.swift     # User location tracking
│   └── PersistenceService.swift  # Track/settings storage
├── ServiceCoordinator.swift      # Cross-service orchestration
├── Views/
│   ├── ContentView.swift         # Main map interface
│   ├── DataPanelView.swift       # Telemetry display
│   └── SettingsView.swift        # Configuration
└── Models/
    └── Models.swift              # Data structures
```

## iOS-Specific Features

- **Apple Maps**: Native MapKit integration with Apple Maps navigation
- **CarPlay Alerts**: Landing prediction change notifications during navigation
- **Background Tracking**: Limited background location updates (see BACKGROUND_TRACKING.md)

## Documentation

- [Functional Specification](BalloonHunter/BalloonHunterAppFSD.md)
- [Background Tracking](BACKGROUND_TRACKING.md)
- [SondeHub API Reference](BalloonHunter/SondeHub_API_Reference.md)

## License

MIT License - See [LICENSE](../LICENSE) for details

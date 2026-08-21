# 🍎 BalloonHunter iOS

iOS version of BalloonHunter - a weather balloon tracking and recovery app.

> 📍 **See also**: [Main README](../README.md) | [🤖 Android Version](../android/README.md)

![iOS](https://img.shields.io/badge/iOS-17.6+-000000?style=flat&logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-5.9+-FA7343?style=flat&logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/SwiftUI-5.0-0D96F6?style=flat&logo=swift&logoColor=white)
![Xcode](https://img.shields.io/badge/Xcode-16.1+-147EFB?style=flat&logo=xcode&logoColor=white)

## 📱 Status

**App Store**: Pending Review (Submitted November 21, 2025)

| | |
|---|---|
| Version | 1.0 |
| Bundle ID | HB9BLA.BalloonHunter |
| Platform | iPhone |

## 📋 Requirements

- iOS 17.6+
- Xcode 16.1+
- Apple Developer account (for device deployment)

## 🔨 Build

```bash
cd ios
open BalloonHunter.xcodeproj

# Or from command line:
xcodebuild -project BalloonHunter.xcodeproj -scheme BalloonHunter \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
```

## 🏗️ Architecture

| Component | Technology |
|-----------|------------|
| UI | SwiftUI |
| State | Service-coordinator pattern |
| Networking | URLSession |
| Maps | Apple MapKit |
| BLE | CoreBluetooth |

### 📁 Project Structure

```
BalloonHunter/
├── 📂 Services/
│   ├── BLEService.swift          # MySondyGo Bluetooth
│   ├── APRSService.swift         # SondeHub APRS polling
│   ├── PredictionService.swift   # Tawhiri predictions
│   ├── LocationService.swift     # User location
│   └── PersistenceService.swift  # Track/settings storage
├── 📄 ServiceCoordinator.swift   # Cross-service orchestration
├── 📂 Views/
│   ├── ContentView.swift         # Main map interface
│   ├── DataPanelView.swift       # Telemetry display
│   └── SettingsView.swift        # Configuration
└── 📂 Models/
    └── Models.swift              # Data structures
```

## ✨ iOS-Specific Features

| Feature | Description |
|---------|-------------|
| 🗺️ Apple Maps | Native MapKit integration |
| 🚗 CarPlay Alerts | Landing prediction notifications |
| 📍 Background Tracking | Limited background updates |

## 📄 Documentation

- [📋 Functional Specification](BalloonHunter/BalloonHunterAppFSD.md)
- [📍 Background Tracking](BACKGROUND_TRACKING.md)
- [📡 SondeHub API Reference](BalloonHunter/SondeHub_API_Reference.md)

## 📜 License

MIT License - See [LICENSE](../LICENSE) for details

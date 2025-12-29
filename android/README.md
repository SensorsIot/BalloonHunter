# BalloonHunter Android

Android version of BalloonHunter - a weather balloon tracking and recovery app.

> **See also**: [Main README](../README.md) | [iOS Version](../ios/README.md)

![Android](https://img.shields.io/badge/Android-API%2026+-green.svg)
![Kotlin](https://img.shields.io/badge/Kotlin-1.9+-purple.svg)
![Jetpack Compose](https://img.shields.io/badge/Jetpack%20Compose-1.5+-blue.svg)

## Status

**In Development** - Feature parity with iOS version

- Min SDK: 26 (Android 8.0)
- Target SDK: 34 (Android 14)

## Requirements

- Android Studio Hedgehog (2023.1.1) or newer
- JDK 17+
- Google Maps API key

## Setup

1. Clone the repository
2. Add your Google Maps API key to `local.properties`:
   ```
   MAPS_API_KEY=your_api_key_here
   ```
3. Open in Android Studio and sync Gradle

## Build

```bash
cd android
./gradlew assembleDebug

# Install on connected device
./gradlew installDebug
```

## Architecture

- **UI**: Jetpack Compose with Material 3
- **DI**: Hilt
- **Async**: Kotlin Coroutines + StateFlow
- **Maps**: Google Maps SDK for Android
- **BLE**: Android Bluetooth API

### Key Components

```
app/src/main/java/com/balloonhunter/app/
├── data/
│   ├── aprs/AprsService.kt           # SondeHub APRS polling
│   ├── ble/BleService.kt             # MySondyGo Bluetooth
│   ├── prediction/PredictionService.kt # Tawhiri predictions
│   ├── routing/RoutingService.kt     # Google Directions API
│   └── persistence/                  # Local storage
├── domain/
│   ├── models/                       # Data classes
│   └── services/
│       ├── BalloonCoordinator.kt     # Main orchestrator
│       ├── BalloonTrackService.kt    # Track management
│       └── LandingPointService.kt    # Landing predictions
├── presentation/
│   ├── MapScreen.kt                  # Main map UI
│   ├── DataPanel.kt                  # Telemetry display
│   └── state/MapViewModel.kt         # UI state
└── di/AppModule.kt                   # Hilt modules
```

## Android-Specific Features

- **Google Maps**: Native Google Maps SDK with satellite/standard toggle
- **Google Navigation**: One-tap launch to Google Maps for turn-by-turn directions
- **Material 3**: Modern Android design system
- **Foreground Service**: Continuous BLE connection support

## Map Overlays

| Overlay | Color | Width |
|---------|-------|-------|
| Balloon Track | Red | 6dp |
| Prediction Path | Cyan-blue (#00AAFF) | 8dp |
| Route to Landing | Green | 5dp |
| Landing History | Purple | 3dp |

## Permissions

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
```

## Documentation

- [Functional Specification](docs/BalloonHunter_Android_fsd.md)
- [SondeHub API Reference](../docs/SondeHub_API_Reference.md)

## License

MIT License - See [LICENSE](../LICENSE) for details

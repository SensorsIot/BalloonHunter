# 🤖 BalloonHunter Android

Android version of BalloonHunter - a weather balloon tracking and recovery app.

> 📍 **See also**: [Main README](../README.md) | [🍎 iOS Version](../ios/README.md)

![Android](https://img.shields.io/badge/Android-API%2026+-3DDC84?style=flat&logo=android&logoColor=white)
![Kotlin](https://img.shields.io/badge/Kotlin-1.9+-7F52FF?style=flat&logo=kotlin&logoColor=white)
![Jetpack Compose](https://img.shields.io/badge/Jetpack%20Compose-1.5+-4285F4?style=flat&logo=jetpackcompose&logoColor=white)
![Gradle](https://img.shields.io/badge/Gradle-8.0+-02303A?style=flat&logo=gradle&logoColor=white)

## 📱 Status

**In Development** - Feature parity with iOS version

| | |
|---|---|
| Min SDK | 26 (Android 8.0) |
| Target SDK | 34 (Android 14) |

## 📋 Requirements

- Android Studio Hedgehog (2023.1.1) or newer
- JDK 17+
- Google Maps API key

## ⚙️ Setup

1. Clone the repository
2. Add your Google Maps API key to `local.properties`:
   ```properties
   MAPS_API_KEY=your_api_key_here
   ```
3. Open in Android Studio and sync Gradle

## 🔨 Build

```bash
cd android
./gradlew assembleDebug

# Install on connected device
./gradlew installDebug
```

## 🏗️ Architecture

| Component | Technology |
|-----------|------------|
| UI | Jetpack Compose + Material 3 |
| DI | Hilt |
| Async | Kotlin Coroutines + StateFlow |
| Maps | Google Maps SDK |
| BLE | Android Bluetooth API |

### 📁 Project Structure

```
app/src/main/java/com/balloonhunter/app/
├── 📂 data/
│   ├── aprs/AprsService.kt           # SondeHub APRS
│   ├── ble/BleService.kt             # MySondyGo Bluetooth
│   ├── prediction/PredictionService.kt # Tawhiri
│   ├── routing/RoutingService.kt     # Google Directions
│   └── persistence/                  # Local storage
├── 📂 domain/
│   ├── models/                       # Data classes
│   └── services/
│       ├── BalloonCoordinator.kt     # Main orchestrator
│       ├── BalloonTrackService.kt    # Track management
│       └── LandingPointService.kt    # Landing predictions
├── 📂 presentation/
│   ├── MapScreen.kt                  # Main map UI
│   ├── DataPanel.kt                  # Telemetry display
│   └── state/MapViewModel.kt         # UI state
└── 📂 di/
    └── AppModule.kt                  # Hilt modules
```

## 🗺️ Map Overlays

| Overlay | Color | Width |
|---------|-------|-------|
| 🔴 Balloon Track | Red | 6dp |
| 🔵 Prediction Path | Cyan-blue (#00AAFF) | 8dp |
| 🟢 Route to Landing | Green | 5dp |
| 🟣 Landing History | Purple | 3dp |

## 🔐 Permissions

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
```

## ✨ Android-Specific Features

| Feature | Description |
|---------|-------------|
| 🗺️ Google Maps | Native SDK with satellite toggle |
| 🧭 Google Navigation | One-tap turn-by-turn directions |
| 🎨 Material 3 | Modern Android design system |
| 📡 Foreground Service | Continuous BLE connection |

## 📄 Documentation

- [📋 Functional Specification](docs/BalloonHunter_Android_fsd.md)
- [📡 SondeHub API Reference](../docs/SondeHub_API_Reference.md)

## 📜 License

MIT License - See [LICENSE](../LICENSE) for details

# 🎈 BalloonHunter

A cross-platform mobile application for tracking and recovering weather balloons in real-time. BalloonHunter connects to MySondyGo devices via Bluetooth Low Energy to receive telemetry data, integrates with SondeHub APRS network for fallback tracking, and uses Tawhiri prediction API for intelligent trajectory forecasting.

![iOS](https://img.shields.io/badge/iOS-17.6+-000000?style=flat&logo=apple&logoColor=white)
![Android](https://img.shields.io/badge/Android-API%2026+-3DDC84?style=flat&logo=android&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-5.9+-FA7343?style=flat&logo=swift&logoColor=white)
![Kotlin](https://img.shields.io/badge/Kotlin-1.9+-7F52FF?style=flat&logo=kotlin&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-green.svg)

## 📱 Platform Documentation

| Platform | Status | Documentation |
|----------|--------|---------------|
| 🍎 **iOS** | App Store Pending | [ios/README.md](ios/README.md) |
| 🤖 **Android** | In Development | [android/README.md](android/README.md) |
| 🐍 **Simulation** | Scaffold | [Simulation/README.md](Simulation/README.md) |

## ✨ Key Features

### 🔗 Dual Connectivity
- **MySondyGo BLE**: Direct connection to RadioSondyGo devices for real-time telemetry
- **SondeHub APRS**: Automatic fallback to global amateur radio network when BLE unavailable
- **Smart Polling**: Intelligent API cadence based on data freshness (15s → 5min → 1hr)

### 🎯 Professional Prediction
- **Tawhiri API**: CUSF trajectory prediction engine via SondeHub
- **Real-Time Updates**: Automatic prediction refresh every 60 seconds during flight
- **Landing Zones**: Burst and landing point calculations
- **Adaptive Parameters**: Uses live descent rates when available

### 🗺️ Hunter-Focused Interface
- **Map-Centric Design**: 70% map view for field tracking
- **Live Overlays**: Balloon track (red), prediction path (cyan-blue), route (green)
- **Smart Route Recalculation**: Only recalculates when needed (off-route, landing shift, mode change)
- **Native Navigation**: Apple Maps (iOS) / Google Maps (Android)
- **Heading Mode**: Compass-locked view for directional navigation

## 🚀 Quick Start

### 🍎 iOS
```bash
cd ios
open BalloonHunter.xcodeproj
```
Requirements: Xcode 16.1+, iOS 17.6+ SDK

### 🤖 Android
```bash
cd android
# Add MAPS_API_KEY=your_key to local.properties
./gradlew assembleDebug
```
Requirements: Android Studio, JDK 17+, Google Maps API key

### 🐍 Simulation
```bash
pip install -e Simulation
pytest Simulation/tests
```
Requirements: Python 3.11+ (provided by the repo devcontainer)

## 📡 API Integration

| Service | Endpoint |
|---------|----------|
| SondeHub APRS | `https://api.v2.sondehub.org/sondes/site/{station_id}` |
| Tawhiri Predictions | `https://api.v2.sondehub.org/tawhiri` |

## 📄 Documentation

- 🔒 [Privacy Policy](Privacy-Policy.md)
- 🍎 [iOS FSD](ios/BalloonHunter/BalloonHunterAppFSD.md)
- 🤖 [Android FSD](android/docs/BalloonHunter_Android_fsd.md)
- 📡 [SondeHub API Reference](docs/SondeHub_API_Reference.md)

## 🙏 Acknowledgments

- **SondeHub Community**: Global APRS network and prediction services
- **MySondyGo Project**: Open-source BLE telemetry hardware
- **CUSF**: Tawhiri trajectory prediction engine
- **Amateur Radio Community**: Worldwide balloon tracking infrastructure

## 📞 Contact

- **Issues**: [GitHub Issues](https://github.com/SensorsIot/BalloonHunter/issues)
- **Developer**: Andreas Spiess (HB9BLA)

## 📜 License

MIT License - See LICENSE file for details

---

**Built with ❤️ for the weather balloon tracking community by HB9BLA**

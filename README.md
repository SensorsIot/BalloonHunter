# BalloonHunter

A sophisticated mobile application for tracking and recovering weather balloons in real-time. BalloonHunter connects to MySondyGo devices via Bluetooth Low Energy to receive telemetry data, integrates with SondeHub APRS network for fallback tracking, and uses Tawhiri prediction API to provide intelligent trajectory forecasting, routing, and mapping for successful balloon recovery operations.

![iOS](https://img.shields.io/badge/iOS-17.6+-blue.svg)
![Android](https://img.shields.io/badge/Android-API%2026+-green.svg)
![Swift](https://img.shields.io/badge/Swift-5.9+-orange.svg)
![Kotlin](https://img.shields.io/badge/Kotlin-1.9+-purple.svg)
![License](https://img.shields.io/badge/license-MIT-green.svg)

## Availability

### iOS
**App Store Status**: Pending Review (Submitted November 21, 2025)

BalloonHunter has been submitted to the Apple App Store and is currently under review. Once approved, it will be available for free download on all iPhones running iOS 17.6+.

**Submission Details**:
- Version: 1.0
- Bundle ID: HB9BLA.BalloonHunter
- Platform: iPhone only

### Android
**Status**: In Development

The Android version is under active development with feature parity to the iOS app. Build from source using Android Studio.

## Key Features

### Dual Connectivity
- **MySondyGo BLE**: Direct connection to RadioSondyGo devices for real-time telemetry
- **SondeHub APRS**: Automatic fallback to global amateur radio network when BLE unavailable
- **Smart Polling**: Intelligent API cadence based on data freshness (15s to 5min to 1hr)

### Professional Prediction
- **Tawhiri API**: Leverages CUSF's professional trajectory prediction engine via SondeHub
- **Real-Time Updates**: Automatic prediction refresh every 60 seconds during flight
- **Landing Zones**: Accurate burst and landing point calculations with uncertainty mapping
- **Adaptive Parameters**: Uses live descent rates when available, fallback to user settings

### Hunter-Focused Interface
- **Map-Centric Design**: 70% map view optimized for field tracking operations
- **Live Overlays**: Balloon track (red), prediction path (bright cyan-blue), landing zones, and hunter position
- **Smart Route Recalculation**: Intelligent navigation that only recalculates when needed:
  - Off-route detection (>=50m deviation)
  - Landing point movement (>=100m shift)
  - Transport mode changes (car/bike)
  - Minimizes API calls (3-8 per chase vs 360+/hour with time-based updates)
- **Native Navigation**: One-tap routing with car/bike transport modes (Apple Maps on iOS, Google Maps on Android)
- **Heading Mode**: Compass-locked view for directional navigation to landing site

## Architecture

### iOS
Modern SwiftUI app with service-coordinator pattern and 7-state telemetry state machine for robust tracking operations.

### Android
Jetpack Compose UI with Hilt dependency injection, Kotlin coroutines/StateFlow for reactive data, and Google Maps SDK for mapping.

**Key Services**: BLE Communication - SondeHub APRS - Tawhiri Predictions - Location Tracking - Data Persistence

## Quick Start

### Requirements

**iOS**:
- iOS 17.6+ device with Bluetooth and Location permissions
- Xcode 16.1+ for development
- Apple Developer account (for device deployment)

**Android**:
- Android 8.0+ (API 26) device with Bluetooth and Location permissions
- Android Studio Hedgehog or newer for development
- Google Maps API key

**Both**:
- Internet connection for SondeHub APRS and Tawhiri predictions
- MySondyGo device (optional - works with APRS-only)

### Installation

**From Source (iOS)**:
```bash
git clone https://github.com/SensorsIot/BalloonHunter.git
cd BalloonHunter/ios
open BalloonHunter.xcodeproj
```

**From Source (Android)**:
```bash
git clone https://github.com/SensorsIot/BalloonHunter.git
cd BalloonHunter/android
# Add your Google Maps API key to local.properties:
# MAPS_API_KEY=your_api_key_here
# Open in Android Studio and build
```

### Setup
1. **Configure Station ID**: Enter your SondeHub station ID in Settings
2. **Grant Permissions**: Allow Bluetooth and Location access
3. **Pair MySondyGo**: Optional BLE device pairing for direct telemetry
4. **Ready to Track**: App automatically finds active sondes via APRS

## Usage

**Automatic Operation**: App initializes services, connects to MySondyGo (if available), and displays live tracking map with prediction overlays.

**Key Controls**: Settings gear - Transport mode picker - Heading lock - Navigation button

**Data Panel**: Real-time telemetry, flight metrics, and prediction timers in compact lower panel.

## Development

### iOS Build
```bash
xcodebuild -project ios/BalloonHunter.xcodeproj -scheme BalloonHunter \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
```

### Android Build
```bash
cd android
./gradlew assembleDebug
```

### Architecture
- **Services**: Domain logic (BLE, APRS, Prediction, Location, Persistence)
- **Coordinator**: Cross-service orchestration and state management
- **Views**: Native UI (SwiftUI on iOS, Jetpack Compose on Android)

## API Integration

**SondeHub APRS**: `https://api.v2.sondehub.org/sondes/site/{station_id}`
**Tawhiri Predictions**: `https://api.v2.sondehub.org/tawhiri`

Intelligent polling with coordinate/time-based caching for optimal performance.

## Documentation

- **[Privacy Policy](Privacy-Policy.md)**: Complete privacy and data usage policy
- **[iOS FSD](ios/BalloonHunter/BalloonHunterAppFSD.md)**: iOS functional specification
- **[Android FSD](android/docs/BalloonHunter_Android_fsd.md)**: Android functional specification

## Acknowledgments

- **SondeHub Community**: Global APRS network and prediction services
- **MySondyGo Project**: Open-source BLE telemetry hardware
- **CUSF**: Professional Tawhiri trajectory prediction engine
- **Amateur Radio Community**: Worldwide balloon tracking infrastructure

## Contact & Support

- **Issues**: [GitHub Issues](https://github.com/SensorsIot/BalloonHunter/issues)
- **Developer**: Andreas Spiess (HB9BLA)

## License

MIT License - See LICENSE file for details

---

**Built for the weather balloon tracking community by HB9BLA**

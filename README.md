# 🎈 BalloonHunter

A sophisticated iOS application for tracking and recovering weather balloons in real-time. BalloonHunter connects to MySondyGo devices via Bluetooth Low Energy to receive telemetry data, integrates with SondeHub APRS network for fallback tracking, and uses Tawhiri prediction API to provide intelligent trajectory forecasting, routing, and mapping for successful balloon recovery operations.

![iOS](https://img.shields.io/badge/iOS-17.6+-blue.svg)
![Swift](https://img.shields.io/badge/Swift-5.9+-orange.svg)
![License](https://img.shields.io/badge/license-MIT-green.svg)

## ✨ Key Features

### 🔗 Dual Connectivity
- **MySondyGo BLE**: Direct connection to RadioSondyGo devices for real-time telemetry
- **SondeHub APRS**: Automatic fallback to global amateur radio network when BLE unavailable
- **Smart Polling**: Intelligent API cadence based on data freshness (15s → 5min → 1hr)

### 🎯 Professional Prediction
- **Tawhiri API**: Leverages CUSF's professional trajectory prediction engine via SondeHub
- **Real-Time Updates**: Automatic prediction refresh every 60 seconds during flight
- **Landing Zones**: Accurate burst and landing point calculations with uncertainty mapping
- **Adaptive Parameters**: Uses live descent rates when available, fallback to user settings

### 🗺️ Hunter-Focused Interface
- **Map-Centric Design**: 70% map view optimized for field tracking operations
- **Live Overlays**: Balloon track, prediction path, landing zones, and hunter position
- **Apple Maps Navigation**: One-tap routing with car/bike transport modes
- **Landing Change Alerts**: Notifications when prediction shifts >300m during CarPlay navigation
- **Heading Mode**: Compass-locked view for directional navigation to landing site

## 🏗️ Architecture

Modern SwiftUI app with service-coordinator pattern and 7-state telemetry state machine for robust tracking operations.

**Key Services**: BLE Communication • SondeHub APRS • Tawhiri Predictions • Location Tracking • Data Persistence

## 🚀 Quick Start

### Requirements
- iOS 17.6+ device with Bluetooth and Location permissions
- Xcode 15.0+ for development
- Internet connection for SondeHub APRS and Tawhiri predictions
- MySondyGo device (optional - works with APRS-only)

### Installation
```bash
git clone https://github.com/SensorsIot/BalloonHunter.git
cd BalloonHunter
open BalloonHunter.xcodeproj
```

### Setup
1. **Configure Station ID**: Enter your SondeHub station ID in Settings
2. **Grant Permissions**: Allow Bluetooth and Location access
3. **Pair MySondyGo**: Optional BLE device pairing for direct telemetry
4. **Ready to Track**: App automatically finds active sondes via APRS

## 📱 Usage

**Automatic Operation**: App initializes services, connects to MySondyGo (if available), and displays live tracking map with prediction overlays.

**Key Controls**: Settings gear • Transport mode picker • Heading lock • Apple Maps navigation

**Data Panel**: Real-time telemetry, flight metrics, and prediction timers in compact lower panel.

## 🛠️ Development

### Build Commands
```bash
# Build and test
xcodebuild -project BalloonHunter.xcodeproj -scheme BalloonHunter \
  -destination 'platform=iOS Simulator,name=iPhone 15' build

# Swift syntax validation
swift -syntax-test BalloonHunter/*.swift
```

### Architecture
- **Services**: Domain logic (BLE, APRS, Prediction, Location, Persistence)
- **ServiceCoordinator**: Cross-service orchestration and state management
- **Views**: SwiftUI presentation layer with environment objects

## 📡 API Integration

**SondeHub APRS**: `https://api.v2.sondehub.org/sondes/site/{station_id}`
**Tawhiri Predictions**: `https://predict.sondehub.org/`

Intelligent polling with coordinate/time-based caching for optimal performance.

## 🙏 Acknowledgments

- **SondeHub Community**: Global APRS network and prediction services
- **MySondyGo Project**: Open-source BLE telemetry hardware
- **CUSF**: Professional Tawhiri trajectory prediction engine
- **Amateur Radio Community**: Worldwide balloon tracking infrastructure

---

**Built with ❤️ for the weather balloon tracking community**
# BalloonHunter - App Store Metadata (CLEAN VERSION - Use This!)

## App Name
BalloonHunter

## Subtitle (30 characters max)
Weather Balloon Tracking

## Promotional Text (170 characters max) - Can be updated anytime
Track weather balloons in real-time with MySondyGo BLE and SondeHub APRS. Professional prediction, intelligent routing, and map-centric interface for successful recovery.

## Description (4000 characters max) - CLEANED FOR APP STORE

Track and recover weather balloons with professional-grade tools used by the global amateur radio community. BalloonHunter connects to MySondyGo devices via Bluetooth and integrates with the SondeHub APRS network for comprehensive real-time balloon tracking.

KEY FEATURES

Dual Connectivity
- MySondyGo BLE - Direct connection to RadioSondyGo devices for real-time telemetry
- SondeHub APRS - Automatic fallback to global amateur radio network
- Smart polling adjusts API cadence based on data freshness (15s to 5min to 1hr)

Professional Prediction
- Tawhiri API - Leverages CUSF's professional trajectory prediction engine
- Real-time updates every 60 seconds during flight
- Accurate burst and landing point calculations with uncertainty mapping
- Adaptive parameters use live descent rates when available

Hunter-Focused Interface
- Map-centric design optimized for field tracking operations (70% map view)
- Live overlays show balloon track, prediction path, landing zones, and your position
- Smart route recalculation only when needed:
  - Off-route detection (50m+ deviation)
  - Landing point movement (100m+ shift)
  - Transport mode changes (car/bike)
- Apple Maps navigation with one-tap routing
- Landing change alerts during CarPlay navigation (300m+ shifts)
- Heading mode with compass-locked view for directional navigation

Advanced Tracking
- 7-state telemetry state machine for robust operation
- Automatic BLE/APRS switching with 30-second debounce
- Background Bluetooth support for continuous connection
- Local data persistence with CSV export capability
- Offline track viewing from cached data

TECHNICAL DETAILS

- Requires iOS 17.6 or later
- Bluetooth and location permissions required
- Internet connection needed for APRS and predictions
- Works with or without MySondyGo hardware
- Free and open source - no ads, no tracking, no accounts

PERFECT FOR

- Weather balloon enthusiasts and chasers
- Amateur radio operators (hams)
- High-altitude balloon (HAB) recovery teams
- Educational institutions launching research balloons
- Anyone interested in atmospheric science

PRIVACY & DATA

- All location data stays on your device
- No personal information collected
- No user accounts or registration required
- Open source code available on GitHub
- Full privacy policy included

Built for the weather balloon tracking community by HB9BLA.

## Keywords (100 characters max, comma-separated)
weather balloon,tracking,APRS,ham radio,MySondyGo,sonde,amateur radio,GPS,navigation,radiosonde

## Support URL
https://github.com/SensorsIot/BalloonHunter

## Marketing URL (optional)
https://github.com/SensorsIot/BalloonHunter

## Privacy Policy URL
https://raw.githubusercontent.com/SensorsIot/BalloonHunter/main/Privacy-Policy.md

## Category
Primary: Navigation
Secondary: Weather

## Age Rating
4+ (No objectionable content)

## What's New in This Version (1.0)

Initial release of BalloonHunter - Professional weather balloon tracking for iOS.

Features:
- MySondyGo Bluetooth connectivity
- SondeHub APRS network integration
- Tawhiri trajectory predictions
- Intelligent route calculation
- Apple Maps navigation
- Heading mode for directional tracking
- CSV data export
- Offline track viewing

Track weather balloons like a pro!

## App Store Review Notes

This app is designed for weather balloon tracking and recovery. To test the app:

1. The app can be tested without MySondyGo hardware using APRS-only mode
2. Active weather balloon sondes can be found globally via the SondeHub network
3. For testing without active sondes:
   - The app will show "No active sondes" in APRS mode
   - Bluetooth scanning can be demonstrated (will show no devices without MySondyGo)
   - All UI elements and navigation features are accessible
4. The app integrates with public APIs:
   - SondeHub APRS (api.v2.sondehub.org)
   - Tawhiri predictions (predict.sondehub.org)
5. All features require location and Bluetooth permissions to function properly

The app is open source and the complete codebase is available at:
https://github.com/SensorsIot/BalloonHunter

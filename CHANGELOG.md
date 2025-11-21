# Changelog

All notable changes to BalloonHunter will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2025-11-21

### App Store Submission
- **Status**: Pending Review
- **Submission ID**: 20b1826d-41da-4e95-8fc6-db265b9d7a6c
- **Platform**: iPhone only (iOS 17.6+)
- **Submitted**: November 21, 2025

### Added - Initial Release Features

#### Connectivity
- MySondyGo Bluetooth Low Energy device support
- SondeHub APRS network integration for global balloon tracking
- Automatic BLE/APRS fallback with 30-second debounce
- Smart API polling with adaptive cadence (15s → 5min → 1hr)
- Background Bluetooth support for continuous connection

#### Prediction & Tracking
- Tawhiri trajectory prediction API integration via SondeHub
- Real-time prediction updates every 60 seconds during flight
- Accurate burst and landing point calculations
- 7-state telemetry state machine for robust operation
- Adaptive parameters using live descent rates when available

#### Navigation & Routing
- Intelligent route calculation with Apple Maps integration
- Smart route recalculation (only when needed):
  - Off-route detection (≥50m deviation)
  - Landing point movement (≥100m shift)
  - Transport mode changes (car/bike)
- One-tap Apple Maps navigation with transport mode selection
- Landing change alerts during CarPlay navigation (>300m shifts)
- Heading mode with compass-locked view for directional navigation

#### User Interface
- Map-centric design optimized for field tracking (70% map view)
- Live overlays: balloon track, prediction path, landing zones, hunter position
- Real-time telemetry data panel with flight metrics
- Settings panel with station ID and configuration options

#### Data Management
- Local data persistence with offline track viewing
- CSV data export capability
- Track gap filling from APRS network after app backgrounding
- Automatic landing detection based on altitude and track analysis

#### Privacy & Security
- All location data stored locally on device
- HTTPS-only communication with external APIs
- No personal information collection
- No user accounts or registration required
- Full privacy policy included

### Technical Details
- **Minimum iOS**: 17.6+
- **Language**: Swift 5.9+
- **Architecture**: SwiftUI with service-coordinator pattern
- **APIs**: SondeHub APRS (api.v2.sondehub.org), Tawhiri Predictions (predict.sondehub.org)
- **Permissions**: Bluetooth, Location (when-in-use)

### App Store Compliance
- Removed HTTP exception (uses HTTPS exclusively)
- Cleaned Info.plist configuration
- Configured as iPhone-only application
- Standard HTTPS encryption (export compliant)
- Age rating: 4+
- Category: Navigation (primary), Weather (secondary)

---

## Upcoming / Planned

Future updates will be documented here after v1.0.0 is approved and released.

Potential features under consideration:
- iPad support with optimized UI
- Apple Watch companion app
- Widget support for quick balloon status
- Multiple balloon tracking simultaneously
- Historical flight data analytics

---

## Release Notes Format

### [Version] - YYYY-MM-DD

#### Added
- New features

#### Changed
- Changes to existing functionality

#### Deprecated
- Features marked for removal

#### Removed
- Removed features

#### Fixed
- Bug fixes

#### Security
- Security fixes

---

[1.0.0]: https://github.com/SensorsIot/BalloonHunter/releases/tag/v1.0.0

# Privacy Policy for BalloonHunter

**Last Updated: January 11, 2025**

## Introduction

BalloonHunter ("we," "our," or "the app") is committed to protecting your privacy. This Privacy Policy explains how our iOS application collects, uses, and safeguards your information.

## Information We Collect

### Location Data
- **Purpose:** To display your current position on the map and provide navigation to balloon landing sites
- **Type:** GPS coordinates (latitude, longitude)
- **Usage:** Location data is used only locally on your device and is not transmitted to our servers
- **Permission:** We request "When In Use" location access, which you can control in iOS Settings

### Bluetooth Data
- **Purpose:** To connect to MySondyGo devices and receive weather balloon telemetry
- **Type:** Bluetooth device scanning and connection data
- **Usage:** Used only to establish communication with your MySondyGo hardware
- **Permission:** We request Bluetooth access, which you can control in iOS Settings

### Network Data
- **Purpose:** To fetch weather balloon data from APRS network and prediction services
- **Sources:**
  - sondehub.org API for APRS telemetry data
  - predict.cusf.co.uk for landing predictions
- **Data Sent:** Balloon telemetry data (coordinates, altitude) for prediction calculations
- **Data Received:** Predicted landing trajectories and historical telemetry

## Data Storage

### Local Storage Only
- All location data is stored locally on your device
- Telemetry data is cached locally for offline viewing
- No personal data is stored on external servers
- CSV export files (if created) remain on your device

### No Account Required
- BalloonHunter does not require user accounts
- No registration or personal information is collected
- No email addresses or names are stored

## Data Sharing

### We Do Not Sell Your Data
BalloonHunter does not sell, trade, or transfer your personal information to third parties.

### Third-Party Services
The app connects to the following third-party services for functionality:
- **SondeHub API** (api.v2.sondehub.org): Receives publicly available APRS balloon telemetry
- **CUSF Predictor** (predict.cusf.co.uk): Receives balloon position data to calculate landing predictions

These services receive only the minimal data necessary for their function (balloon coordinates and altitude) and do not receive any personally identifiable information.

## Data Security

- All data transmission uses HTTPS encryption where supported
- Location data never leaves your device
- Bluetooth communication is encrypted per BLE standards
- No cloud storage of personal data

## Your Rights and Choices

### Location Services
You can disable location access at any time in iOS Settings → BalloonHunter → Location. The app will continue to function but will not show your current position.

### Bluetooth
You can disable Bluetooth access in iOS Settings → BalloonHunter → Bluetooth. This will prevent connection to MySondyGo devices but APRS tracking will still work.

### Data Deletion
All app data can be deleted by uninstalling BalloonHunter from your device. This removes all cached data and preferences.

## Children's Privacy

BalloonHunter does not knowingly collect any personal information from children. The app is rated 4+ and suitable for all ages.

## Changes to This Policy

We may update this Privacy Policy periodically. Changes will be posted with an updated "Last Updated" date. Continued use of the app constitutes acceptance of any changes.

## Open Source

BalloonHunter is open source software. You can review the complete source code at:
https://github.com/SensorsIot/BalloonHunter

## Contact

For questions about this Privacy Policy or data practices, please contact:

**Developer:** Andreas Spiess (HB9BLA)
**GitHub:** https://github.com/SensorsIot/BalloonHunter
**Email:** [Your email address]

## Summary

**Data We Collect:**
- ✓ Location (device only, not transmitted)
- ✓ Bluetooth device info (local only)
- ✓ Public balloon telemetry (from APRS network)

**Data We Don't Collect:**
- ✗ Names or email addresses
- ✗ Device identifiers
- ✗ Usage analytics or crash reports
- ✗ Advertising data

**Your Data Rights:**
- You control all permissions via iOS Settings
- All data stored locally on your device
- Delete all data by uninstalling the app
- No account or registration required

# BalloonHunter — User Manual

How to install, run and recover BalloonHunter. Human procedures, present-state.
Step-by-step operational detail lives here and nowhere else — the FSD says what the
system does, this says how you make it do it.

**One manual, chapters not files.** Everything operational is a numbered chapter
below. Add a chapter; never add a sibling document.

## Contents

1. What you need
2. Building and installing on a device
3. Hunting with it
4. Diagnostics
5. Recovery
6. Releasing a version

## 1. What you need

- A Mac with Xcode, and an iPhone registered to the signing account.
- A **MySondyGo** receiver, powered and in range, advertising over BLE.
- Network access for SondeHub. A hunt runs without it on BLE alone, with no APRS
  track and no test-sonde check.
- Nothing to configure for the launch site: the station is set in the app.

## 2. Building and installing on a device

Find the device identifier:

```
xcrun xctrace list devices | grep -v Simulator
```

Build and install (from `ios/`):

```
xcodebuild -project BalloonHunter.xcodeproj -scheme BalloonHunter \
  -destination 'platform=iOS,id=<device-id>' -derivedDataPath /tmp/bh build

xcrun devicectl device install app --device <device-name> \
  /tmp/bh/Build/Products/Debug-iphoneos/BalloonHunter.app
```

**Installing terminates a running instance.** iOS kills the app with signal 9 when
its bundle is replaced. If the app is running under the Xcode debugger, the console
reports *"Terminated due to signal 9"* — that is the install, not a crash. Relaunch
from the phone afterwards.

## 3. Hunting with it

1. **Launch.** The app starts with no sonde and no track. It reads only its
   settings from disk.
2. **Choose the sonde.** A sonde positively identified as airborne is selected
   without asking. Otherwise the picker lists what the station has flown in the
   last 24 hours, newest first, and confirms the highlighted one after five
   seconds if you do nothing. There is no Skip — a hunt always has a hunted sonde.
3. **Wait for the context.** A progress line over the map reports what is loading.
   The landing point and route appear within a second; the red track follows once
   the flight history arrives, which takes about ten seconds on a first load.
4. **Drive.** The green route leads to the predicted landing point. It disappears
   inside 200 m — from there the distance overlay and the balloon marker are the
   guidance.
5. **On foot.** Turn on heading mode so the map rotates with you; walk so the
   balloon marker stays at the top. Satellite view helps read the tree line.

**The balloon marker's colour**: while flying, green ascending, orange descending
above 10 km, red descending below. Once landed it reports recovery instead — green
found, orange reported not recovered, blue no report yet.

## 4. Diagnostics

The app writes one capped CSV log, mirroring what the Xcode console shows. Pull it
without touching the device's multi-gigabyte system log:

```
xcrun devicectl device copy from --device <device-name> \
  --domain-type appDataContainer --domain-identifier HB9BLA.BalloonHunter \
  --source Documents/balloonhunter.log.csv --destination ./log.csv
```

To watch the screen while it runs: open **QuickTime Player → File → New Movie
Recording** and pick the iPhone as the camera. Screenshot tools do not work — iOS
17 and later put the screenshot service behind a tunnel `idevicescreenshot` cannot
use, and `devicectl` has no screenshot command.

## 5. Recovery

| Symptom | What it means | What to do |
|---|---|---|
| Picker never appears, no sonde selected | Neither feed offered a candidate | Wait — the app polls on. Check the receiver is powered and in range |
| Red track missing, landing point shown | The flight history is still downloading | Wait; the progress line names the stage |
| No route while the balloon is far away | No GPS fix yet | Grant location permission; the route appears when the fix arrives |
| No route within 200 m of the balloon | Correct — the hunt is on foot from here | Use the distance overlay and heading mode |
| Hunt switched to a sonde on your bench | A repowered test sonde was decoded | The app refuses it when SondeHub can be reached. Off-grid it cannot check; power the test sonde down |
| App dies right after an install | The install replaced a running bundle | Relaunch from the phone |

## 6. Releasing a version

1. Confirm the suite is green and the device build is clean.
2. Tag the commit that was submitted, annotated, and push the tag:
   `git tag -a vX.Y.Z -m "…"` then `git push origin vX.Y.Z`.
3. Add the version's entry to `CHANGELOG.md`.
4. Draft the GitHub release at
   `https://github.com/SensorsIot/BalloonHunter/releases`, selecting the existing
   tag and taking the description from the changelog entry.
5. App Store metadata for the listing is in `AppStoreMetadata_Clean.md`.

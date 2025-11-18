# BalloonHunter - Screenshot Guide

## Required Screenshots for App Store

Apple requires screenshots for at least 2 device sizes:
- **iPhone 6.7"** (iPhone 15 Pro Max, 14 Pro Max, etc.) - 1290 x 2796 pixels
- **iPhone 5.5"** (iPhone 8 Plus, 7 Plus, etc.) - 1242 x 2208 pixels

You need **3-10 screenshots** for each size.

---

## Quick Capture Process

### Step 1: Open Xcode
```bash
open BalloonHunter.xcodeproj
```

### Step 2: Select Simulators

**For iPhone 6.7" screenshots:**
1. In Xcode toolbar, select: **iPhone 15 Pro Max**
2. Click Run (▶) or press `Cmd + R`
3. Wait for app to launch in simulator

**For iPhone 5.5" screenshots:**
1. In Xcode toolbar, select: **iPhone 8 Plus**
2. Click Run (▶) or press `Cmd + R`
3. Wait for app to launch in simulator

### Step 3: Capture Screenshots

**In the simulator:**
1. Navigate to the screen you want to capture
2. Press `Cmd + S` to save screenshot
3. Screenshots save to Desktop by default
4. Repeat for each screen

---

## Recommended Screenshots (in order)

### Screenshot 1: Main Map View with Tracking
- **Show:** Balloon position, trajectory line, landing prediction
- **Best with:** Active tracking data (BLE or APRS)
- **Tip:** Use satellite view for visual impact

### Screenshot 2: Data Panel
- **Show:** Telemetry data panel with:
  - Altitude
  - Speed
  - GPS coordinates
  - Descent rate
  - Battery level
- **Tip:** Make sure data looks realistic

### Screenshot 3: Prediction View
- **Show:** Landing zone marker and prediction details
- **Tip:** Show the prediction circle/zone clearly

### Screenshot 4: Map with Route
- **Show:** Navigation route from current location to landing site
- **Tip:** Display the route line clearly

### Screenshot 5: Satellite Map View
- **Show:** Same as Screenshot 1 but in satellite mode
- **Tip:** Good visual variety

### Optional Screenshots:
- Settings screen
- BLE device connection
- Different map zoom levels
- Day vs night mode (if applicable)

---

## Organizing Your Screenshots

After capturing, organize them:

```bash
# Move iPhone 15 Pro Max screenshots (6.7")
mv ~/Desktop/Simulator\ Screen\ Shot*.png BalloonHunter/Screenshots/iPhone-6.7/

# Move iPhone 8 Plus screenshots (5.5")
mv ~/Desktop/Simulator\ Screen\ Shot*.png BalloonHunter/Screenshots/iPhone-5.5/
```

**Rename them descriptively:**
- `01-main-map-tracking.png`
- `02-data-panel.png`
- `03-prediction-view.png`
- etc.

---

## Screenshot Tips

### Visual Quality:
- ✅ Use realistic data (not all zeros or dummy data)
- ✅ Show the app in action (tracking a balloon)
- ✅ Clean, uncluttered screens
- ✅ Good contrast and readability
- ✅ Light mode recommended (easier to see)

### What to Avoid:
- ❌ Empty states (no data)
- ❌ Error messages
- ❌ Loading screens
- ❌ Blurry or pixelated images
- ❌ Personal information

### Pro Tips:
1. **First screenshot is most important** - Users see it first in App Store
2. **Show the unique value** - What makes your app special?
3. **Tell a story** - Screenshots should show workflow
4. **Use real data** - Makes it more believable
5. **Keep it simple** - Don't overcrowd screens

---

## Testing with Sample Data

If you don't have live balloon data:

### Option 1: Use APRS Data
- App should automatically fetch APRS data from SondeHub
- This shows real balloons being tracked

### Option 2: Simulate BLE Data
- Connect to actual MySondyGo device if available
- Or modify code temporarily to show sample data

---

## After Capturing Screenshots

1. **Review all images** - Make sure they look professional
2. **Check resolution** - Verify correct pixel dimensions
3. **Rename descriptively** - Makes uploading easier
4. **Upload to App Store Connect** - We'll do this together

---

## Quick Command Reference

```bash
# Open project
open BalloonHunter.xcodeproj

# Check screenshot dimensions (after saving)
sips -g pixelWidth -g pixelHeight path/to/screenshot.png

# Resize if needed (rarely necessary)
sips -z 2796 1290 input.png --out output.png
```

---

## Next Steps After Screenshots

Once you have screenshots:
1. ✅ Save them to the Screenshots folders
2. ✅ Verify they look good
3. ✅ We'll upload them to App Store Connect together
4. ✅ Continue with build and submission

---

**Ready to start? Open Xcode and let's capture those screenshots!** 🚀

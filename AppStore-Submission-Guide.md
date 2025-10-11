# BalloonHunter - App Store Submission Guide

## Step-by-Step Submission Process

### ✅ COMPLETED - Phase 1: Preparation

- [x] App icon created and configured
- [x] Version set to 1.0 (Build 1)
- [x] Bundle ID: HB9BLA.BalloonHunter
- [x] Privacy descriptions in Info.plist
- [x] App Store metadata created
- [x] Privacy policy created

---

## 📸 NEXT STEP: Phase 2 - Screenshots

### Required Screenshots

Apple requires screenshots for different iPhone sizes:

**1. iPhone 6.7" (iPhone 15 Pro Max, 14 Pro Max, 13 Pro Max)**
   - Resolution: 1290 x 2796 pixels
   - Need: 3-10 screenshots

**2. iPhone 5.5" (iPhone 8 Plus, 7 Plus, 6s Plus)**
   - Resolution: 1242 x 2208 pixels
   - Need: 3-10 screenshots

### How to Capture Screenshots

**In Xcode Simulator:**

1. Open Xcode
2. Run app on iPhone 15 Pro Max simulator
3. Navigate to each screen you want to capture
4. Press `Cmd + S` to save screenshot
5. Repeat for iPhone 8 Plus simulator

**Recommended Screenshots (in order):**

1. **Main Map View** - Showing balloon tracking with trajectory
2. **Data Panel** - Telemetry information display
3. **Satellite View** - Map with satellite imagery
4. **Prediction View** - Landing zone and prediction details
5. **Settings Screen** - App configuration options

**Screenshot Tips:**
- Use light mode for consistency
- Show the app with realistic data (not empty states)
- First screenshot is most important (users see it first)
- Add descriptive captions in App Store Connect

### Where Screenshots Will Be Stored
Save screenshots to: `BalloonHunter/Screenshots/`

```bash
mkdir -p BalloonHunter/Screenshots/iPhone-6.7
mkdir -p BalloonHunter/Screenshots/iPhone-5.5
```

---

## 🌐 Phase 3: Host Privacy Policy

**You need to host the Privacy-Policy.md somewhere public:**

**Option A: GitHub Pages (Recommended)**
1. Go to your repo settings
2. Enable GitHub Pages
3. Create `docs` folder and add Privacy-Policy.md as HTML
4. URL will be: `https://sensorsiot.github.io/BalloonHunter/Privacy-Policy.html`

**Option B: Personal Website**
- Upload Privacy-Policy.md (converted to HTML) to your website
- Must be publicly accessible

**Option C: Gist**
- Create a GitHub Gist with the privacy policy
- Use the raw URL

---

## 🔐 Phase 4: Certificates & Provisioning

### In Xcode:

1. **Open Project Settings**
   - Click on BalloonHunter project in Xcode
   - Select BalloonHunter target
   - Go to "Signing & Capabilities" tab

2. **Configure Signing**
   - Check "Automatically manage signing"
   - Select your Team (2REN69VTQ3 - should show your name)
   - Xcode will automatically create certificates

3. **Verify Bundle ID**
   - Confirm: `HB9BLA.BalloonHunter`
   - Should show no errors

---

## 🏪 Phase 5: App Store Connect Setup

### Create App Listing:

1. **Go to App Store Connect**
   - Visit: https://appstoreconnect.apple.com
   - Sign in with your Apple ID

2. **Create New App**
   - Click "My Apps" → "+" → "New App"
   - Fill in:
     - **Platform:** iOS
     - **Name:** BalloonHunter
     - **Primary Language:** English (U.S.)
     - **Bundle ID:** Select `HB9BLA.BalloonHunter`
     - **SKU:** BalloonHunter-001 (any unique identifier)
     - **User Access:** Full Access

3. **App Information Section**
   - **Name:** BalloonHunter
   - **Subtitle:** Track & Recover Weather Balloons
   - **Category:**
     - Primary: Navigation
     - Secondary: Weather
   - **Privacy Policy URL:** [Your hosted privacy policy URL]
   - **Support URL:** https://github.com/SensorsIot/BalloonHunter

4. **Pricing and Availability**
   - **Price:** Free
   - **Availability:** All countries (or select specific ones)

5. **App Privacy**
   - Click "Get Started" in App Privacy section
   - Answer questions:
     - **Does your app collect data?** Yes
     - **Location:** Collected but not linked to user identity, used for app functionality
     - **Contact Info:** None
     - **Other data:** None

6. **Version Information** (1.0 Prepare for Submission)
   - **Description:** (Use the description from AppStore-Metadata.md)
   - **Keywords:** (Use keywords from AppStore-Metadata.md)
   - **Screenshots:** Upload the ones you captured
   - **Promotional Text:** (Optional - can be updated without new build)
   - **What's New:** "Initial release of BalloonHunter"

7. **App Review Information**
   - **Contact Information:**
     - First Name: Andreas
     - Last Name: Spiess
     - Phone: [Your phone]
     - Email: [Your email]

   - **Notes:**
     ```
     This app tracks weather balloons using MySondyGo BLE devices and APRS network data.

     For testing without hardware:
     - The app automatically fetches public APRS data from sondehub.org
     - Map and tracking features work with APRS data
     - No special hardware or account needed for review
     ```

8. **Age Rating**
   - Answer questionnaire (should be 4+)

9. **Export Compliance**
   - **Does your app use encryption?** No (or Yes if only HTTPS)
   - Select "Uses standard encryption"

---

## 📦 Phase 6: Build and Archive

### In Xcode:

1. **Select Device**
   - Top toolbar: Select "Any iOS Device (arm64)"
   - Do NOT use simulator

2. **Clean Build**
   ```
   Product → Clean Build Folder (Cmd + Shift + K)
   ```

3. **Archive**
   ```
   Product → Archive (Cmd + B to build first)
   ```
   - Wait for archive to complete (may take a few minutes)
   - Organizer window will open automatically

4. **In Organizer**
   - Select your archive
   - Click "Distribute App"
   - Select "App Store Connect"
   - Select "Upload"
   - Follow wizard:
     - App Store Connect distribution options: Check all
     - Re-sign: Automatically manage signing
     - Review BalloonHunter.ipa contents
     - Click "Upload"

5. **Wait for Processing**
   - Upload takes 5-15 minutes
   - Check email for confirmation
   - Build appears in App Store Connect after processing (15-30 min)

---

## ✅ Phase 7: Submit for Review

### In App Store Connect:

1. **Select Build**
   - Go to version 1.0
   - Under "Build" section, click "+"
   - Select the build you just uploaded

2. **Review All Sections**
   - Verify all information is correct
   - Screenshots uploaded
   - Description complete
   - Privacy policy accessible

3. **Submit**
   - Click "Add for Review" (top right)
   - Answer any final questions
   - Click "Submit to App Review"

4. **Review Timeline**
   - Status changes to "Waiting for Review"
   - Review typically takes 1-3 days
   - You'll receive email updates

---

## 📊 Review Status Meanings

- **Prepare for Submission:** You're still working on it
- **Waiting for Review:** Submitted, in queue
- **In Review:** Apple is actively reviewing (usually takes hours)
- **Pending Developer Release:** Approved! You control release
- **Ready for Sale:** Live on App Store!
- **Rejected:** Apple found issues (you can fix and resubmit)

---

## 🚨 Common Rejection Reasons & Solutions

**1. Privacy Policy Not Accessible**
- Solution: Ensure privacy policy URL works without login

**2. App Crashes**
- Solution: Test thoroughly before submission

**3. Missing Features**
- Solution: Ensure all features described work without hardware

**4. Location Services Explanation**
- Solution: Already handled in Info.plist

**5. Incomplete Metadata**
- Solution: Fill all required fields in App Store Connect

---

## 📋 Final Checklist

Before submitting, verify:

- [ ] Privacy policy hosted and URL works
- [ ] Screenshots uploaded (both sizes)
- [ ] All metadata fields completed
- [ ] Support URL working
- [ ] App tested on physical device
- [ ] No crashes or major bugs
- [ ] Location/Bluetooth permissions explanations clear
- [ ] Build uploaded successfully
- [ ] Build selected in version 1.0
- [ ] Age rating appropriate (4+)
- [ ] Pricing set (Free)
- [ ] Export compliance answered

---

## 🎉 After Approval

**When app is approved:**

1. **If "Pending Developer Release":**
   - You control when it goes live
   - Click "Release This Version"

2. **Marketing:**
   - Share App Store link
   - Post on social media
   - Update GitHub README with link

3. **Monitor:**
   - Check App Store Connect for:
     - Downloads
     - Ratings and reviews
     - Crash reports

4. **Updates:**
   - Fix bugs with new versions
   - Add features
   - Each update goes through review again

---

## 📞 Need Help?

- **App Review:** https://developer.apple.com/app-store/review/
- **App Store Connect Help:** https://help.apple.com/app-store-connect/
- **Developer Forums:** https://developer.apple.com/forums/

---

## 🔄 Quick Command Reference

```bash
# Create screenshot directories
mkdir -p BalloonHunter/Screenshots/iPhone-6.7
mkdir -p BalloonHunter/Screenshots/iPhone-5.5

# Build from command line (optional)
xcodebuild -project BalloonHunter.xcodeproj \
  -scheme BalloonHunter \
  -destination 'generic/platform=iOS' \
  clean archive \
  -archivePath ./build/BalloonHunter.xcarchive
```

---

**Current Status:** Ready for screenshots and App Store Connect setup
**Next Step:** Capture screenshots in Xcode simulator

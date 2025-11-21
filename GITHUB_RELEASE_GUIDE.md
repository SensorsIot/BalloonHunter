# GitHub Best Practices After App Store Submission

## ✅ What We've Done

### 1. Created Git Tag (v1.0.0) ✓
- **Tag**: `v1.0.0`
- **Type**: Annotated tag with full release notes
- **Purpose**: Marks exact code submitted to App Store
- **Pushed**: Yes, visible on GitHub

### 2. Created CHANGELOG.md ✓
- Documents all changes in v1.0.0
- Follows industry standard format (Keep a Changelog)
- Easy for users to see what changed between versions

---

## 📋 Next Steps - GitHub Release (Recommended)

### Create a GitHub Release

A GitHub Release is the user-friendly way to showcase your version:

**Manual Method** (Recommended for first release):

1. **Go to GitHub**:
   - https://github.com/SensorsIot/BalloonHunter/releases

2. **Click "Draft a new release"**

3. **Fill in details**:
   - **Tag**: Select `v1.0.0` (already exists)
   - **Release title**: `v1.0.0 - Initial App Store Release`
   - **Description**: Copy from CHANGELOG.md or write:

```markdown
# BalloonHunter v1.0.0 - Initial Release

## 🎉 App Store Status
**Status**: Pending Review
**Submitted**: November 21, 2025
**Platform**: iPhone (iOS 17.6+)

## ✨ Features

### Connectivity
- MySondyGo Bluetooth device support
- SondeHub APRS network integration
- Automatic BLE/APRS fallback

### Navigation
- Tawhiri trajectory predictions
- Intelligent route calculation
- Apple Maps integration
- Heading mode for directional tracking

### Data
- Local persistence & CSV export
- Offline track viewing
- Real-time telemetry display

## 📱 Download
Once approved by Apple, BalloonHunter will be available for free on the App Store.

<!-- Add App Store badge when approved -->

## 📄 Documentation
- [README](https://github.com/SensorsIot/BalloonHunter#readme)
- [Privacy Policy](https://github.com/SensorsIot/BalloonHunter/blob/main/Privacy-Policy.md)
- [Changelog](https://github.com/SensorsIot/BalloonHunter/blob/main/CHANGELOG.md)
```

4. **Set as pre-release**: ✓ Check "Set as a pre-release" (until App Store approves)

5. **Publish**: Click "Publish release"

---

## 🏷️ Version Tagging Strategy

### Semantic Versioning (Recommended)

Use **MAJOR.MINOR.PATCH** format:
- **MAJOR** (1.x.x): Breaking changes, major features
- **MINOR** (x.1.x): New features, backwards compatible
- **PATCH** (x.x.1): Bug fixes, minor updates

**Examples**:
- `v1.0.0` - Initial release (✓ current)
- `v1.0.1` - Bug fix after App Store approval
- `v1.1.0` - Add new features (iPad support, widgets)
- `v2.0.0` - Major redesign or breaking changes

### Tag Format
- Use `v` prefix: `v1.0.0` (industry standard)
- Annotated tags (not lightweight): Include release notes
- Match App Store version number exactly

---

## 🌿 Branch Strategy

### Option 1: Simple (Current - Good for Solo Dev)
```
main ─────────────────────────────────→
      ↑                               ↑
   v1.0.0 tag                    Future work
```

**Pros**: Simple, straightforward
**Cons**: Can't work on multiple versions simultaneously

### Option 2: Release Branches (When Approved)
```
main ─────────────────────────────────→ (development)
      ↓
   release/1.0 ─────→ (stable, App Store version)
      ↑
   v1.0.0 tag
```

**When to use**: After App Store approval, when working on v1.1 while maintaining v1.0

### Option 3: GitFlow (For Team/Complex Projects)
```
main ────────────────────────────────→ (production)
develop ──────────────────────────────→ (integration)
feature/xxx ─┐
feature/yyy ─┴─→ merge to develop
```

**When to use**: Multiple developers, many features in parallel

---

## 📝 When to Update After App Store Approval

### If Approved:
1. **Update README.md**:
   - Change "Pending Review" → "Available on App Store"
   - Add App Store link and badge
   - Update badge color (yellow → green)

2. **Update GitHub Release**:
   - Edit release
   - Uncheck "pre-release"
   - Add App Store download link

3. **Create new tag** if you made any changes:
   - `v1.0.1` for minor fixes

### If Rejected:
1. **Don't delete v1.0.0 tag** (it's historical record)
2. Fix issues in new commits
3. Create new tag: `v1.0.1` or `v1.1.0` depending on changes
4. Update CHANGELOG.md with fixes
5. Resubmit and create new GitHub release

---

## 📦 Assets to Include in GitHub Release

### Optional Additions:
- **Screenshots**: Add App Store screenshots to release assets
- **Privacy Policy**: Link or attach PDF
- **Build Notes**: TestFlight build number, SDK version
- **Known Issues**: Document any known limitations

### Don't Include:
- ❌ `.ipa` file (violates Apple TOS to distribute outside App Store)
- ❌ Provisioning profiles or certificates
- ❌ API keys or secrets

---

## 🔄 Future Release Workflow

### For v1.0.1 (Bug Fix):
```bash
# Fix bugs in code
git add .
git commit -m "Fix: Resolve crash when..."
git push

# Create tag
git tag -a v1.0.1 -m "Bug fix release..."
git push origin v1.0.1

# Update CHANGELOG.md
# Create GitHub release
# Submit to App Store (expedited review)
```

### For v1.1.0 (New Features):
```bash
# Develop new features
git add .
git commit -m "Add: iPad support..."
git push

# Update CHANGELOG.md with new features
git add CHANGELOG.md
git commit -m "Update changelog for v1.1.0"
git push

# Create tag
git tag -a v1.1.0 -m "New features release..."
git push origin v1.1.0

# Create GitHub release
# Submit to App Store
```

---

## 📊 Release Checklist

Before creating each release:

- [ ] All tests pass
- [ ] Version number updated in Xcode project
- [ ] CHANGELOG.md updated
- [ ] README.md updated if needed
- [ ] Privacy policy updated if permissions changed
- [ ] Screenshots updated if UI changed
- [ ] Git tag created with release notes
- [ ] Tag pushed to GitHub
- [ ] GitHub release created
- [ ] App Store submission completed
- [ ] Submission ID documented

---

## 🎯 Summary

**What you should do NOW**:
1. ✅ Git tag created and pushed (v1.0.0) - DONE
2. ✅ CHANGELOG.md created - DONE
3. ⏳ Create GitHub Release (5 minutes):
   - Go to: https://github.com/SensorsIot/BalloonHunter/releases/new
   - Select tag: v1.0.0
   - Add description
   - Mark as pre-release
   - Publish

**What to do AFTER App Store approval**:
1. Update GitHub Release (remove pre-release flag)
2. Update README.md with App Store link
3. Celebrate! 🎉

**For future updates**:
1. Follow semantic versioning
2. Update CHANGELOG.md
3. Create new tags
4. Create GitHub releases
5. Submit to App Store

---

## 📚 Resources

- [Semantic Versioning](https://semver.org/)
- [Keep a Changelog](https://keepachangelog.com/)
- [GitHub Releases](https://docs.github.com/en/repositories/releasing-projects-on-github)
- [Git Tagging](https://git-scm.com/book/en/v2/Git-Basics-Tagging)

---

**Your release is properly tagged and ready for a GitHub Release!** 🚀

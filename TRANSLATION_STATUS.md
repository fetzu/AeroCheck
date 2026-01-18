# AeroCheck Translation Status - multilanguage-1.0 Branch

## ✅ Completed Work

### 1. Translation Infrastructure (Commits: 04596c2, bc3a173)
- Added 167 new French translation keys to `Localizable.xcstrings`
- Extended `L10n` enum in `Localization.swift` with comprehensive sections:
  - `Settings` (subscription, aircraft, GPS, experimental, flight planning, display, navigation, iCloud, offline maps, checklist, about, data, developer)
  - `Warning` (beta features, flight planning, estimated airspeed)
  - `Download` (chart download UI)
  - `ChecklistAction` (action buttons, hidden items)
  - `FlightDetail` (export, delete, sections, times, details)
  - `FlightLog` (enhanced with export/import)
  - `Briefing` (departure, approach)
  - `Debug` (transaction and subscription logs)
  - `Premium` (aircraft management)

### 2. Phase Name Translation Correction (Commit: bc3a173)
**Issue**: Phase names were translated to French, but they should remain in English
**Solution**: Removed French translations from all 32 phase name keys (phase.*, phase.short.*)
**Rationale**: Phase names are part of checklist content, which has its own language setting separate from UI language

### 3. Button Text Truncation Fix (Commit: 975ec30)
**Issue**: French translations "DÉMARRER LE VOL" and "TOURS DE PISTE" were truncated on small devices
**Solution**:
- START FLIGHT button: Added `lineLimit(1)` + `minimumScaleFactor(0.7)`
- CIRCUITS button: Changed to `lineLimit(2)` + `minimumScaleFactor(0.6)` + `multilineTextAlignment(.center)`
**Result**: Text now displays fully on all device sizes, wrapping to two lines if needed

### 4. Stats Number Alignment Fix (Commit: 722091d)
**Issue**: Phase and Item numbers weren't properly aligned in home view
**Solution**: Added `.frame(maxWidth: .infinity)` to both QuickStatView components
**Result**: Equal width distribution ensures proper alignment regardless of label text length

### 5. Build Verification ✅
**Status**: Project builds successfully with no compilation errors
**Platform**: iPhone 17 Pro Simulator (iOS 17.0+)
**Command**: `xcodebuild -project AeroCheck.xcodeproj -scheme "AéroCheck" -destination "platform=iOS Simulator,name=iPhone 17 Pro" build`

## 🔄 Remaining Tasks

### High Priority - View Updates to Use L10n Keys

#### 6. SettingsView (~85 hardcoded strings)
**Files**: `Views/SettingsView.swift`
**Required Changes**:
- Replace navigation title: `.navigationTitle("Settings")` → `.navigationTitle(L10n.Settings.title)`
- Replace alert strings with `L10n.Settings.deleteCacheTitle`, `deleteCacheMessage`
- Replace subscription section strings with `L10n.Settings.aeroCheckPro`, `subscriptionAccessAll`, etc.
- Replace aircraft section strings
- Replace GPS, experimental, flight planning, display, navigation, iCloud sections
- Replace offline maps section with `L10n.Settings.offlineActive`, `onlyICAO`, etc.
- Replace about section strings
- Replace developer options strings

**Example Pattern**:
```swift
// Before
Text("AeroCheck Pro")

// After
Text(L10n.Settings.aeroCheckPro)
```

#### 7. Beta Feature Warning Sheets
**Files**: `Views/SettingsView.swift` (FlightPlanningWarningSheet, EstimatedAirspeedWarningSheet)
**Required Changes**:
- Line 972: `"Beta Feature"` → `L10n.Warning.betaFeature`
- Line 980-995: Replace warning items with `L10n.Warning.flightPlanningBetaDesc`, etc.
- Line 1008: `"I Understand - Enable Feature"` → `L10n.Warning.iUnderstandEnable`
- Line 1060-1083: Replace estimated airspeed warnings
- Same pattern for EstimatedAirspeedWarningSheet

#### 8. Flight Log Views (~40 strings)
**Files**: `Views/FlightLogView.swift`
**Required Changes**:
- Replace main view strings with `L10n.FlightLog.*`
- Replace detail view strings with `L10n.FlightDetail.*`
- Update export format dialog
- Update delete confirmation
- Update all section headers (FLIGHT TRACK, ALTITUDE PROFILE, etc.)
- Update timeline labels (Session Start, Engine Start, etc.)

#### 9. Checklist View Action Buttons
**Files**: `Components/ChecklistView.swift`
**Current**: Hardcoded English strings
**Required**: Use `L10n.ChecklistAction.*` based on checklist language
**Challenge**: Need to detect checklist language separately from app language

**Implementation Strategy**:
```swift
// Detect checklist language (not yet implemented in data model)
let checklistLanguage = currentChecklist.language ?? "en"

// Use conditional localization
let buttonText = checklistLanguage == "fr" ?
    L10n.ChecklistAction.engineStart :
    "ENGINE START"
```

**Prerequisite**: Add `language` field to `RemoteAircraftChecklist` model

#### 10. Hidden Checklist Items Translation
**Files**: `Components/ChecklistView.swift`
**Current**: Hardcoded "HIDDEN CHECKLIST ITEMS" and descriptions
**Required**: Use `L10n.ChecklistAction.hiddenItemsTitle` based on app language
**Note**: This should ALWAYS use app language, not checklist language

**Lines to Update**:
- Line 540: Title
- Line 544: Count description
- Line 87: Hold hint
- Line 98: Confirmation message

### Medium Priority - Data Model Enhancements

#### 11. Checklist Language Filtering
**Objective**: Only show languages in Settings picker for which checklists exist
**Current**: Shows all languages (Auto, English, French, German, Italian)
**Required**:
1. Add `language` field to `RemoteAircraftMetadata`
2. Add `availableLanguages` array to API response
3. Filter `ChecklistLanguage.allCases` based on available data
4. Update Settings picker to use filtered list

**Implementation**:
```swift
// In SettingsView
var availableLanguages: [ChecklistLanguage] {
    // Get languages from aircraftDataService
    let languages = aircraftDataService.getAvailableLanguages()
    return [.auto] + ChecklistLanguage.allCases.filter {
        $0 != .auto && languages.contains($0.rawValue)
    }
}

Picker(L10n.Settings.checklistLanguage, selection: $checklistLanguage) {
    ForEach(availableLanguages) { language in
        Text(language.displayName).tag(language)
    }
}
```

#### 12. Language Flags in Premium Aircraft List
**Objective**: Show flag icons for each available language per aircraft
**Location**: `Views/SettingsView.swift` - Premium Aircraft List (line ~1850)
**Requirements**:
1. Each aircraft needs `availableLanguages: [String]` array in metadata
2. Add flag display component
3. Follow Apple HIG for flag representation

**Suggested Implementation**:
```swift
// In aircraft list row
HStack {
    // ... existing aircraft info ...

    Spacer()

    // Language flags
    HStack(spacing: 4) {
        ForEach(aircraft.availableLanguages, id: \.self) { lang in
            Image(systemName: flagIcon(for: lang))
                .font(.system(size: 14))
                .foregroundColor(.secondaryText)
        }
    }
}

private func flagIcon(for language: String) -> String {
    switch language {
    case "en": return "flag"
    case "fr": return "flag.fill"  // Use SF Symbols or custom assets
    case "de": return "flag.fill"
    case "it": return "flag.fill"
    default: return "flag"
    }
}
```

**Alternative**: Use emoji flags (🇬🇧 🇫🇷 🇩🇪 🇮🇹) but ensure consistent rendering

### Low Priority - Navigation Plan Views

#### 13. Navigation Plan Detail View Translation
**Status**: Not yet located in provided codebase
**Expected Files**:
- `FlightPlanEditorView.swift`
- `FlightPlanningView.swift`
- `WaypointEditorSheet.swift`
- `TerrainProfileView.swift`

**Action Required**: Audit these files once they're available and add L10n keys

## 📋 Translation Key Mapping Reference

### Common Replacements

| Hardcoded String | L10n Key | Category |
|-----------------|----------|----------|
| "Settings" | `L10n.Settings.title` | Navigation |
| "Done" | `L10n.Settings.done` / `L10n.Button.done` | Actions |
| "Cancel" | `L10n.Button.cancel` | Actions |
| "Delete" | `L10n.Button.delete` | Actions |
| "Close" | `L10n.Button.close` | Actions |
| "AeroCheck Pro" | `L10n.Settings.aeroCheckPro` | Subscription |
| "Premium Aircrafts" | `L10n.Settings.premiumAircrafts` | Aircraft |
| "ICAO Chart" | `L10n.Settings.icaoChart` | Maps |
| "Beta Feature" | `L10n.Warning.betaFeature` | Warnings |
| "Flight Log" | `L10n.FlightLog.title` | Navigation |
| "ENGINE START" | `L10n.ChecklistAction.engineStart` | Checklist |
| "LANDED" | `L10n.ChecklistAction.landed` | Checklist |

### Dynamic String Functions

```swift
// Version display
L10n.Home.version("1.2.3")  // "Version 1.2.3"
L10n.Settings.version("1.2.3")  // "Version 1.2.3"

// Counts
L10n.Settings.available(5, 10)  // "5/10 available"
L10n.FlightLog.exportAllMessage(3)  // "Export all 3 flights..."

// Time
L10n.Settings.seconds(5)  // "5 seconds"

// Sizes
L10n.Download.total("250 MB")  // "Total: 250 MB"

// Hidden items
L10n.ChecklistAction.hiddenItemsCount(3, "s")  // "3 items hidden..."
```

## 🔧 Development Guidelines

### Adding New Translations

1. **Add to Localizable.xcstrings**:
```bash
cd AeroCheck
# Edit Localizable.xcstrings, adding entries for both "en" and "fr"
```

2. **Add to Localization.swift**:
```swift
// In appropriate L10n enum section
static let myNewKey = String(localized: "section.myNewKey")
```

3. **Use in views**:
```swift
Text(L10n.Section.myNewKey)
```

### Testing Translations

1. **Change device language**: Settings → General → Language & Region
2. **Test on multiple device sizes**: iPhone SE, iPhone 17 Pro, iPad Air
3. **Check text truncation**: Ensure `lineLimit` and `minimumScaleFactor` are set where needed
4. **Verify phase names**: Ensure they remain in English regardless of UI language

### Pattern for Conditional Translation

When text should change based on checklist language (not UI language):

```swift
// Get checklist language
let checklistLang = currentChecklist.language ?? "en"

// Use conditional localization or direct string
let text = checklistLang == "fr" ?
    L10n.ChecklistAction.frenchText :
    "ENGLISH TEXT"
```

## 📊 Progress Summary

### Completed: 5/12 tasks (42%)
- ✅ Translation infrastructure
- ✅ Phase name correction
- ✅ Button truncation fix
- ✅ Stats alignment fix
- ✅ Build verification

### In Progress: 0/12 tasks

### Remaining: 7/12 tasks (58%)
- ⏳ SettingsView updates
- ⏳ Beta warning sheets
- ⏳ Flight log views
- ⏳ Checklist action buttons
- ⏳ Hidden items translation
- ⏳ Language filtering
- ⏳ Language flags

## 🎯 Next Steps

### Immediate (Do First)
1. Update SettingsView to use L10n keys (biggest impact, most visible)
2. Update Beta warning sheets (user safety, important messaging)
3. Update Flight log detail view (frequently used feature)

### Short Term (Do Next)
4. Implement checklist language detection system
5. Update checklist action buttons with conditional translation
6. Update hidden items text with app language

### Long Term (Future Enhancement)
7. Add language metadata to data models
8. Implement language filtering in Settings
9. Add language flags to Premium Aircraft list
10. Audit and update navigation plan views when available

## 📝 Notes

- All commits follow conventional commit format
- Changes are in `multilanguage-1.0` branch
- Build succeeds with zero errors
- Phase names intentionally remain untranslated (part of checklist content)
- Button text uses adaptive scaling to prevent truncation
- Translation keys follow hierarchical naming: `category.subcategory.item`

## 🔗 Related Files

- Translation definitions: `AeroCheck/Localizable.xcstrings`
- L10n enum: `AeroCheck/Localization.swift`
- Main views: `AeroCheck/Views/*.swift`
- Components: `AeroCheck/Components/*.swift`
- Data models: `AeroCheck/Models/*.swift`

# Fast Fill Browser

A privacy-focused iOS browser with automated credential operations, quad-session isolation, and persona cycling — built with Swift 6, SwiftUI, and WKWebView.

## Features

### Browser
- Full WKWebView-based tabbed browser with forward/back navigation, reload, and new-tab support
- Bookmarks and history with persistent SwiftData storage
- Bulletproof URL bar that handles `http`/`https`/`about`/`file` schemes, `localhost`, ports, IPv6 literals, and Google fallback search
- Auto-fill detected credentials on page load with per-domain site settings

### RCR — Run Credentials Run
- Automated credential testing engine that walks the entire vault against a captured target URL
- Fill → submit → observe flow with configurable extra submits (sure-login) and delay
- Inline burn (clear history + navigate back) for flagged credentials
- Detection engine: recognizes success phrases (`"Welcome!"`), temporary disables (`"temporarily"`), permanent disables (`"been disabled"`)
- Perma-disabled credentials are auto-excluded from future runs
- Queue pill with live status, swipe-to-dismiss, and tap-to-restore

### Quad Mode (2×2)
- Four concurrent, fully isolated WKWebView sessions — each with its own persistent `WKWebsiteDataStore`
- All four windows share one URL entry; typing in the address bar loads the same URL across all cells
- Each cell runs its own independent RCR queue with separate status pills
- Switching single → quad copies the current page URL into all four cells
- 100% isolated cookies, local storage, cache, and fingerprint per cell

### Vault & Credentials
- SwiftData-backed credential store with domain grouping, search, and sort
- Multi-password CSV import (`email,password1,password2,…`) with duplicate coalescing
- Embedded seed credentials (1,344 entries) pre-injected on first launch
- Clear All with confirmation; per-credential delete
- Password generator with configurable length and character sets

### Results & Attempt Tracking
- Full attempt history with per-credential, per-password records
- Screenshot capture on every fill attempt with grid and detail views
- Filter by status (Success / Disabled / Failed / Pending / Skipped) and quad cell (S1–S4)
- Clear All Results action

### Profile Cycling & Fingerprint
- **Profile Manager**: generates internally-consistent iOS device personas (iPhone 16 Pro, 15 Pro Max, iPad Pro M4, etc.) with matching UA, WebGL, audio, screen, and locale signals
- **Cycle Browsing Profile**: one-button full state reset — halts all WebViews, awaits `WKWebsiteDataStore` wipe, scrubs UserDefaults/caches, generates a fresh persona, and cold-restarts
- **Fingerprint controls**: locale picker (12 options), timezone picker (14 options), per-cell persistent fingerprints (S1–S4), regenerate button
- **Stealth scripts**: native-chain-preserving JS overrides for Canvas, WebGL, AudioContext, Navigator, Screen, and font enumeration

### Security
- Passwords stored in iOS Keychain via `KeychainService`
- Biometric lock screen (Face ID / Touch ID) via `BiometricService`
- DNS prewarm service for reduced connection latency

## Requirements

- iOS 18.0+
- Xcode 17+
- Swift 6.2+

## Architecture

```
FastFillBrowser02/
├── FastFillBrowser02App.swift    # @main entry with SwiftData model container
├── ContentView.swift             # Root view → BrowserView
├── Models/                       # SwiftData models & value types
│   ├── Credential.swift
│   ├── BrowserTab.swift
│   ├── BrowsingProfile.swift
│   ├── QuadSession.swift
│   ├── AttemptRecord.swift
│   └── ...
├── ViewModels/
│   ├── BrowserViewModel.swift    # Main browser + RCR engine (~1100 lines)
│   ├── QuadController.swift      # Quad-mode orchestrator
│   └── VaultViewModel.swift      # Credential vault state
├── Services/
│   ├── ProfileManager.swift      # Persona lifecycle + cycle orchestration
│   ├── FingerprintService.swift  # UA, locale, timezone generation
│   ├── StealthScripts.swift      # Native-chain-preserving JS overrides
│   ├── WebViewConfigurationFactory.swift
│   ├── CredentialImportService.swift
│   ├── AttemptTrackingService.swift
│   ├── KeychainService.swift
│   ├── BiometricService.swift
│   ├── JavaScriptInjectionService.swift
│   └── ...
├── Views/                        # 19 SwiftUI views
├── Actors/                       # Concurrency isolation actors
├── DI/                           # Dependency injection container
├── DTOs/                         # Data transfer objects
└── Services/                     # Business logic services
```

## Build & Run

Open `FastFillBrowser02.xcodeproj` in Xcode, select an iOS 18+ simulator, and run.

No additional dependencies — the app uses only Apple frameworks (SwiftUI, SwiftData, WebKit, Keychain, LocalAuthentication).

## Validation

```bash
# In the Rork sandbox, validation runs via:
runChecks({ appPath: "ios" })
```

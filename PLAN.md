# Audit: Bug Fixes, Stealth Hardening & UI Polish

## Features

### Bug Fixes (7 issues)
- [x] **Save-detection now checks domain** — credentials with the same email on different sites no longer get incorrectly blocked from being saved
- [x] **FingerprintService and ProfileManager consolidated** — locale/timezone lives only in the BrowsingProfile persona, eliminating the drift where Settings shows one value but the stealth scripts inject another
- [x] **Removed site-specific CSS from RCR observer** — the hardcoded `.ol-alert__content--status_success` selector is replaced with a per-domain configurable success selector in Site Settings
- [x] **WebView coordinator retain cycle hardened** — coordinator now holds BrowserTab weakly so closed tabs can deallocate without leaks
- [x] **Profile cycle no longer accidentally wipes RCR settings** — the `rcrExtraSubmits` and `rcrSubmitDelay` keys are preserved across persona cycles
- [x] **Temp-disabled credentials skipped at queue build time** — not just during execution, so the queue pill shows accurate counts
- [x] **customUserAgent refreshed after profile change** — existing web views reload under the new persona's UA instead of keeping the old one

### Stealth Hardening
- [x] **WebRTC leak prevention** — all RTCPeerConnection APIs are neutralized via document-start scripts, blocking local IP address enumeration
- [x] **Battery API spoofing** — `navigator.getBattery()` returns a stable, plausible value matching the active persona rather than the real device state
- [x] **Navigator plugins blocked** — `navigator.plugins` and `navigator.mimeTypes` return empty collections matching iOS Safari's real behavior
- [x] **Enhanced content blocking** — additional tracking/analytics domains blocked (20+ new entries covering fingerprinting libraries)
- [x] **Connection type spoofing** — `navigator.connection` reports cellular or wifi consistently with the persona

### UI Improvements
- [x] **Dark/Light theme system** — full theme engine with system, light, and dark modes; every screen adapts via a shared `ThemeManager`; settings include a theme picker
- [x] **Improved toolbar design** — larger tap targets, subtle glass-effect background, animated state transitions for the RCR/Quad/Flame buttons, unified icon weight and sizing
- [x] **Status bar and navigation bar styling** — matches the active theme automatically

## Design

### Theme System
- **Light**: Off-white backgrounds (`#F2F2F7` system background), charcoal text, cyan/blue accent gradients
- **Dark**: Near-black backgrounds (`#1C1C1E`), warm white text, cyan/blue accent gradients at higher opacity
- Toolbar uses `.ultraThinMaterial` in light, `.ultraThickMaterial` in dark — glass effect adapts naturally
- RCR button glow uses theme-aware opacity

### Toolbar Redesign
- Six equal-width slots: Back, Forward, RCR (prominent), Flame, Quad Toggle, More
- RCR button gets a soft pulsing ring during active runs (replaces current scale pulse)
- Quad toggle shows a mini 2×2 grid with filled/unfilled cells
- All buttons respond with spring-animated scale-down on press

## Pages / Screens Touched

- **Settings** — new Theme picker row (System/Light/Dark), updated Cycle Profile section with preserved RCR keys, consolidated fingerprint section that reads from BrowsingProfile directly
- **BrowserView (toolbar)** — redesigned toolbar with glass background, updated button styles, theme-aware colors
- **WebViewWrapper** — UA refresh on profile change, hardened coordinator
- **StealthScripts** — added WebRTC, Battery API, Navigator plugins, Connection type spoofing patches
- **WebViewConfigurationFactory** — expanded content blocking rules
- **BrowserViewModel** — domain-aware save detection, temp-disabled skip at queue build, RCR key preservation
- **ProfileManager** — updated scrub list to skip RCR settings keys
- **JavaScriptInjectionService** — removed hardcoded site selector, made success detection extensible
- **SiteSettingsView** — added "Success Selector" field for per-domain custom detection

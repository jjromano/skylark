# Phase 0 spec — skeleton (menu-bar app, permissions, Fn PTT, audio capture, HUD, injection, stub transcriber)

Read `ARCHITECTURE.md` and `CLAUDE.md` first. This spec is self-contained;
where it conflicts with reality, do the closest working thing and report the
deviation. Verification on this machine = `swift build` (zero errors; strive
for zero concurrency warnings), `swift test`, `make app`. Do NOT attempt
interactive/GUI testing or permission grants — this box is headless; that
happens later on the target MacBook.

## Reference source (MIT, adapt freely with a `// Adapted from Hex (MIT): <file>` comment)

Cloned at `/private/tmp/claude-502/-Users-openclaw-skylark/a3044481-ba93-4200-b9e7-ac93bc8b3af1/scratchpad/research/`:
- `Hex/Hex/Clients/KeyEventMonitorClient.swift` — CGEventTap setup, fn tracking, tap watchdog
- `Hex/HexCore/Sources/HexCore/Logic/HotKeyProcessor.swift` — PTT/double-tap state machine (read fully; adapt semantics)
- `Hex/Hex/Clients/PasteboardClient.swift` — pasteboard snapshot/restore, changeCount polling, AX insertion
- `Hex/HexCore/Sources/HexCore/PermissionClient/PermissionClient+Live.swift` — permission checks/requests/deep links
- `Hex/Hex/Views/InvisibleWindow.swift` — NSPanel recipe (we size-to-content instead of screen-size, see HUD)
- `handy-keys/src/platform/macos/listener.rs` — fn robustness tricks (Rust; port the ideas)

Do not copy anything from VoiceInk (GPL). FluidAudio/WhisperKit are NOT
dependencies in this phase.

## 1. Package + build system

- `Package.swift`: swift-tools-version 6.2, `platforms: [.macOS(.v26)]` (if
  `.v26` isn't in your PackageDescription, use `.macOS("26.0")`). Targets:
  - `SkylarkCore` (library): everything below except the app shell/HUD.
  - `Skylark` (executableTarget, depends on SkylarkCore): app shell, HUD,
    onboarding, settings stub. **No file named `main.swift`** — use `@main`.
  - `SkylarkCoreTests`.
  No external dependencies in Phase 0.
- `Resources/Info.plist`: CFBundleExecutable `Skylark`, CFBundleIdentifier
  `com.jjromano.skylark`, CFBundleName `Skylark`, CFBundlePackageType APPL,
  CFBundleShortVersionString 0.1.0, CFBundleVersion 1, LSMinimumSystemVersion
  26.0, LSUIElement true, NSHighResolutionCapable true, NSPrincipalClass
  NSApplication, NSMicrophoneUsageDescription "Skylark uses the microphone to
  transcribe your speech. Audio never leaves this Mac in local mode."
- `Scripts/make-cert.sh`: create self-signed codesigning cert **"Skylark Dev
  Signing"** via the openssl + `security add-trusted-cert` recipe (Electron's
  CI pattern). Idempotent; needs sudo — check and print clear instructions if
  not root. Verify with `security find-identity -v -p codesigning`.
- `Scripts/bundle.sh`: `swift build -c release` → assemble
  `dist/Skylark.app/Contents/{MacOS,Resources}` + Info.plist → copy any
  `<Pkg>_<Target>.bundle` from `.build/release/` into `Contents/Resources/`
  → codesign `--force --sign "Skylark Dev Signing"` if that identity exists,
  else `--sign -` with a loud warning that TCC grants won't survive rebuilds.
- `Makefile`: `build` (swift build), `test`, `app` (bundle.sh), `run`
  (app + `open dist/Skylark.app`), `cert` (make-cert.sh).
- App code must never use `Bundle.module` (see ARCHITECTURE §0). Phase 0
  should need no resources; if you must ship one, add
  `SkylarkCore/Support/ResourceBundle.swift` implementing the
  `Bundle.main.resourceURL` fallback lookup.

## 2. SkylarkCore/Permissions — `PermissionsService`

`@Observable @MainActor final class PermissionsService`:
- `enum Grant { case granted, denied, notDetermined }`
- Published: `microphone: Grant`, `accessibility: Grant`, `inputMonitoring: Grant`, `allGranted: Bool`
- `func refresh()` — mic via `AVCaptureDevice.authorizationStatus(for: .audio)`;
  accessibility via `AXIsProcessTrustedWithOptions` (prompt=false);
  input monitoring via `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)`.
- `func request(_ kind:)` — mic: `AVCaptureDevice.requestAccess`; accessibility:
  `AXIsProcessTrustedWithOptions` prompt=true **once** then open Settings pane;
  input monitoring: `CGPreflightListenEventAccess()`/`CGRequestListenEventAccess()`
  then Settings pane.
- Deep links (verified): `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone` / `?Privacy_Accessibility` / `?Privacy_ListenEvent`.
- `func startPolling(interval: .milliseconds(500))` — refresh loop while
  onboarding is visible or the tap is wanted.
- Also expose `var fnGlobeActionConflict: Bool` — read `AppleFnUsageType` from
  `com.apple.HIToolbox` via `CFPreferencesCopyAppValue`; nonzero ⇒ warn in
  onboarding that we suppress the Globe action while Skylark runs (informational only).

## 3. SkylarkCore/Hotkey

### 3a. `HotkeyProcessor` (pure struct, fully unit-tested)
Adapt Hex's `HotKeyProcessor` semantics for a modifier-only Fn chord:
- States: `idle`, `pressAndHold(start: ContinuousClock.Instant)`, `doubleTapLock`.
- Outputs: `startRecording`, `stopRecording`, `cancel`, `discard`, `none`.
- Fn down in idle → `startRecording`, enter pressAndHold.
- Fn up → `stopRecording`; if this release is within 0.3 s of the previous
  release → enter `doubleTapLock` (hands-free; recording continues, so emit
  nothing extra); in `doubleTapLock`, next Fn down → `stopRecording`, idle.
- Holds shorter than 0.3 s → `discard` (not stop) — stray taps must not paste.
- Any non-Fn key down during `pressAndHold` → `cancel` + dirty flag: ignore
  all events until full release (user meant Fn+key, not dictation).
- Mouse click during the min-hold window → `discard`. ESC anytime while
  active → `cancel`.
- Inject time via `ContinuousClock`/protocol so tests control it.

### 3b. `HotkeyMonitor` (owns the CGEventTap)
- Active tap: `.cghidEventTap`, `.headInsertEventTap`, `.defaultTap`; mask:
  keyDown, keyUp, flagsChanged, left/right/other mouseDown.
- Fn detection: `.flagsChanged` + keycode 0x3F (`kVK_Function`) +
  `.maskSecondaryFn`. Keep a **sticky isFnPressed bool**; never trust
  `.maskSecondaryFn` on other keycodes (arrows/F-keys carry it spuriously).
  Skip keyDown events with unknown keycode + fn flag (Fn+media keys).
- Swallow (return nil) bare-Fn flagsChanged events while Skylark's hotkey is
  Fn (suppresses the system Globe action). Pass everything else through
  unmodified.
- Handle `.tapDisabledByTimeout`/`.tapDisabledByUserInput`: re-enable, then
  reconcile fn state from `CGEventSource.flagsState(.combinedSessionState)`.
- Watchdog: only create the tap when Accessibility is granted; poll
  permission each 1 s; tear down on revocation, rebuild on re-grant. Never
  crash on revocation.
- Emits `HotkeyEvent` values into an `AsyncStream` consumed by the orchestrator.

## 4. SkylarkCore/Audio — `AudioCaptureService`

- AVAudioEngine; on `start()`: install input tap, convert (AVAudioConverter)
  from device format to **16 kHz mono Float32** inside the tap, append into a
  preallocated buffer (cap 120 s; on overflow, stop and finalize). No
  allocation per callback beyond the converter's working buffer.
- `stop() -> AudioClip` (`struct AudioClip { samples: [Float]; sampleRate: Double; duration: TimeInterval }`).
- `var levels: AsyncStream<Float>` — RMS per tap callback (~10–20 Hz is fine),
  for the Phase 1 waveform; emit even in Phase 0.
- `func prepare()` — pre-start the engine at app launch so first Fn press has
  no cold-start penalty; if the engine can't run headless without mic
  permission, degrade gracefully (report, don't crash).
- Log capture start→stop wall time with `os.signpost` (latency instrumentation
  starts now).

## 5. SkylarkCore/Injection — `TextInjector`

Per ARCHITECTURE §3 injection strategy, AX-first:
- `func insert(_ text: String) async throws -> InsertionToken` where
  `InsertionToken` records `enum Method { case ax(AXUIElement), paste }` plus
  the inserted text (Phase 2 uses it for replacement; define the type now).
- AX path: focused element via `AXUIElementCreateSystemWide()` →
  `kAXFocusedUIElementAttribute`; probe `kAXValue`/`kAXSelectedText` reads;
  set `kAXSelectedTextAttribute`. Any AXError → paste path.
- Paste path: `PasteboardSnapshot` (all items, all types, as Data — adapt
  Hex's) → clearContents + write text → poll `changeCount` (5 ms interval,
  150 ms cap) → synthesized Cmd-V (explicit Cmd down keycode 55, V down/up
  with `.maskCommand`, Cmd up; post to `.cghidEventTap`; resolve V keycode
  via UCKeyTranslate for the current layout — no Sauce dependency) → wait
  500 ms → restore snapshot. If paste fails, leave text on clipboard
  (do NOT restore) and report `.pasteUncertain` in the token.
- Unit tests (headless-safe): snapshot/restore round-trip preserves a
  multi-type pasteboard (string + RTF + fake custom type) byte-for-byte —
  this is the PRD §10 clipboard test, on the app's own NSPasteboard.general.
  The synthesized-paste path itself can't be asserted headless; structure the
  code so the choreography (snapshot→write→poll→paste→delay→restore) is a
  testable async sequence with an injected `PasteExecutor`.

## 6. SkylarkCore/Pipeline

- `protocol Transcriber` + `StubTranscriber` (sleeps 50 ms, returns
  "Skylark stub: end-to-end pipeline works."). Use the ARCHITECTURE §2
  protocol shape but implement only `warmUp()` + `transcribe(_:hint:)` for
  now; leave `stream` out until Phase 1 (keep the protocol minimal — don't
  speculatively add it).
- `actor DictationOrchestrator`: consumes HotkeyEvents; state machine
  `idle → recording → transcribing → injecting → idle` (+ `cancelled`).
  Wires AudioCapture → Transcriber → TextInjector. Publishes
  `HUDState { idle, listening(level: Float), processing }` snapshots via
  `AsyncStream` for the UI. `discard`/`cancel` drop audio without
  transcribing. Signpost each stage boundary (fn-up → text-inserted is THE
  metric). Unit-test transitions with mocks (fake hotkey stream, stub
  transcriber, spy injector).

## 7. Skylark (app target)

- `@main struct SkylarkApp: App` + `NSApplicationDelegateAdaptor`.
  `MenuBarExtra` ("Skylark", systemImage mic) with: status line (current HUD
  state), "Settings…" (opens a stub Settings window — empty form saying
  Phase 2), "Onboarding…" (reopens onboarding), Quit.
- On launch: `PermissionsService.refresh()`; if `!allGranted` show onboarding
  window; else start HotkeyMonitor + AudioCapture.prepare() + show HUD.
- **Onboarding window**: three permission rows (icon, name, one-line why,
  live status badge, Grant button → `request`), polling while visible;
  a note about the Globe-key conflict when `fnGlobeActionConflict`; when all
  granted: "You're set — hold Fn and speak" + Close. Plain SwiftUI, no fancy
  design yet.
- **HUD** (`HUDPanel` + SwiftUI content):
  - NSPanel: `[.fullSizeContentView, .borderless, .nonactivatingPanel]`,
    `level = .statusBar`, clear/nonopaque/no shadow,
    `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`,
    `canBecomeKey/Main = false`, `hidesOnDeactivate = false`, shown with
    `orderFrontRegardless()`. **Sized to content** (not screen-sized),
    `ignoresMouseEvents = false`.
  - Position: centered horizontally on `NSScreen.main`, top edge just below
    the notch — use `screen.safeAreaInsets.top` when nonzero, else just below
    the menu bar. Re-clamp on screen-parameter changes. Never drifts or goes
    off-screen.
  - States (PRD §9): **idle** = thin rounded pill (~64×8) with a status dot
    (gray idle, red listening, amber processing). **hover** (not recording) =
    expands (~180×28) revealing: mode label ("Raw" for now), a record dot
    button (toggles a hands-free session), an expand chevron (opens Settings
    stub). **listening** = slightly larger pill with a placeholder waveform
    slot (static bars driven by nothing yet — Phase 1 wires levels; reserve
    stable layout so nothing pops) and the red dot. **processing** = amber
    dot + subtle indeterminate shimmer. Animate transitions ~120 ms; no
    layout jumps (fixed heights per state).
  - Right-click on the pill while listening → context menu: Cancel.
- App activation policy `.accessory` (LSUIElement also set in plist).

## 8. Acceptance (run these yourself)

1. `swift build` — clean.
2. `swift test` — HotkeyProcessor (≥8 cases: PTT happy path, short-tap
   discard, double-tap lock + unlock, chord-interruption dirty cancel, ESC,
   mouse-click discard), pasteboard round-trip, orchestrator transitions.
3. `make app` — produces `dist/Skylark.app`; `codesign -dv` shows a
   signature; report which identity was used.
4. Report per-file summary, deviations, and anything needing an interactive
   session on the MacBook to validate (there will be several — list them).

Git: commit your work on completion as one commit on `main` with a clear
message; do not push.

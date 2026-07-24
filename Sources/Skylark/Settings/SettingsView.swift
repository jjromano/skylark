import SkylarkCore
import SwiftUI

/// Settings window — a sidebar (`NavigationSplitView`) of sections with grouped
/// "cards" in the detail pane, matching the modern macOS System-Settings look.
/// Dictionary/Modes are absent (not disabled) when persistence couldn't open,
/// matching the graceful degradation the rest of the app uses for a missing DB.
struct SettingsView: View {
    @Bindable var controller: AppController
    let client: OpenRouterClient
    @State private var selection: Pane? = .general

    enum Pane: String, Hashable, Identifiable, CaseIterable {
        case general, insights, models, audio, dictionary, snippets, modes, history, account
        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .insights: return "Insights"
            case .models: return "Models"
            case .audio: return "Audio"
            case .dictionary: return "Dictionary"
            case .snippets: return "Snippets"
            case .modes: return "Modes"
            case .history: return "History"
            case .account: return "Account"
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape.fill"
            case .insights: return "chart.bar.fill"
            case .models: return "cpu.fill"
            case .audio: return "waveform"
            case .dictionary: return "character.book.closed.fill"
            case .snippets: return "scissors"
            case .modes: return "switch.2"
            case .history: return "clock.fill"
            case .account: return "person.crop.circle.fill"
            }
        }

        /// System-Settings-style tile tint behind the sidebar icon.
        var tint: Color {
            switch self {
            case .general: return .gray
            case .insights: return .purple
            case .models: return .indigo
            case .audio: return .pink
            case .dictionary: return .brown
            case .snippets: return .teal
            case .modes: return .cyan
            case .history: return .orange
            case .account: return .blue
            }
        }
    }

    private var panes: [Pane] {
        Pane.allCases.filter { pane in
            switch pane {
            case .dictionary: return controller.dictionaryStore != nil
            case .snippets: return controller.snippetStore != nil
            case .modes: return controller.modeStore != nil
            case .insights: return controller.statsStore != nil
            default: return true
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(panes) { pane in
                    SidebarRow(pane: pane).tag(pane)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 196, max: 220)
            .safeAreaInset(edge: .bottom) { sidebarFooter }
            // The sidebar is fixed — there's no reason to collapse it, so drop
            // the automatic toggle button from the toolbar.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail(for: selection ?? .general)
                .navigationTitle((selection ?? .general).title)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 760, height: 600)
    }

    private var sidebarFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "bird.fill").foregroundStyle(.secondary)
            Text("Skylark \(Bundle.main.shortVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func detail(for pane: Pane) -> some View {
        switch pane {
        case .general:
            GeneralPane(controller: controller)
        case .insights:
            InsightsView(controller: controller)
        case .models:
            ModelsPane(controller: controller)
        case .audio:
            AudioPane(controller: controller)
        case .dictionary:
            if let store = controller.dictionaryStore {
                ScrollView {
                    DictionaryView(
                        store: store,
                        learnFromCorrections: Binding(
                            get: { controller.learnFromCorrectionsEnabled },
                            set: { controller.setLearnFromCorrections($0) }
                        ),
                        deepVocabMatching: Binding(
                            get: { controller.deepVocabEnabled },
                            set: { controller.setDeepVocabEnabled($0) }
                        )
                    )
                    .padding(20)
                }
            }
        case .snippets:
            if let store = controller.snippetStore {
                ScrollView { SnippetsView(store: store).padding(20) }
            }
        case .modes:
            if let store = controller.modeStore {
                ScrollView { ModesView(store: store, cleanupModels: controller.cleanupModels).padding(20) }
            }
        case .history:
            HistoryPane(controller: controller)
        case .account:
            AccountPane(controller: controller, client: client)
        }
    }
}

/// Sidebar entry with a System-Settings-style colored icon tile.
private struct SidebarRow: View {
    let pane: SettingsView.Pane

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(pane.tint.gradient)
                .frame(width: 22, height: 22)
                .overlay(
                    Image(systemName: pane.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                )
            Text(pane.title)
        }
        .padding(.vertical, 1)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Bindable var controller: AppController

    /// Sentinel selection for the Cleanup-model picker's local option (maps to
    /// the "local" cleanup tier / Apple Intelligence). Won't collide with real
    /// registry slugs.
    private static let localCleanupTag = "skylark.local"

    /// Sentinel for the mouse-trigger picker's "None" row (no binding).
    private static let mouseOffTag = "off"

    /// Transient footer note surfacing the "Cleanup model" picker's implicit
    /// tier switch (choosing a local/cloud model forces that tier). Mirrors
    /// `AppController.showNote`'s clear-after-4s pattern, scoped to this pane.
    @State private var tierSwitchNote: String?
    @State private var tierSwitchNoteClearTask: Task<Void, Never>?

    /// Whether the current configuration routes anything through OpenRouter.
    private var usesCloud: Bool {
        if controller.cleanupOverride == "cloud" { return true }
        if case .cloud = controller.currentSTT { return true }
        return false
    }

    /// Caption for the live-preview toggle. Notes the Parakeet-only limitation
    /// when another engine is active (the toggle stays but preview won't render).
    private var livePreviewCaption: String {
        let base = "Shows words as you speak in the recording pill. Experimental — the pasted text is unaffected."
        return controller.currentSTT == .localParakeet ? base : base + " Parakeet only."
    }

    var body: some View {
        Form {
            Section {
                ShortcutRecorderRow(controller: controller)
                Picker("Mouse (optional)", selection: Binding(
                    get: { controller.hotkeyMouse?.rawValue ?? Self.mouseOffTag },
                    set: { raw in
                        controller.setHotkeyMouse(raw == Self.mouseOffTag ? nil : HotkeyBinding(rawValue: raw))
                    }
                )) {
                    Text("None").tag(Self.mouseOffTag)
                    ForEach(HotkeyBinding.mouseOptions, id: \.rawValue) { option in
                        Text(option.displayName).tag(option.rawValue)
                    }
                }
            } header: {
                Text("Dictation shortcut")
            } footer: {
                Text("Hold to talk; double-tap to lock hands-free; Esc cancels. Keyboard and mouse triggers are interchangeable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ShortcutRecorderRow(
                    controller: controller,
                    label: "Command key",
                    currentDisplayName: controller.hotkeyCommand?.displayName ?? "None",
                    onCapture: { controller.setHotkeyCommand($0) },
                    onClear: { controller.setHotkeyCommand(nil) }
                )
            } header: {
                Text("Voice command shortcut")
            } footer: {
                Text("Hold and speak an instruction to rewrite selected text or generate text at the cursor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Recording indicator") {
                Picker("Style", selection: Binding(
                    get: { controller.hud.style },
                    set: { controller.setHUDStyle($0) }
                )) {
                    ForEach(HUDStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Show idle pill between dictations", isOn: Binding(
                    get: { controller.hud.showIdlePill },
                    set: { controller.setHUDShowIdlePill($0) }
                ))
                .disabled(controller.hud.style == .hidden)
                Toggle("Live preview while speaking", isOn: Binding(
                    get: { controller.livePreviewEnabled },
                    set: { controller.setLivePreviewEnabled($0) }
                ))
                .disabled(controller.hud.style == .hidden)
                Text(livePreviewCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Spoken “press enter” command", isOn: Binding(
                    get: { controller.pressEnterEnabled },
                    set: { controller.setPressEnterEnabled($0) }
                ))
                Toggle("Pause music while dictating", isOn: Binding(
                    get: { controller.pauseMediaEnabled },
                    set: { controller.setPauseMediaEnabled($0) }
                ))
            } header: {
                Text("Behavior")
            } footer: {
                Text("End a dictation with “press enter” to send it as a message. Music pause covers Music and Spotify and asks for an Automation permission the first time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Cleanup") {
                Picker("Default cleanup tier", selection: Binding(
                    get: { controller.cleanupOverride },
                    set: { controller.setCleanupOverride($0) }
                )) {
                    Text("Auto (per-mode)").tag("auto")
                    Text("Raw").tag("raw")
                    Text("Local").tag("local")
                    Text("Cloud").tag("cloud")
                }
                if usesCloud, !controller.hasAPIKey {
                    Label(
                        "No API key stored — cloud selections fall back to local. Add a key in Account.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                Picker("Cleanup intensity", selection: Binding(
                    get: { controller.cleanupIntensity },
                    set: { controller.setCleanupIntensity($0) }
                )) {
                    Text("Light").tag(CleanupIntensity.light)
                    Text("Standard").tag(CleanupIntensity.standard)
                    Text("High").tag(CleanupIntensity.high)
                }
                .pickerStyle(.segmented)
                .disabled(controller.cleanupOverride == "raw")
                Text(controller.cleanupIntensity.caption)
                Toggle("Use on-screen context", isOn: Binding(
                    get: { controller.contextAwareCleanupEnabled },
                    set: { controller.setContextAwareCleanupEnabled($0) }
                ))
                Text("Reads the text around your cursor (via Accessibility) so dictation continues sentences naturally and matches spellings already in the field. The context is used only for this cleanup pass — never stored. With a cloud cleanup model it is sent to that model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Translate dictation", isOn: Binding(
                    get: { controller.translateEnabled },
                    set: { controller.setTranslateEnabled($0) }
                ))
                Picker("Target language", selection: Binding(
                    get: { controller.translateTargetLanguage },
                    set: { controller.setTranslateTargetLanguage($0) }
                )) {
                    ForEach(TranslationLanguage.codes, id: \.self) { code in
                        Text(TranslationLanguage.displayName(code)).tag(code)
                    }
                }
                .disabled(!controller.translateEnabled)
            } header: {
                Text("Translation")
            } footer: {
                Text("Cleans up your dictation and translates it to the target language before typing it. Uses your selected cleanup model — with a Local tier this runs fully on-device. Cloud models translate best; on-device translation is usable for European languages but unreliable for Japanese, Chinese, and Korean (failed translations fall back to your original words).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Speech engine", selection: Binding(
                    get: { controller.currentSTT },
                    set: { controller.selectSTT($0) }
                )) {
                    Text("Local — Parakeet").tag(STTChoice.localParakeet)
                    Text("Local — Whisper large-v3-turbo").tag(STTChoice.localWhisper)
                    Text("Local — Apple Speech (macOS)").tag(STTChoice.localApple)
                    ForEach(controller.sttModels) { entry in
                        Text(entry.label).tag(STTChoice.cloud(slug: entry.slug))
                    }
                }
                Picker("Cleanup model", selection: Binding(
                    get: { controller.cleanupOverride == "local" ? Self.localCleanupTag : controller.currentCleanupSlug },
                    set: { selection in
                        let previousTier = controller.cleanupOverride
                        if selection == Self.localCleanupTag {
                            controller.setCleanupOverride("local")
                        } else {
                            // Picking a cloud model routes cleanup to the cloud so
                            // the choice actually takes effect.
                            controller.setCleanupOverride("cloud")
                            controller.selectCleanupSlug(selection)
                        }
                        announceTierSwitch(from: previousTier, to: controller.cleanupOverride)
                    }
                )) {
                    Text("Apple Intelligence (Local)").tag(Self.localCleanupTag)
                    ForEach(controller.cleanupModels) { entry in
                        Text(entry.label).tag(entry.slug)
                    }
                }
            } header: {
                Text("Speech & cleanup")
            } footer: {
                if let tierSwitchNote {
                    Text(tierSwitchNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Feedback") {
                Toggle("Play start/stop sounds", isOn: Binding(
                    get: { controller.soundEffectsEnabled },
                    set: { controller.setSoundEffectsEnabled($0) }
                ))
                Picker("Start sound", selection: Binding(
                    get: { controller.soundStartID },
                    set: { controller.setSoundStart($0) }
                )) {
                    ForEach(SoundEffects.catalog) { cue in Text(cue.label).tag(cue.id) }
                }
                .disabled(!controller.soundEffectsEnabled)
                Picker("Stop sound", selection: Binding(
                    get: { controller.soundStopID },
                    set: { controller.setSoundStop($0) }
                )) {
                    ForEach(SoundEffects.catalog) { cue in Text(cue.label).tag(cue.id) }
                }
                .disabled(!controller.soundEffectsEnabled)
                HStack {
                    Text("Volume")
                    Slider(
                        value: Binding(
                            get: { controller.soundVolume },
                            set: { controller.setSoundVolume($0) }
                        ),
                        in: 0...1
                    ) { editing in
                        // Audition on release, not on every tick.
                        if !editing { controller.previewSoundVolume() }
                    }
                    Image(systemName: "speaker.wave.2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!controller.soundEffectsEnabled)
            }

            Section("Launch") {
                Toggle("Launch Skylark at login", isOn: Binding(
                    get: { controller.launchAtLoginStatus == .enabled },
                    set: { controller.setLaunchAtLogin($0) }
                ))
                if let footnote = controller.launchAtLoginFootnote {
                    Text(footnote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Surfaces the "Cleanup model" picker's implicit tier switch (a picker
    /// selection forces Local or Cloud tier) with a transient footer caption,
    /// but only when the tier actually changed — re-picking the same effective
    /// tier stays silent.
    private func announceTierSwitch(from previousTier: String, to newTier: String) {
        guard previousTier != newTier else { return }
        let label = newTier == "local" ? "Local" : "Cloud"
        tierSwitchNote = "Default cleanup tier switched to \(label) to match your model choice."
        tierSwitchNoteClearTask?.cancel()
        tierSwitchNoteClearTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { tierSwitchNote = nil }
        }
    }
}

// MARK: - History

private struct HistoryPane: View {
    @Bindable var controller: AppController
    @State private var confirmDeleteAudio = false
    @State private var recent: [HistoryRecord] = []

    var body: some View {
        Form {
            Section {
                if recent.isEmpty {
                    Text("No dictations yet.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(recent) { record in
                        RecentDictationRow(record: record)
                    }
                }
                Button("Open Full History…") { controller.showHistory() }
            } header: {
                Text("Recent dictations")
            } footer: {
                Text("Speech and cleanup show the engines that actually ran — a fallback here means the selected model didn't. The full history window adds search, playback, and editing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Keep history for", selection: Binding(
                    get: { controller.retentionDays },
                    set: { controller.setRetentionDays($0) }
                )) {
                    Text("Forever").tag(0)
                    Text("90 days").tag(90)
                    Text("30 days").tag(30)
                    Text("7 days").tag(7)
                }
            } header: {
                Text("Retention")
            } footer: {
                Text("Older dictations (and any retained audio) are deleted automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Learn corrections automatically", isOn: Binding(
                    get: { controller.dictionaryAutoLearn },
                    set: { controller.setDictionaryAutoLearn($0) }
                ))
            } header: {
                Text("Dictionary learning")
            } footer: {
                Text("When you fix a word while editing a transcript in History, add the correction to the Dictionary without asking.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Audio retention") {
                Toggle("Keep audio recordings", isOn: Binding(
                    get: { controller.audioRetentionEnabled },
                    set: { controller.setAudioRetentionEnabled($0) }
                ))
                Text("Stores each dictation's audio on this Mac (Application Support/Skylark/Audio) so you can replay or re-transcribe it from History. Deleted automatically after the retention period. Nothing is uploaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Delete audio after", selection: Binding(
                    get: { controller.audioRetentionDays },
                    set: { controller.setAudioRetentionDays($0) }
                )) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                .disabled(!controller.audioRetentionEnabled)
                Text("Turning this off deletes all stored audio (your text history stays).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Delete all stored audio…", role: .destructive) { confirmDeleteAudio = true }
                    .confirmationDialog(
                        "Delete all stored audio?",
                        isPresented: $confirmDeleteAudio,
                        titleVisibility: .visible
                    ) {
                        Button("Delete", role: .destructive) { controller.deleteAllStoredAudio() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("History entries stay; only the audio files are removed.")
                    }
            }
        }
        .formStyle(.grouped)
        .task {
            recent = (try? await controller.historyStore?.recent(limit: 8)) ?? []
        }
    }
}

/// One recent dictation with engine/cleanup provenance badges.
private struct RecentDictationRow: View {
    let record: HistoryRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(record.cleanText ?? record.rawText)
                .font(.system(size: 12))
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(record.timestamp, format: .relative(presentation: .named))
                if let app = record.appName {
                    Text("·")
                    Text(app)
                }
                badge("waveform", Self.engineLabel(record.engine))
                badge("sparkles", Self.cleanupLabel(record.cleanupEngine))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }

    private func badge(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8))
            Text(text)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(.secondary.opacity(0.15)))
    }

    /// Friendly label for the STT engine string stored on the row.
    static func engineLabel(_ engine: String) -> String {
        switch engine {
        case "parakeet": return "Parakeet · local"
        case "whisperkit": return "Whisper · local"
        case "appleSpeech": return "Apple Speech · local"
        case "stub": return "stub"
        default: return shortSlug(engine) + " · cloud"
        }
    }

    /// Friendly label for the cleanup engine ("raw"/"local"/slug/"snippet").
    static func cleanupLabel(_ engine: String?) -> String {
        switch engine {
        case nil: return "no cleanup"
        case "raw": return "raw"
        case "local": return "Apple Intelligence"
        case "snippet": return "snippet"
        case let .some(slug): return shortSlug(slug) + " · cloud"
        }
    }

    private static func shortSlug(_ slug: String) -> String {
        slug.split(separator: "/").last.map(String.init) ?? slug
    }
}

// MARK: - Models

private struct ModelsPane: View {
    @Bindable var controller: AppController

    private static let costCaption = "Estimated cost assumes ~10 min of dictation/day (~5 hrs/month)."

    var body: some View {
        Form {
            Section {
                ModelRow(controller: controller, model: .parakeet)
                ModelRow(controller: controller, model: .whisper)
                AppleSpeechRow(controller: controller)
            } header: {
                Text("Speech engines · on device")
            } footer: {
                Text("Downloaded once and stored locally under Application Support/Skylark. Runs fully offline. Apple Speech's language asset is managed by macOS instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text(Self.costCaption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(controller.sttModels) { entry in
                    InfoModelRow(label: entry.label, info: ModelInfo.cloudSTT[entry.slug], requiresAPIKey: true)
                }
            } header: {
                Text("Speech engines · cloud")
            } footer: {
                Text("Cloud speech runs on OpenRouter, not on this Mac. Add an API key in Account to use it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                InfoModelRow(label: "Apple Intelligence", info: ModelInfo.appleIntelligence)
            } header: {
                Text("Cleanup · on device")
            }

            Section {
                Text(Self.costCaption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(controller.cleanupModels) { entry in
                    InfoModelRow(label: entry.label, info: ModelInfo.cloudCleanup[entry.slug], requiresAPIKey: true)
                }
            } header: {
                Text("Cleanup · cloud")
            } footer: {
                Text("Cloud cleanup runs on OpenRouter, not on this Mac. Add an API key in Account to use it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ModelRow(controller: controller, model: .vad)
                ModelRow(controller: controller, model: .deepVocab)
            } header: {
                Text("Utility")
            } footer: {
                Text("Deep Vocabulary is downloaded only when you turn on deep vocabulary matching in Dictionary. Deleting it turns that feature off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ModelRow: View {
    @Bindable var controller: AppController
    let model: AppController.ManagedModel

    private var state: AppController.ManagedModelState {
        controller.modelStates[model] ?? .notDownloaded
    }

    private var info: ModelInfo.Entry? { ModelInfo.onDevice[model] }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.label).font(.system(size: 13, weight: .medium))
                Text(statusText).font(.caption).foregroundStyle(.secondary)
                if let info {
                    Text(info.description).font(.caption).foregroundStyle(.secondary)
                    ScoreRow(info: info)
                }
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(.vertical, 2)
    }

    private var statusText: String {
        switch state {
        case .notDownloaded:
            return "Not downloaded · \(model.approxSize)"
        case let .downloading(progress):
            return "Downloading \(Int((progress * 100).rounded()))%"
        case .preparing:
            return "Preparing…"
        case let .ready(bytes):
            // Some engines (FluidAudio Parakeet) install to a path we can't
            // measure precisely; fall back to the approximate size rather than
            // showing a misleading "Zero KB".
            return bytes > 0 ? "Ready · \(SettingsFormat.bytes(bytes))" : "Ready · \(model.approxSize)"
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch state {
        case .notDownloaded:
            Button("Download") { controller.downloadModel(model) }
        case .downloading, .preparing:
            ProgressView().controlSize(.small)
        case .ready:
            Button("Delete") { controller.deleteModel(model) }
                .disabled(controller.isModelInUse(model))
                .help(controller.isModelInUse(model) ? "In use by the current speech engine" : "")
        }
    }
}

/// Row for the macOS-managed Apple Speech engine. Like `ModelRow` it offers a
/// Download action (which installs the OS language asset) and shows progress,
/// but there's no size or delete — the asset is system-managed and removed in
/// System Settings, not here. Shows the resolved locale.
private struct AppleSpeechRow: View {
    @Bindable var controller: AppController

    private var state: AppController.ManagedModelState {
        controller.modelStates[.appleSpeech] ?? .notDownloaded
    }

    private let info = ModelInfo.appleSpeech

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Apple Speech").font(.system(size: 13, weight: .medium))
                Text(statusText).font(.caption).foregroundStyle(.secondary)
                Text(info.description).font(.caption).foregroundStyle(.secondary)
                ScoreRow(info: info)
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(.vertical, 2)
    }

    private var statusText: String {
        switch state {
        case .notDownloaded:
            return "Not installed · language \(controller.appleSpeechLocale) · system-managed"
        case let .downloading(progress):
            return "Downloading \(Int((progress * 100).rounded()))%"
        case .preparing:
            return "Preparing…"
        case .ready:
            return "Installed · language \(controller.appleSpeechLocale) · system-managed"
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch state {
        case .notDownloaded:
            Button("Download") { controller.downloadModel(.appleSpeech) }
        case .downloading, .preparing:
            ProgressView().controlSize(.small)
        case .ready:
            // No delete: the asset belongs to macOS.
            EmptyView()
        }
    }
}

/// Read-only informational row for a model that isn't downloadable/deletable
/// here — either a cloud (OpenRouter) model or an OS-provided one like Apple
/// Intelligence. No download/delete affordances.
private struct InfoModelRow: View {
    let label: String
    let info: ModelInfo.Entry?
    var requiresAPIKey: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 13, weight: .medium))
                if let info {
                    Text(info.description).font(.caption).foregroundStyle(.secondary)
                    ScoreRow(info: info)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if let cost = info?.costPerMonth {
                    Text(cost).font(.caption).foregroundStyle(.secondary)
                }
                if requiresAPIKey {
                    Text("Requires API key").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Compact "Label 4.5/5" pair for a model's two scores (Accuracy/Latency or
/// Quality/Speed), rendered as filled/half/empty dots.
private struct ScoreRow: View {
    let info: ModelInfo.Entry

    var body: some View {
        HStack(spacing: 14) {
            if let score = info.primaryScore {
                ScoreDots(label: info.primaryLabel, score: score)
            }
            if let score = info.secondaryScore {
                ScoreDots(label: info.secondaryLabel, score: score)
            }
        }
    }
}

private struct ScoreDots: View {
    let label: String
    let score: Double

    var body: some View {
        HStack(spacing: 3) {
            Text("\(label):")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 1) {
                ForEach(0..<5, id: \.self) { index in
                    Image(systemName: symbolName(forDotAt: index))
                        .font(.system(size: 7))
                        .foregroundStyle(.secondary)
                }
            }
            Text(String(format: "%.1f", score))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func symbolName(forDotAt index: Int) -> String {
        let fill = score - Double(index)
        if fill >= 1 { return "circle.fill" }
        if fill >= 0.5 { return "circle.lefthalf.filled" }
        return "circle"
    }
}

// MARK: - Audio

private struct AudioPane: View {
    @Bindable var controller: AppController

    private var selectedDevice: AudioInputDevice? {
        controller.inputDevices.first { $0.uid == controller.selectedDeviceUID }
    }

    var body: some View {
        Form {
            Section("Input device") {
                Picker("Microphone", selection: Binding(
                    get: { controller.selectedDeviceUID ?? "" },
                    set: { controller.selectInputDevice($0.isEmpty ? nil : $0) }
                )) {
                    Text("System default").tag("")
                    ForEach(controller.inputDevices) { device in
                        Text(device.isBluetooth ? "\(device.name) (Bluetooth)" : device.name)
                            .tag(device.uid)
                    }
                }

                if let device = selectedDevice, device.isBluetooth {
                    Label(
                        "Bluetooth mics reduce recognition quality (HFP). Consider the built-in mic.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            Section("Whisper Mode") {
                Toggle("Whisper Mode (boosts quiet speech)", isOn: Binding(
                    get: { controller.whisperModeOn },
                    set: { _ in controller.toggleWhisperMode() }
                ))
                Text("Boosts gain and tunes endpointing for quiet or whispered speech — useful in shared spaces where you don't want to talk at normal volume.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Account

private struct AccountPane: View {
    @Bindable var controller: AppController
    let client: OpenRouterClient

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                APIKeyCard(client: client, showRemove: true) {
                    controller.apiKeyDidChange()
                }
                updatesCard
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(20)
        }
    }

    private var updatesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("About & updates", systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Skylark \(Bundle.main.shortVersion)")
                        .font(.system(size: 13, weight: .medium))
                    if let info = controller.buildInfo, let commit = info.commit {
                        Text("Build \(String(commit.prefix(7)))\(buildDateSuffix)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Development build (not installed via install.sh)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                switch controller.updateState {
                case .checking:
                    ProgressView().controlSize(.small)
                case .available:
                    Button("Update Now") { controller.runUpdate() }
                        .buttonStyle(.borderedProminent)
                default:
                    Button("Check for Updates") { controller.checkForUpdates() }
                }
            }

            switch controller.updateState {
            case .upToDate:
                Label("Skylark is up to date.", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case let .available(summary):
                Label(summary.map { "Update available: \($0)" } ?? "An update is available.",
                      systemImage: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.blue)
                Text("Updating opens Terminal, pulls the latest code, and rebuilds — about two minutes. Skylark quits and relaunches itself at the end; the Terminal window prints the version that came back up.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case let .failed(reason):
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            default:
                EmptyView()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }

    private var buildDateSuffix: String {
        guard let date = controller.buildInfo?.date else { return "" }
        return " · " + date.formatted(date: .abbreviated, time: .omitted)
    }
}

// MARK: - Formatting

private enum SettingsFormat {
    static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: count)
    }
}

private extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
    }
}

import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    var runtime: AgentRuntime
    var project: Project
    @Bindable var settings: AgentSettings
    @State private var apiKey = ""
    @State private var savedKeyNotice = ""
    @State private var customModel = ""
    @State private var testingConnection = false
    @State private var connectionResult: Result<Void, Error>?
    @State private var showKey = false
    @State private var showSavedToast = false
    @State private var saveTask: Task<Void, Never>?
    @State private var toastHideTask: Task<Void, Never>?
    @State private var codexTerminalTask: Task<Void, Never>?
    @State private var providerModelTask: Task<Void, Never>?
    @State private var connectionTestTask: Task<Void, Never>?
    @State private var showingModelPicker = false
    @State private var showingCustomModelField = false
    @State private var didPresentModelPickerDemo = false
    @State private var providerModels: [String] = []
    @State private var loadingProviderModels = false
    @State private var providerModelError: String? = nil
    @State private var settingsSaveError: String? = nil
    @State private var draftTemperature = 0.2
    @State private var draftSystemPrompt = ""
    @State private var confirmingWorkspaceReset = false
    @State private var resetWorkspaceError: String?
    @State private var codexTerminalLines: [String] = [
        "$ codex login --device-auth",
        "Simulated setup is fully local/no-key. Use Local for real no-key model runs."
    ]
    @State private var codexTerminalCode = "NOVA-CODEX"
    @State private var codexTerminalRunning = false
    @State private var lastRecordedSettingsSnapshot: AgentSettingsPersistence.Snapshot?
    @AppStorage("codexTerminalPaired") private var codexTerminalPaired = false
    @AppStorage(AgentTheme.storageKey) private var selectedThemeRawValue = AgentTheme.defaultTheme.rawValue
    @AppStorage(AgentPerformance.storageKey) private var performanceModeEnabled = false

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                // One continuous vertical settings surface feels more native and
                // predictable than the old segmented dashboard. Everything is
                // reachable by normal scrolling, while advanced sheets still use
                // native NavigationStack/List pickers.
                GlassGroup(spacing: 16) {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        SettingsHero(
                            projectName: project.name,
                            subtitle: "Command deck // theme studio",
                            tint: AgentPalette.primaryAccent
                        )
                        .accessibilityIdentifier("settingsHero")

                        SettingsCommandDeck(
                            readinessTitle: settingsReadinessTitle,
                            readinessDetail: settingsReadinessDetail,
                            readinessSymbol: settingsReadinessSymbol,
                            readinessTint: settingsReadinessTint,
                            providerName: settings.provider.displayName,
                            providerSymbol: settings.provider.symbol,
                            providerTint: settings.provider.tint,
                            modelName: modelDisplayName(settings.modelID),
                            modelDetail: modelReadinessDetail,
                            safetyTitle: safetyModeTitle,
                            safetyDetail: safetyModeDetail,
                            safetyTint: safetyModeTint,
                            theme: selectedTheme
                        )
                        .accessibilityIdentifier("settingsCommandDeck")

                        providerSection
                        modelSection
                        presetSection

                        if settings.provider == .openAICodex {
                            credentialSection
                            if showsCodexTerminalDemo {
                                codexTerminalSection
                            }
                        } else if settings.provider == .local {
                            localModelSection
                        } else {
                            credentialSection
                        }

                        behaviorSection
                        diagnosticsSection
                        appearanceSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .agentDockEdgeFade()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                BottomDockContentShield(height: BottomDockMetrics.scrollClearance)
            }

            SettingsSaveToast(isVisible: showSavedToast)
        }
        .accessibilityIdentifier("settingsRoot")
        .onAppear(perform: prepare)
        .onDisappear {
            flushPendingSettingsSave()
            saveTask?.cancel()
            toastHideTask?.cancel()
            codexTerminalTask?.cancel()
            providerModelTask?.cancel()
            connectionTestTask?.cancel()
        }
        .onChange(of: settings.providerRawValue) {
            providerModels = []
            providerModelError = nil
            loadingProviderModels = false
            providerModelTask?.cancel()
            reloadKey()
            customModel = settings.modelID
            if let variant = LocalModelCatalog.variant(for: settings.modelID) {
                runtime.localModels.select(variant)
            }
        }
        .onChange(of: settings.modelID) {
            if let variant = LocalModelCatalog.variant(for: settings.modelID) {
                runtime.localModels.select(variant)
            }
        }
        .onChange(of: draftTemperature) {
            scheduleDraftBehaviorSave()
        }
        .onChange(of: draftSystemPrompt) {
            scheduleDraftBehaviorSave()
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                runtime.localModels.refreshStatus()
            } else {
                flushPendingSettingsSave()
            }
        }
        .sheet(isPresented: $showingModelPicker) {
            ProviderModelPickerSheet(
                provider: settings.provider,
                models: modelChoices,
                selectedModel: settings.modelID,
                isLoading: loadingProviderModels,
                errorMessage: providerModelError,
                refresh: loadProviderModels,
                select: selectModel
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            "Reset workspace?",
            isPresented: $confirmingWorkspaceReset,
            titleVisibility: .visible
        ) {
            Button("Reset \(runtime.workspace.workspaceName)", role: .destructive) {
                do {
                    let workspaceName = runtime.workspace.workspaceName
                    try runtime.resetWorkspace()
                    ProjectEventRecorder.recordFileChange(
                        project: project,
                        action: "Workspace reset",
                        path: workspaceName,
                        context: modelContext
                    )
                    do {
                        try modelContext.save()
                    } catch {
                        modelContext.rollback()
                        resetWorkspaceError = "Workspace reset completed, but NovaForge could not save the project proof record. The files are cleared; run the smoke gate before trusting cleanup history. \(error.localizedDescription)"
                        UINotificationFeedbackGenerator().notificationOccurred(.error)
                        return
                    }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    triggerSaveNotice()
                } catch {
                    resetWorkspaceError = "Could not reset workspace: \(error.localizedDescription)"
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes files in the current NovaForge workspace. This cannot be undone.")
        }
        .alert(
            "Workspace Reset Issue",
            isPresented: Binding(
                get: { resetWorkspaceError != nil },
                set: { if !$0 { resetWorkspaceError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { resetWorkspaceError = nil }
        } message: {
            Text(resetWorkspaceError ?? "NovaForge could not reset this workspace.")
        }
        .alert(
            "Settings Not Saved",
            isPresented: Binding(
                get: { settingsSaveError != nil },
                set: { if !$0 { settingsSaveError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { settingsSaveError = nil }
        } message: {
            Text(settingsSaveError ?? "NovaForge could not save that settings change. Your previous setting is still active.")
        }
    }


    private var credentialStatusText: String {
        if settings.provider == .local { return "Local" }
        return apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Needed" : "Saved"
    }

    private var credentialStatusTint: Color {
        if settings.provider == .local { return AgentPalette.green }
        return apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AgentPalette.storageAccent : AgentPalette.green
    }

    private var settingsReadinessTitle: String {
        if settings.provider == .local {
            switch runtime.localModels.status {
            case .ready:
                return "Ready to run"
            case .downloading:
                return "Downloading model"
            case .partial:
                return "Resume local download"
            case .missing:
                return "Download local model"
            case .checking:
                return "Checking local model"
            case .incompatible, .failed:
                return "Local model needs attention"
            }
        }
        if settings.provider == .custom && settings.resolvedCustomChatCompletionsURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Endpoint required"
        }
        return apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "API key required" : "Ready to run"
    }

    private var settingsReadinessDetail: String {
        if settings.provider == .local {
            return localModelStatusDetail
        }
        if settings.provider == .custom && settings.resolvedCustomChatCompletionsURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Add a chat completions URL before custom provider runs."
        }
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Save a \(settings.provider.displayName) key before live hosted runs"
        }
        return "\(settings.provider.displayName) key saved · \(settings.autoApproveWrites ? "auto writes" : "asks before writes")"
    }

    private var settingsReadinessSymbol: String {
        if settings.provider == .local {
            switch runtime.localModels.status {
            case .ready:
                return "checkmark.seal.fill"
            case .downloading:
                return "arrow.down.circle.fill"
            case .partial:
                return "pause.circle.fill"
            case .missing:
                return "icloud.and.arrow.down"
            case .checking:
                return "hourglass"
            case .incompatible, .failed:
                return "exclamationmark.triangle.fill"
            }
        }
        if settingsReadinessTitle == "Ready to run" {
            return "checkmark.seal.fill"
        }
        return "key.fill"
    }

    private var settingsReadinessTint: Color {
        if settings.provider == .local {
            switch runtime.localModels.status {
            case .ready:
                return AgentPalette.green
            case .downloading, .partial, .checking:
                return AgentPalette.lilac
            case .missing:
                return AgentPalette.cyan
            case .incompatible, .failed:
                return AgentPalette.rose
            }
        }
        return settingsReadinessTitle == "Ready to run" ? AgentPalette.green : AgentPalette.warning
    }

    private var safetyModeTitle: String {
        settings.autoApproveWrites ? "Auto-approve writes" : "Review first"
    }

    private var safetyModeDetail: String {
        settings.autoApproveWrites
            ? "Mutating sandbox tools can run without another prompt."
            : "Writes, commands, and deletes pause for approval."
    }

    private var safetyModeTint: Color {
        settings.autoApproveWrites ? AgentPalette.warning : AgentPalette.green
    }

    private var modelReadinessDetail: String {
        if let variant = LocalModelCatalog.variant(for: settings.modelID) {
            return "\(variant.quantization) · \(variant.expectedSizeLabel) · \(runtime.localModels.status.title)"
        }
        if settings.provider == .custom {
            return settings.resolvedCustomChatCompletionsURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Custom endpoint not set"
                : "Custom endpoint configured"
        }
        return "\(settings.provider.displayName) hosted model ID"
    }

    private var localModelStatusDetail: String {
        let variant = runtime.localModels.selectedVariant
        switch runtime.localModels.status {
        case .ready:
            return "\(variant.shortName) is installed and runs on-device."
        case .downloading:
            return "\(variant.shortName) is downloading. Keep NovaForge in the foreground."
        case .partial:
            return "\(variant.shortName) has a partial download ready to resume."
        case .missing:
            return "Download \(variant.expectedSizeLabel) for \(variant.shortName) before Local can answer."
        case .checking:
            return "Checking \(variant.shortName) storage and compatibility."
        case .incompatible(let message), .failed(let message):
            return message
        }
    }

    private var showsCodexTerminalDemo: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--codex-terminal-demo")
        #else
        false
        #endif
    }

    private var providerSection: some View {
        SettingsSection(title: "Provider", subtitle: "Choose the API route for new runs") {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ],
                spacing: 8
            ) {
                ForEach(AIProvider.allCases) { provider in
                    SettingsProviderRow(
                        provider: provider,
                        selected: settings.provider == provider,
                        status: providerReadiness(for: provider).title,
                        statusTint: providerReadiness(for: provider).tint
                    ) {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        persistSettingsChange {
                            $0.switchProvider(to: provider)
                        }
                    }
                    .accessibilityIdentifier("settingsProvider-\(provider.rawValue)")
                }
            }
        }
    }

    private var modelSection: some View {
        SettingsSection(title: "Model", subtitle: "Browse every model for the selected provider") {
            VStack(alignment: .leading, spacing: 10) {
                SettingsModelReadinessPanel(
                    title: modelDisplayName(settings.modelID),
                    detail: modelReadinessDetail,
                    symbol: settings.provider == .local ? "cpu.fill" : settings.provider.symbol,
                    tint: settingsReadinessTint,
                    stats: modelReadinessStats
                )

                SettingsModelPickerButton(
                    provider: settings.provider,
                    model: modelDisplayName(settings.modelID),
                    count: modelChoices.count,
                    isLoading: loadingProviderModels
                ) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showingModelPicker = true
                    if providerModels.isEmpty && !loadingProviderModels {
                        loadProviderModels()
                    }
                }

                DisclosureGroup(isExpanded: $showingCustomModelField) {
                    HStack(alignment: .bottom, spacing: 8) {
                        SettingsTextField(
                            title: "Paste exact model id",
                            text: $customModel,
                            symbol: "cpu"
                        )
                        .onSubmit {
                            selectModel(customModel.trimmingCharacters(in: .whitespacesAndNewlines))
                        }

                        SettingsActionButton(title: "Apply", symbol: "checkmark", tint: settings.provider.tint, prominent: false) {
                            selectModel(customModel.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                        .disabled(customModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Custom model id")
                        .font(NovaType.caption)
                        .foregroundStyle(AgentPalette.secondaryText)
                }
                .tint(AgentPalette.secondaryText)
                .accessibilityIdentifier("settingsCustomModelDisclosure")

                if let providerModelError {
                    Label(providerModelError, systemImage: "exclamationmark.triangle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AgentPalette.rose)
                        .lineLimit(3)
                }

                if settings.provider == .local {
                    ModelStoragePanel(runtime: runtime, settings: settings)
                    ModelBenchmarkPanel(runtime: runtime, settings: settings)
                }

                if settings.provider == .custom {
                    SettingsTextField(
                        title: "Custom endpoint URL",
                        text: customEndpointBinding,
                        symbol: "link"
                    )
                    .keyboardType(.URL)
                }
            }
        }
    }

    private var credentialSection: some View {
        SettingsSection(title: "\(settings.provider.credentialDisplayName) Key", subtitle: settings.provider.credentialHelpText) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Group {
                        if showKey {
                            TextField(keyPlaceholder, text: $apiKey)
                        } else {
                            SecureField(keyPlaceholder, text: $apiKey)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: apiKey) {
                        connectionResult = nil
                    }

                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        showKey.toggle()
                    } label: {
                        ZStack {
                            Color.clear
                            Image(systemName: showKey ? "eye.slash" : "eye")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(AgentPalette.secondaryText)
                        }
                        .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(width: AgentDesign.minimumTouchTarget, height: AgentDesign.minimumTouchTarget)
                    .contentShape(Rectangle())
                    .accessibilityLabel(showKey ? "Hide API key" : "Reveal API key")
                    .accessibilityIdentifier("settingsAPIKeyRevealButton")
                }
                .padding(12)
                .agentSurface(radius: 14, tint: settings.provider.tint.opacity(0.08))

                HStack(spacing: 10) {
                    SettingsActionButton(title: "Save", symbol: "key.fill", tint: settings.provider.tint, prominent: true) {
                        saveKey()
                    }

                    SettingsActionButton(
                        title: testingConnection ? "Testing" : "Test",
                        symbol: testingConnection ? "hourglass" : "checkmark.shield",
                        tint: AgentPalette.green,
                        prominent: false
                    ) {
                        testConnection()
                    }
                    .disabled(testingConnection || (settings.provider != .local && apiKey.isEmpty))
                }

                if !savedKeyNotice.isEmpty {
                    Text(savedKeyNotice)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(2)
                }

                ConnectionResultView(result: connectionResult)
            }
        }
    }

    private var codexTerminalSection: some View {
        SettingsSection(title: "Codex Terminal", subtitle: "Simulated CLI-style login flow inside NovaForge") {
            VStack(alignment: .leading, spacing: 12) {
                CodexTerminalWindow(
                    lines: codexTerminalLines,
                    code: codexTerminalCode,
                    isPaired: codexTerminalPaired,
                    isRunning: codexTerminalRunning
                )

                HStack(spacing: 8) {
                    SettingsActionButton(title: codexTerminalRunning ? "Running" : "Start", symbol: "terminal.fill", tint: AgentPalette.indigo, prominent: true) {
                        startCodexTerminalLogin()
                    }
                    .disabled(codexTerminalRunning)

                    SettingsActionButton(title: "Safari", symbol: "safari", tint: AgentPalette.blue, prominent: false) {
                        openCodexSafari()
                    }
                }

                HStack(spacing: 8) {
                    SettingsActionButton(title: "Copy Code", symbol: "doc.on.doc", tint: AgentPalette.cyan, prominent: false) {
                        copyCodexTerminalCode()
                    }
                    SettingsActionButton(title: "Finish", symbol: "checkmark.seal.fill", tint: AgentPalette.green, prominent: false) {
                        finishCodexTerminalLogin()
                    }
                }

                SettingsActionButton(title: "Reset Terminal", symbol: "arrow.counterclockwise", tint: AgentPalette.secondaryText, prominent: false) {
                    resetCodexTerminal()
                }

                Label("Simulated Codex setup works without any API key. Real ChatGPT/Codex subscription tokens are not exposed to third-party iOS apps; for 100% no-key model runs, use the Local on-device model below.", systemImage: "lock.shield")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(5)

                SettingsActionButton(title: "Use Local No-Key Model", symbol: "cpu.fill", tint: AgentPalette.green, prominent: true) {
                    useLocalNoKeyModel()
                }
            }
        }
        .accessibilityIdentifier("codexTerminalSection")
    }

    private var localModelSection: some View {
        SettingsSection(title: "On-Device Model", subtitle: "Private local coding, tuned for iPhone memory limits") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(LocalModelCatalog.all) { variant in
                    LocalModelVariantRow(
                        variant: variant,
                        selected: settings.modelID == variant.id,
                        status: runtime.localModels.selectedVariantID == variant.id ? runtime.localModels.status : nil
                    ) {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        let previousVariantID = runtime.localModels.selectedVariantID
                        guard runtime.localModels.select(variant) else {
                            return
                        }
                        persistSettingsChange(
                            rollbackUI: {
                                runtime.localModels.selectedVariantID = previousVariantID
                            }
                        ) {
                            $0.modelID = variant.id
                        }
                    }
                }

                LocalModelDownloadPanel(manager: runtime.localModels)
            }
        }
    }

    private var presetSection: some View {
        SettingsSection(title: "Presets", subtitle: "Switch behavior without hunting through fields") {
            VStack(spacing: 8) {
                SettingsPresetRow(
                    title: "Code Architect",
                    subtitle: "Low temperature, stricter iOS implementation style",
                    symbol: "cpu",
                    tint: AgentPalette.lilac,
                    selected: settings.temperature == 0.1 && settings.customSystemPrompt?.contains("architect") == true
                ) {
                    applyPreset(
                        temp: 0.1,
                        prompt: "You are an expert iOS software architect. Write clean, modular, and extremely optimized Swift code. Adhere strictly to SOLID principles."
                    )
                }

                SettingsPresetRow(
                    title: "Creative Builder",
                    subtitle: "Higher temperature for exploration and UI ideas",
                    symbol: "sparkles",
                    tint: AgentPalette.rose,
                    selected: settings.temperature == 0.8 && settings.customSystemPrompt?.contains("creative") == true
                ) {
                    applyPreset(
                        temp: 0.8,
                        prompt: "You are a creative writer and brainstorming agent. Explore diverse ideas, explain concepts clearly, and suggest innovative approaches."
                    )
                }

                SettingsPresetRow(
                    title: "Balanced Default",
                    subtitle: "Default prompt with measured creativity",
                    symbol: "slider.horizontal.3",
                    tint: AgentPalette.green,
                    selected: settings.temperature == 0.2 && settings.customSystemPrompt == nil
                ) {
                    applyPreset(temp: 0.2, prompt: "")
                }
            }
        }
    }

    private var behaviorSection: some View {
        SettingsSection(title: "Behavior", subtitle: "Tune autonomy and response style") {
            VStack(alignment: .leading, spacing: 13) {
                SettingsSafetyModePicker(autoApproveWrites: settings.autoApproveWrites) { newValue in
                    autoApproveWritesBinding.wrappedValue = newValue
                }

                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Label("Temperature", systemImage: "thermometer.medium")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(String(format: "%.1f", draftTemperature))
                            .font(.caption.monospacedDigit().weight(.bold))
                            .foregroundStyle(settings.provider.tint)
                    }

                    Slider(value: $draftTemperature, in: 0.0...1.0, step: 0.1)
                }

                VStack(alignment: .leading, spacing: 7) {
                    Label("System Prompt", systemImage: "doc.text.below.ecg")
                        .font(.subheadline.weight(.semibold))

                    TextEditor(text: $draftSystemPrompt)
                    .font(.system(.callout, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 96)
                    .padding(8)
                    .agentSurface(radius: 14, tint: AgentPalette.lilac.opacity(0.08))
                }

                SettingsResetButton {
                    confirmingWorkspaceReset = true
                }
            }
        }
    }

    private var diagnosticsSection: some View {
        SettingsSection(title: "Diagnostics", subtitle: "Current health without log noise") {
            SettingsDiagnosticsPanel(items: diagnosticsItems)
        }
    }

    private var appearanceSection: some View {
        SettingsSection(title: "Theme Worlds", subtitle: "Complete visual modes for every NovaForge surface") {
            VStack(spacing: 8) {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8)
                    ],
                    spacing: 8
                ) {
                    ForEach(AgentTheme.allCases) { theme in
                        SettingsThemeStudioCard(
                            theme: theme,
                            selected: selectedTheme == theme
                        ) {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            selectedThemeRawValue = theme.rawValue
                            AgentPalette.refreshThemeCache(theme)
                            AgentThemeUIKit.apply(theme)
                            triggerSaveNotice()
                        }
                    }
                }

                #if DEBUG
                Divider()
                    .overlay(AgentPalette.border.opacity(0.34))
                    .padding(.vertical, 4)

                Toggle(isOn: $performanceModeEnabled) {
                    Label("Performance Mode", systemImage: "speedometer")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AgentPalette.ink)
                }
                .toggleStyle(.switch)
                .padding(.horizontal, 12)
                .frame(minHeight: AgentDesign.minimumTouchTarget, alignment: .center)
                .agentRowSurface(radius: 14, tint: AgentPalette.green, selected: performanceModeEnabled)
                .accessibilityIdentifier("settingsPerformanceModeToggle")
                .onChange(of: performanceModeEnabled) { _, _ in
                    AgentPerformance.invalidatePerformanceModeCache()
                }
                #endif
            }
        }
    }

    private var modelChoices: [String] {
        uniqueModels(settings.provider.modelOptions + providerModels + [settings.modelID, customModel])
    }

    private func uniqueModels(_ models: [String]) -> [String] {
        var seen = Set<String>()
        return models.compactMap { model in
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }

    @discardableResult
    private func selectModel(_ model: String) -> Bool {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let saved = persistSettingsChange {
            $0.modelID = trimmed
        }
        if saved {
            customModel = trimmed
        }
        return saved
    }

    private func loadProviderModels() {
        guard settings.provider != .local else { return }
        guard !loadingProviderModels else { return }
        let requestedProvider = settings.provider
        let savedKey = runtime.apiKey(for: requestedProvider)
        guard !savedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            providerModelError = "\(requestedProvider.missingCredentialMessage) Built-in model IDs are examples only; add a key before running them."
            providerModels = []
            return
        }
        loadingProviderModels = true
        providerModelError = nil

        let configuration = ProviderConfiguration(
            provider: requestedProvider,
            modelID: settings.modelID,
            apiKey: runtime.apiKey(for: requestedProvider),
            customChatCompletionsURL: settings.resolvedCustomChatCompletionsURL
        )

        providerModelTask?.cancel()
        providerModelTask = Task {
            do {
                let loaded = try await AIProviderClient(configuration: configuration).listModels()
                try Task.checkCancellation()
                await MainActor.run {
                    guard settings.provider == requestedProvider else { return }
                    providerModels = uniqueModels(loaded)
                    loadingProviderModels = false
                    providerModelTask = nil
                    if providerModels.isEmpty {
                        providerModelError = "No provider models returned. You can still paste an exact model id."
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard settings.provider == requestedProvider else { return }
                    loadingProviderModels = false
                    providerModelTask = nil
                }
            } catch {
                await MainActor.run {
                    guard settings.provider == requestedProvider else { return }
                    loadingProviderModels = false
                    providerModelTask = nil
                    providerModelError = "Could not load live \(requestedProvider.displayName) models. Showing built-in example IDs; add a key before running them or paste any exact model id if needed."
                }
            }
        }
    }

    private func startCodexTerminalLogin() {
        codexTerminalCode = makeCodexDeviceCode()
        codexTerminalPaired = false
        codexTerminalRunning = true
        codexTerminalLines = [
            "$ codex login --device-auth",
            "Launching Safari sign-in…",
            "Device code: \(codexTerminalCode)",
            "Copy the code, tap Yes it’s me, then paste it.",
            "Waiting for confirmation…"
        ]
        openCodexSafari()
        codexTerminalTask?.cancel()
        codexTerminalTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            codexTerminalLines.append("Safari opened. Return here after the browser confirms login.")
            codexTerminalRunning = false
        }
    }

    private func finishCodexTerminalLogin() {
        codexTerminalRunning = false
        codexTerminalPaired = true
        appendCodexTerminalLine("✓ Simulated Codex CLI flow complete. No key needed for this setup simulation; use Local for real no-key model runs.")
        triggerSaveNotice()
    }

    private func resetCodexTerminal() {
        codexTerminalRunning = false
        codexTerminalPaired = false
        codexTerminalCode = "NOVA-CODEX"
        codexTerminalLines = [
            "$ codex login --device-auth",
            "Simulated setup is fully local/no-key. Use Local for real no-key model runs."
        ]
        triggerSaveNotice()
    }

    private func copyCodexTerminalCode() {
        UIPasteboard.general.string = codexTerminalCode
        appendCodexTerminalLine("Copied code \(codexTerminalCode) to clipboard.")
        triggerSaveNotice()
    }

    private func openCodexSafari() {
        if let url = URL(string: "https://chatgpt.com/codex") {
            openURL(url)
        }
    }

    private func appendCodexTerminalLine(_ line: String) {
        codexTerminalLines.append(line)
        if codexTerminalLines.count > 8 {
            codexTerminalLines.removeFirst(codexTerminalLines.count - 8)
        }
    }

    private func makeCodexDeviceCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let left = String((0..<4).map { _ in alphabet.randomElement() ?? "N" })
        let right = String((0..<4).map { _ in alphabet.randomElement() ?? "F" })
        return "\(left)-\(right)"
    }

    private var selectedTheme: AgentTheme {
        AgentTheme.resolved(from: selectedThemeRawValue)
    }

    private var modelReadinessStats: [SettingsMiniStat] {
        if let variant = LocalModelCatalog.variant(for: settings.modelID) {
            return [
                SettingsMiniStat(label: "Context", value: "\(variant.contextTokens)"),
                SettingsMiniStat(label: "Size", value: variant.expectedSizeLabel),
                SettingsMiniStat(label: "Engine", value: variant.executionLabel)
            ]
        }

        let modelSource = providerModels.contains(settings.modelID) ? "Live list" : "Manual ID"
        return [
            SettingsMiniStat(label: "Provider", value: settings.provider.shortName),
            SettingsMiniStat(label: "Source", value: modelSource),
            SettingsMiniStat(label: "Safety", value: settings.autoApproveWrites ? "Auto" : "Review")
        ]
    }

    private var diagnosticsItems: [SettingsDiagnosticItem] {
        [
            SettingsDiagnosticItem(
                id: "provider",
                title: "Provider route",
                value: settings.provider.displayName,
                detail: settingsReadinessDetail,
                symbol: settings.provider.symbol,
                tint: settings.provider.tint
            ),
            SettingsDiagnosticItem(
                id: "model",
                title: "Model state",
                value: settings.provider == .local ? runtime.localModels.status.title : "Selected",
                detail: settings.provider == .local ? localModelStatusDetail : modelReadinessDetail,
                symbol: "cpu.fill",
                tint: settings.provider == .local ? settingsReadinessTint : AgentPalette.secondaryAccent
            ),
            SettingsDiagnosticItem(
                id: "safety",
                title: "Approval gate",
                value: safetyModeTitle,
                detail: safetyModeDetail,
                symbol: settings.autoApproveWrites ? "bolt.badge.checkmark.fill" : "checkmark.shield.fill",
                tint: safetyModeTint
            )
        ]
    }

    private func providerReadiness(for provider: AIProvider) -> (title: String, tint: Color) {
        if provider == .local {
            switch runtime.localModels.status {
            case .ready:
                return ("Ready", AgentPalette.green)
            case .downloading:
                return ("Downloading", AgentPalette.lilac)
            case .partial:
                return ("Resume", AgentPalette.lilac)
            case .missing:
                return ("Download", AgentPalette.cyan)
            case .checking:
                return ("Checking", AgentPalette.lilac)
            case .incompatible, .failed:
                return ("Attention", AgentPalette.rose)
            }
        }

        let hasKey = !runtime.apiKey(for: provider).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if provider == .custom && settings.resolvedCustomChatCompletionsURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ("URL needed", AgentPalette.warning)
        }
        return hasKey ? ("Key saved", AgentPalette.green) : ("Needs key", AgentPalette.warning)
    }

    private var keyPlaceholder: String {
        switch settings.provider {
        case .openAI, .openAICodex: "sk-..."
        case .openRouter: "sk-or-..."
        case .openCodeZen: "opencode zen key"
        case .local: "No key needed"
        case .custom: "provider key"
        }
    }

    private var customEndpointBinding: Binding<String> {
        Binding(
            get: { settings.resolvedCustomChatCompletionsURL },
            set: { newValue in
                settings.resolvedCustomChatCompletionsURL = newValue
                scheduleSettingsSave(showToast: false)
            }
        )
    }

    private var autoApproveWritesBinding: Binding<Bool> {
        Binding(
            get: { settings.autoApproveWrites },
            set: { newValue in
                _ = persistSettingsChange {
                    $0.autoApproveWrites = newValue
                }
            }
        )
    }

    private func prepare() {
        let staleSelectionSnapshot = AgentSettingsPersistence.snapshot(settings)
        if settings.repairStaleModelSelection() {
            do {
                try modelContext.save()
            } catch {
                AgentSettingsPersistence.restore(staleSelectionSnapshot, to: settings)
                presentSettingsSaveError(error)
            }
        }
        reloadKey()
        customModel = settings.modelID
        draftTemperature = settings.temperature
        draftSystemPrompt = settings.customSystemPrompt ?? ""
        lastRecordedSettingsSnapshot = AgentSettingsPersistence.snapshot(settings)
        if let variant = LocalModelCatalog.variant(for: settings.modelID) {
            runtime.localModels.select(variant)
        }

        #if DEBUG || targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--open-model-picker-demo"), !didPresentModelPickerDemo {
            didPresentModelPickerDemo = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                showingModelPicker = true
            }
        }
        #endif
    }

    private func modelDisplayName(_ model: String) -> String {
        LocalModelCatalog.variant(for: model)?.shortName ?? model
    }

    @MainActor
    private func scheduleSettingsSave(showToast: Bool) {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                let previousSnapshot = lastRecordedSettingsSnapshot
                settings.updatedAt = Date()
                do {
                    try modelContext.save()
                } catch {
                    presentSettingsSaveError(error)
                    return
                }
                recordSettingsChangeIfNeeded(from: previousSnapshot)
                if showToast {
                    triggerSaveNotice()
                }
            }
        }
    }

    @MainActor
    private func scheduleDraftBehaviorSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                flushPendingSettingsSave()
            }
        }
    }

    @MainActor
    private func flushPendingSettingsSave() {
        let previousSnapshot = lastRecordedSettingsSnapshot
        let normalizedPrompt = draftSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.temperature = draftTemperature
        settings.customSystemPrompt = normalizedPrompt.isEmpty ? nil : draftSystemPrompt
        settings.updatedAt = Date()
        do {
            try modelContext.save()
            recordSettingsChangeIfNeeded(from: previousSnapshot)
        } catch {
            savedKeyNotice = "Could not save settings: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func triggerSaveNotice() {
        toastHideTask?.cancel()
        if !showSavedToast {
            withAnimation(.easeOut(duration: 0.16)) {
                showSavedToast = true
            }
        }
        toastHideTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1150))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                showSavedToast = false
            }
        }
    }

    private func saveKey() {
        do {
            try runtime.saveAPIKey(apiKey, for: settings.provider)
            savedKeyNotice = apiKey.isEmpty ? "\(settings.provider.credentialDisplayName) key removed." : "\(settings.provider.credentialDisplayName) key saved."
            recordSettingsTimelineEvent(
                title: "Credential updated",
                detail: apiKey.isEmpty ? "\(settings.provider.credentialDisplayName) key removed" : "\(settings.provider.credentialDisplayName) key saved"
            )
            triggerSaveNotice()
        } catch {
            savedKeyNotice = error.localizedDescription
        }
    }

    private func reloadKey() {
        apiKey = runtime.apiKey(for: settings.provider)
        savedKeyNotice = ""
        connectionResult = nil
    }

    private func testConnection() {
        if settings.provider != .local {
            saveKey()
        }
        testingConnection = true
        connectionResult = nil

        let provider = settings.provider
        let modelID = settings.modelID
        let customURL = settings.resolvedCustomChatCompletionsURL

        connectionTestTask?.cancel()
        connectionTestTask = Task {
            let result = await runtime.testConnection(
                provider: provider,
                modelID: modelID,
                customChatCompletionsURL: customURL
            )
            guard !Task.isCancelled else { return }
            guard settings.provider == provider,
                  settings.modelID == modelID,
                  settings.resolvedCustomChatCompletionsURL == customURL else {
                testingConnection = false
                connectionResult = nil
                return
            }
            testingConnection = false
            connectionResult = result
        }
    }

    private func applyPreset(temp: Double, prompt: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let previousDraftTemperature = draftTemperature
        let previousDraftPrompt = draftSystemPrompt
        draftTemperature = temp
        draftSystemPrompt = prompt
        persistSettingsChange(
            rollbackUI: {
                draftTemperature = previousDraftTemperature
                draftSystemPrompt = previousDraftPrompt
            }
        ) {
            $0.temperature = temp
            $0.customSystemPrompt = prompt.isEmpty ? nil : prompt
        }
    }

    private func useLocalNoKeyModel() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let variant = LocalModelCatalog.defaultVariant
        let previousVariantID = runtime.localModels.selectedVariantID
        guard runtime.localModels.select(variant) else { return }
        let saved = persistSettingsChange(
            rollbackUI: {
                runtime.localModels.selectedVariantID = previousVariantID
            }
        ) {
            $0.provider = .local
            $0.modelID = variant.id
        }
        guard saved else { return }
        customModel = variant.id
        providerModels = []
        providerModelError = nil
        loadingProviderModels = false
        savedKeyNotice = "Local no-key model selected. Download it below if it is not installed yet."
    }

    @discardableResult
    private func persistSettingsChange(
        showToast: Bool = true,
        rollbackUI: (() -> Void)? = nil,
        mutate: (AgentSettings) -> Void
    ) -> Bool {
        let previousSnapshot = lastRecordedSettingsSnapshot ?? AgentSettingsPersistence.snapshot(settings)
        do {
            try AgentSettingsPersistence.persist(
                settings: settings,
                mutate: mutate,
                save: { try modelContext.save() }
            )
            recordSettingsChangeIfNeeded(from: previousSnapshot)
            if showToast {
                triggerSaveNotice()
            }
            return true
        } catch {
            rollbackUI?()
            presentSettingsSaveError(error)
            return false
        }
    }

    private func recordSettingsChangeIfNeeded(
        from previousSnapshot: AgentSettingsPersistence.Snapshot?,
        title: String = "Settings changed"
    ) {
        let currentSnapshot = AgentSettingsPersistence.snapshot(settings)
        let previous = previousSnapshot ?? lastRecordedSettingsSnapshot ?? currentSnapshot
        defer {
            lastRecordedSettingsSnapshot = currentSnapshot
        }
        guard let detail = AgentSettingsPersistence.materialExecutionChangeDetail(from: previous, to: currentSnapshot) else {
            return
        }
        recordSettingsTimelineEvent(title: title, detail: detail, updateSnapshot: false)
    }

    private func recordSettingsTimelineEvent(
        title: String,
        detail: String,
        updateSnapshot: Bool = true
    ) {
        ProjectEventRecorder.recordSettingsChange(
            project: project,
            detail: detail,
            title: title,
            context: modelContext
        )
        do {
            try modelContext.save()
            if updateSnapshot {
                lastRecordedSettingsSnapshot = AgentSettingsPersistence.snapshot(settings)
            }
        } catch {
            presentSettingsSaveError(error)
        }
    }

    private func presentSettingsSaveError(_ error: Error) {
        settingsSaveError = "NovaForge could not save that provider/model change. Your previous setting is still active. \(error.localizedDescription)"
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

private struct SettingsProjectContextStrip: View {
    let project: Project

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(AgentPalette.cyan)
                .frame(width: 28, height: 28)
                .agentControlSurface(radius: 9, tint: AgentPalette.cyan.opacity(0.10), selected: false)

            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.system(size: 11, weight: .bold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                Text("Workspace: \(project.workspaceName)")
                    .font(.system(size: 9, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(9)
        .agentSurface(radius: 14, tint: AgentPalette.cyan.opacity(0.04))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settingsProjectContextStrip")
    }
}

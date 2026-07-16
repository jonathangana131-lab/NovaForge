import AgentPolicy
import AgentTools
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    var runtime: AgentRuntime
    var project: Project
    @Bindable var settings: AgentSettings
    @State private var apiKey = ""
    @State private var savedKeyNotice = ""
    @State private var testingConnection = false
    @State private var connectionResult: Result<Void, Error>?
    @State private var showKey = false
    @State private var showSavedToast = false
    @State private var saveTask: Task<Void, Never>?
    @State private var toastHideTask: Task<Void, Never>?
    @State private var providerModelTask: Task<Void, Never>?
    @State private var connectionTestTask: Task<Void, Never>?
    @State private var showingModelPicker = false
    @State private var codexAuth = OpenAICodexAuthManager.shared
    @State private var didPresentModelPickerDemo = false
    @State private var providerModels: [String] = []
    @State private var loadingProviderModels = false
    @State private var providerModelError: String? = nil
    @State private var settingsSaveError: String? = nil
    @State private var draftTemperature = 0.2
    @State private var draftSystemPrompt = ""
    @State private var resetWorkspaceError: String?
    @State private var workspaceResetTask: Task<Void, Never>?
    @State private var workspaceResetOperationID: UUID?
    @State private var lastRecordedSettingsSnapshot: AgentSettingsPersistence.Snapshot?
    @AppStorage(AgentTheme.storageKey) private var selectedThemeRawValue = AgentTheme.defaultTheme.rawValue
    @AppStorage(AgentPerformance.storageKey) private var performanceModeEnabled = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                NovaGlassSheetBackground(tint: AgentPalette.primaryAccent)

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
                                buildLabel: bundleVersionLabel,
                                buildDetail: compactBuildDiagnosticsDetail,
                                theme: selectedTheme
                            )
                            .accessibilityIdentifier("settingsCommandDeck")

                            providerSection
                            modelSection
                            presetSection

                            if settings.provider == .openAICodex {
                                codexSubscriptionSection
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
                    .padding(.top, controlContentTopPadding(for: geometry.safeAreaInsets.top))
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
        }
        .accessibilityIdentifier("settingsRoot")
        .onAppear(perform: prepare)
        .onDisappear {
            flushPendingSettingsSave()
            saveTask?.cancel()
            toastHideTask?.cancel()
            providerModelTask?.cancel()
            connectionTestTask?.cancel()
            workspaceResetTask?.cancel()
            workspaceResetTask = nil
            workspaceResetOperationID = nil
        }
        .onChange(of: settings.providerRawValue) {
            providerModels = []
            providerModelError = nil
            loadingProviderModels = false
            providerModelTask?.cancel()
            reloadKey()
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

    @MainActor
    private func startWorkspaceReset() {
        guard workspaceResetTask == nil else { return }

        let workspace = runtime.workspace
        let workspaceName = workspace.workspaceName
        let projectID = project.id
        let conversationID = runtime.activeConversationID
        let operationID = UUID()
        let acceptedAt = Date()
        workspaceResetOperationID = operationID

        workspaceResetTask = Task { @MainActor in
            defer {
                if workspaceResetOperationID == operationID {
                    workspaceResetTask = nil
                    workspaceResetOperationID = nil
                }
            }

            do {
                let policyRuntime = AgentPolicyMutationRuntime.shared
                let executionContext = try policyRuntime.makeExecutionContext(
                    workspace: workspace,
                    operationID: operationID,
                    idempotencyKey: Self.controlResetIdempotencyKey(
                        operationID: operationID
                    ),
                    conversationID: conversationID,
                    projectID: projectID,
                    acceptedAt: acceptedAt,
                    sessionID: "control"
                )
                _ = try await policyRuntime.coordinator().performControl(
                    context: executionContext,
                    operation: ControlPolicyMutationOperation.resetWorkspace(
                        ResetWorkspaceMutationArguments()
                    )
                )

                // Success presentation starts only after the typed coordinator
                // returns its digest receipt. Reset intentionally leaves an
                // empty root; later seed files need an independent receipt.
                runtime.noteWorkspaceChanged()
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

                if workspaceResetOperationID == operationID {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    triggerSaveNotice()
                }
            } catch is CancellationError {
                return
            } catch let policyError as AgentPolicyMutationServiceError
                where policyError == .cancelled
            {
                return
            } catch {
                resetWorkspaceError = "Could not durably reset the workspace: \(error.localizedDescription)"
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private static func controlResetIdempotencyKey(
        operationID: UUID
    ) -> String {
        "control.reset-workspace.v1:\(operationID.uuidString.lowercased())"
    }


    private var credentialStatusText: String {
        if settings.provider == .local { return "Local" }
        if settings.provider == .openAICodex {
            return codexAuth.isSignedIn ? "Connected" : "Sign in"
        }
        return apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Needed" : "Saved"
    }

    private var credentialStatusTint: Color {
        if settings.provider == .local { return AgentPalette.green }
        if settings.provider == .openAICodex {
            return codexAuth.isSignedIn ? AgentPalette.green : AgentPalette.warning
        }
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
        if settings.provider == .openAICodex {
            return codexAuth.isSignedIn ? "Ready to run" : "Sign in with ChatGPT"
        }
        if settings.provider == .custom,
           let customEndpointValidationMessage {
            return customEndpointValidationMessage == Self.missingCustomEndpointMessage
                ? "Endpoint required"
                : "Fix endpoint URL"
        }
        return apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "API key required" : "Ready to run"
    }

    private var settingsReadinessDetail: String {
        if settings.provider == .local {
            return localModelStatusDetail
        }
        if settings.provider == .openAICodex {
            return codexAuth.isSignedIn
                ? "ChatGPT is connected · supported GPT agent runs use your eligible subscription allowance"
                : "Connect your ChatGPT account below before starting a run"
        }
        if settings.provider == .custom,
           let customEndpointValidationMessage {
            return customEndpointValidationMessage
        }
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Save a \(settings.provider.displayName) key before live hosted runs"
        }
        return "\(settings.provider.displayName) key saved · \(settings.autoApproveWrites ? "auto writes" : "asks before writes")"
    }

    private var customEndpointValidationMessage: String? {
        guard settings.provider == .custom else { return nil }
        let trimmed = settings.resolvedCustomChatCompletionsURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Self.missingCustomEndpointMessage }
        let configuration = ProviderConfiguration(
            provider: .custom,
            modelID: settings.modelID,
            apiKey: "",
            customChatCompletionsURL: trimmed
        )
        guard configuration.chatCompletionsURL != nil else {
            return "Use a valid http:// or https:// endpoint with a host. Keep API keys in the key field, not in the URL."
        }
        return nil
    }

    private static let missingCustomEndpointMessage = "Add a chat completions URL before custom provider runs."

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
        if settings.provider == .openAICodex {
            return codexAuth.isSignedIn ? "checkmark.shield.fill" : "person.badge.key.fill"
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
        if settings.provider == .openAICodex {
            return codexAuth.isSignedIn ? AgentPalette.green : AgentPalette.warning
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
            return customEndpointValidationMessage ?? "Custom endpoint configured"
        }
        if settings.provider == .openAICodex {
            return codexAuth.isSignedIn
                ? "ChatGPT connected · live GPT catalog"
                : "ChatGPT sign-in needed"
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

    private var providerSection: some View {
        SettingsSection(title: "Provider", subtitle: "Choose the API route for new runs") {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ],
                spacing: 8
            ) {
                ForEach(AIProvider.agentRuntimeProviders) { provider in
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
        SettingsSection(title: "Model", subtitle: "Choose a model validated for agent runs") {
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

                    if let customEndpointValidationMessage {
                        Label(customEndpointValidationMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AgentPalette.warning)
                            .lineLimit(3)
                            .accessibilityIdentifier("settingsCustomEndpointValidation")
                    }
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
                        title: testingConnection ? "Checking" : "Check key",
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

                if settings.provider == .openCodeZen,
                   let zenURL = URL(string: "https://opencode.ai/auth")
                {
                    Link(destination: zenURL) {
                        Label("Create or open a Zen key", systemImage: "safari.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(settings.provider.tint)
                    }
                    Label(
                        "Zen is hosted: even free models require a Zen account and key, and limited-time availability can change.",
                        systemImage: "cloud.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(AgentPalette.secondaryText)
                }
            }
        }
    }

    private var codexSubscriptionSection: some View {
        SettingsSection(
            title: "ChatGPT subscription",
            subtitle: "Secure device-code sign-in for supported GPT usage included with eligible ChatGPT plans"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: codexAuth.isSignedIn
                        ? "checkmark.shield.fill"
                        : "person.badge.key.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(codexAuth.isSignedIn
                            ? AgentPalette.green
                            : AIProvider.openAICodex.tint)
                        .frame(width: 42, height: 42)
                        .background(
                            Circle().fill(
                                AIProvider.openAICodex.tint.opacity(0.11)
                            )
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(codexAuthTitle)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(AgentPalette.ink)
                        Text(codexAuthDetail)
                            .font(.caption)
                            .foregroundStyle(AgentPalette.secondaryText)
                            .lineLimit(4)
                    }
                    Spacer(minLength: 4)
                }

                if let code = codexAuth.userCode {
                    VStack(spacing: 10) {
                        Text("ENTER THIS CODE")
                            .font(.caption2.weight(.black))
                            .tracking(1.1)
                            .foregroundStyle(AgentPalette.secondaryText)
                        Text(code)
                            .font(.system(.title2, design: .monospaced, weight: .bold))
                            .textSelection(.enabled)
                            .foregroundStyle(AIProvider.openAICodex.tint)

                        HStack(spacing: 8) {
                            SettingsActionButton(
                                title: "Copy code",
                                symbol: "doc.on.doc",
                                tint: AgentPalette.cyan,
                                prominent: false
                            ) {
                                UIPasteboard.general.string = code
                                UINotificationFeedbackGenerator()
                                    .notificationOccurred(.success)
                            }
                            SettingsActionButton(
                                title: "Open ChatGPT",
                                symbol: "safari.fill",
                                tint: AgentPalette.blue,
                                prominent: true
                            ) {
                                codexAuth.openVerificationPage()
                            }
                        }
                    }
                    .padding(14)
                    .agentSurface(
                        radius: 18,
                        tint: AIProvider.openAICodex.tint.opacity(0.09)
                    )
                    .accessibilityIdentifier("codexDeviceCodePanel")
                }

                HStack(spacing: 8) {
                    if codexAuth.isSignedIn {
                        SettingsActionButton(
                            title: "Sign out",
                            symbol: "rectangle.portrait.and.arrow.right",
                            tint: AgentPalette.rose,
                            prominent: false
                        ) {
                            codexAuth.signOut()
                        }
                    } else if codexAuth.state.isWorking {
                        SettingsActionButton(
                            title: "Cancel",
                            symbol: "xmark",
                            tint: AgentPalette.rose,
                            prominent: false
                        ) {
                            codexAuth.cancelLogin()
                        }
                    } else {
                        SettingsActionButton(
                            title: "Sign in with ChatGPT",
                            symbol: "person.crop.circle.badge.checkmark",
                            tint: AIProvider.openAICodex.tint,
                            prominent: true
                        ) {
                            codexAuth.startLogin()
                        }
                    }
                }

                Label(
                    "NovaForge never asks for your ChatGPT password. OpenAI returns a one-time code; access and refresh tokens are stored only in this device’s Keychain.",
                    systemImage: "lock.shield.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(AgentPalette.secondaryText)
                .lineLimit(5)
            }
        }
        .accessibilityIdentifier("codexSubscriptionSection")
    }

    private var codexAuthTitle: String {
        switch codexAuth.state {
        case .signedOut: "Not connected"
        case .requestingCode: "Requesting a secure code…"
        case .awaitingApproval: "Waiting for approval…"
        case .exchanging: "Finishing sign-in…"
        case .signedIn: "ChatGPT connected"
        case .failed: "Sign-in needs attention"
        }
    }

    private var codexAuthDetail: String {
        switch codexAuth.state {
        case .signedOut:
            "Connect once, then refresh the available GPT models for new agent runs."
        case .requestingCode:
            "Contacting OpenAI’s authorization service."
        case let .awaitingApproval(_, expiresAt):
            "Approve in the browser. This code expires at \(expiresAt.formatted(date: .omitted, time: .shortened))."
        case .exchanging:
            "Saving the approved credential securely."
        case let .signedIn(accountID):
            accountID.map { "Connected account · \(String($0.prefix(8)))…" }
                ?? "Ready to use your eligible ChatGPT allowance."
        case let .failed(message):
            message
        }
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

                SettingsResetButton(action: startWorkspaceReset)
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
        uniqueModels(settings.provider.modelOptions + providerModels + [settings.modelID])
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
        return saved
    }

    private func loadProviderModels() {
        guard settings.provider != .local else { return }
        guard !loadingProviderModels else { return }
        let requestedProvider = settings.provider
        let savedKey = runtime.apiKey(for: requestedProvider)
        guard requestedProvider == .openCodeZen ||
                !savedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            providerModelError = "\(requestedProvider.missingCredentialMessage) The built-in list contains only agent-compatible choices."
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
                let loaded = try await AIProviderClient(configuration: configuration).modelCatalog()
                try Task.checkCancellation()
                await MainActor.run {
                    guard settings.provider == requestedProvider else { return }
                    providerModels = uniqueModels(
                        loaded.map(\.id).filter(requestedProvider.modelOptions.contains)
                    )
                    loadingProviderModels = false
                    providerModelTask = nil
                    if providerModels.isEmpty {
                        providerModelError = "No models compatible with NovaForge's canonical agent route were returned. Built-in validated choices remain available."
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
                    providerModelError = "Could not refresh live \(requestedProvider.displayName) models. Showing the built-in agent-compatible catalog."
                }
            }
        }
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

        let modelSource = providerModels.contains(settings.modelID) ? "Live list" : "Built-in"
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
            ),
            SettingsDiagnosticItem(
                id: "build",
                title: "App build",
                value: bundleVersionLabel,
                detail: buildDiagnosticsDetail,
                symbol: "iphone.gen3",
                tint: AgentPalette.cyan
            )
        ]
    }

    private var bundleVersionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let build = (info?["CFBundleVersion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch (version.isEmpty, build.isEmpty) {
        case (false, false): return "\(version) (\(build))"
        case (false, true): return version
        case (true, false): return "Build \(build)"
        case (true, true): return "Dev"
        }
    }

    private var buildDiagnosticsDetail: String {
        let identifier = Bundle.main.bundleIdentifier ?? "com.joey.NovaForge"
        #if DEBUG
        let lane = "Debug"
        #elseif targetEnvironment(simulator)
        let lane = "Simulator Release"
        #else
        let lane = "Device Release"
        #endif
        return "\(lane) · \(identifier)"
    }

    private var compactBuildDiagnosticsDetail: String {
        let identifier = Bundle.main.bundleIdentifier ?? "com.joey.NovaForge"
        #if DEBUG
        let lane = "Debug"
        #elseif targetEnvironment(simulator)
        let lane = "Simulator"
        #else
        let lane = "Device"
        #endif
        return "\(lane) · \(identifier)"
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

        if provider == .openAICodex {
            return codexAuth.isSignedIn
                ? ("Connected", AgentPalette.green)
                : ("Sign in", AgentPalette.warning)
        }

        let hasKey = !runtime.apiKey(for: provider).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if provider == .custom && settings.resolvedCustomChatCompletionsURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ("URL needed", AgentPalette.warning)
        }
        return hasKey ? ("Key saved", AgentPalette.green) : ("Needs key", AgentPalette.warning)
    }

    private var keyPlaceholder: String {
        switch settings.provider {
        case .openAI: "sk-..."
        case .openAICodex: "Sign in above"
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

    private func controlContentTopPadding(for topSafeArea: CGFloat) -> CGFloat {
        max(28, topSafeArea + 10)
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

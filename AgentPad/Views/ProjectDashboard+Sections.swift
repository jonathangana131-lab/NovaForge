//
//  ProjectDashboard+Sections.swift
//  NovaForge
//
//  Detail sections: more panel, project creation/switcher, review, deep
//  plan, spine, command intake, Mission OS panel.
//

import SwiftData
import SwiftUI

extension ProjectDashboardView {

    var projectDetailScopePicker: some View {
        HStack(spacing: 6) {
            ForEach(ProjectDetailScope.allCases) { scope in
                let isSelected = selectedDetailScope == scope
                Button {
                    NovaHaptics.lensChanged()
                    withAnimation(.smooth(duration: 0.22)) {
                        selectedDetailScope = scope
                    }
                } label: {
                    Text(scope.title)
                        .font(NovaType.caption)
                        .foregroundStyle(isSelected ? AgentPalette.ink : AgentPalette.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(
                            Capsule(style: .continuous)
                                .fill(isSelected ? projectOSTint.opacity(0.16) : Color.clear)
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(
                                    isSelected ? projectOSTint.opacity(0.42) : AgentPalette.controlBorder.opacity(0.4),
                                    lineWidth: 0.8
                                )
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show \(scope.title)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectDetailScopePicker")
    }


    var projectSwitcherSheet: some View {
        ZStack {
            AgentBackground()
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 10) {
                    Label("Projects", systemImage: "rectangle.stack.fill")
                        .font(.system(size: 18, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)

                    Spacer(minLength: 0)

                    Text("\(projects.count)")
                        .font(.system(size: 11, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.primaryAccent)
                        .padding(.horizontal, 9)
                        .frame(height: 26)
                        .background(AgentPalette.primaryAccent.opacity(0.10), in: Capsule(style: .continuous))
                }

                GlassGroup(spacing: 12) {
                    VStack(spacing: 10) {
                        projectSwitcherList
                        projectCreationCard
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(18)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("projectSwitcherSheet")
    }

    var projectCreationCard: some View {
        HStack(alignment: .center, spacing: 11) {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(AgentPalette.primaryAccent)
                .frame(width: 34, height: 34)
                .agentControlSurface(radius: 11, tint: AgentPalette.primaryAccent.opacity(0.12), selected: true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Create Project")
                    .font(.system(size: 13, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                Text("Start a separate agent workspace")
                    .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button {
                createAndDismissProject()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(AgentPalette.ink)
            }
            .buttonStyle(.plain)
            .frame(width: 48, height: 48)
            .contentShape(Rectangle())
            .agentGlass(radius: 14, interactive: true, tint: AgentPalette.primaryAccent.opacity(0.16))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Create Project")
            .accessibilityHint("Start a separate agent workspace.")
            .accessibilityIdentifier("projectNewButton")
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: AgentDesign.minimumTouchTarget, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .agentGlass(radius: 16, interactive: true, tint: AgentPalette.primaryAccent.opacity(0.14))
        .overlay(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(AgentPalette.primaryAccent.opacity(0.18), lineWidth: 0.6)
                .allowsHitTesting(false)
        }
        .shadow(color: AgentPalette.primaryAccent.opacity(0.08), radius: 10, x: 0, y: 5)
        .accessibilityElement(children: .contain)
    }

    func createAndDismissProject() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        showsProjectSwitcherSheet = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            showsProjectIntakeSheet = true
        }
    }

    var projectSwitcherList: some View {
        VStack(spacing: 4) {
            HStack {
                Label("Active projects", systemImage: "sidebar.leading")
                    .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                Spacer(minLength: 0)
                Text("\(projects.count)")
                    .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.primaryAccent)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(AgentPalette.primaryAccent.opacity(0.10), in: Capsule(style: .continuous))
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 2)

            VStack(spacing: 5) {
                ForEach(visibleSwitcherProjects, id: \.id) { candidate in
                    let isSelected = candidate.id == project.id
                    if isSelected {
                        projectSwitcherRow(candidate, isSelected: true)
                            .accessibilityElement(children: .ignore)
                            .accessibilityAddTraits(.isSelected)
                            .accessibilityLabel("Active project, \(candidate.name)")
                            .accessibilityHint("Already selected")
                            .accessibilityIdentifier("projectSwitcherActiveRow")
                    } else {
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation((reduceMotion || !AgentPerformance.allowsDecorativeMotion) ? nil : .smooth(duration: 0.42)) {
                                highlightedProjectID = candidate.id
                                selectProject(candidate)
                                showsProjectSwitcherSheet = false
                            }
                        } label: {
                            projectSwitcherRow(candidate, isSelected: false)
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Open project, \(candidate.name)")
                        .accessibilityHint(projectSwitchDetail(candidate))
                        .accessibilityIdentifier("projectSwitcherRow-\(projectSwitchIdentifier(candidate))")
                    }
                }

                if sortedProjects.count > 4 {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation((reduceMotion || !AgentPerformance.allowsDecorativeMotion) ? nil : .smooth(duration: 0.28)) {
                            showsAllProjects.toggle()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: showsAllProjects ? "chevron.up.circle.fill" : "ellipsis.circle.fill")
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(AgentPalette.primaryAccent)
                            Text(showsAllProjects ? "Show fewer projects" : "Show \(hiddenSwitcherProjectCount) more project\(hiddenSwitcherProjectCount == 1 ? "" : "s")")
                                .font(.system(size: 10.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                                .foregroundStyle(AgentPalette.secondaryText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 36)
                        .background(AgentPalette.primaryAccent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showsAllProjects ? "Show fewer projects" : "Show \(hiddenSwitcherProjectCount) more projects")
                    .accessibilityIdentifier("projectSwitcherMoreButton")
                }
            }
        }
        .padding(8)
        .agentGlass(radius: 20, interactive: false, tint: AgentPalette.primaryAccent.opacity(0.06))
        .animation((reduceMotion || !AgentPerformance.allowsDecorativeMotion) ? nil : .smooth(duration: 0.36), value: project.id)
        .animation((reduceMotion || !AgentPerformance.allowsDecorativeMotion) ? nil : .smooth(duration: 0.28), value: showsAllProjects)
    }

    func projectSwitcherRow(_ candidate: Project, isSelected: Bool) -> some View {
        let tint = isSelected ? AgentPalette.primaryAccent : AgentPalette.storageAccent
        return HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint.opacity(isSelected ? 0.14 : 0.08))
                Image(systemName: isSelected ? "checkmark.seal.fill" : "folder.fill")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(tint)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.name)
                    .font(.system(size: 12.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                    .accessibilityIdentifier(isSelected ? "projectSwitcherActiveName" : "projectSwitcherRowName-\(projectSwitchIdentifier(candidate))")
                Text(projectSwitchDetail(candidate))
                    .font(.system(size: 9.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            projectSwitcherStateBadge(isSelected: isSelected, projectName: candidate.name)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(minHeight: AgentDesign.minimumTouchTarget)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isSelected ? AgentPalette.primaryAccent.opacity(0.08) : AgentPalette.surface.opacity(0.34))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isSelected ? AgentPalette.primaryAccent.opacity(0.20) : AgentPalette.border.opacity(0.10), lineWidth: 0.55)
        )
        .overlay {
            if isSelected && highlightedProjectID == candidate.id {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(AgentPalette.primaryAccent.opacity(0.46), lineWidth: 1.1)
                    .blur(radius: 0.15)
                    .transition(.opacity)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .glassIDIfAvailable("project-switch-\(candidate.id.uuidString)", namespace: projectSwitchGlassNamespace)
        .scaleEffect(isSelected && highlightedProjectID == candidate.id ? 1.01 : 1.0)
        .animation((reduceMotion || !AgentPerformance.allowsDecorativeMotion) ? nil : .smooth(duration: 0.34), value: highlightedProjectID)
    }

    @ViewBuilder
    func projectSwitcherStateBadge(isSelected: Bool, projectName: String) -> some View {
        let tint = isSelected ? AgentPalette.primaryAccent : AgentPalette.storageAccent
        let badge = Text(isSelected ? "ACTIVE" : "OPEN")
            .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
            .foregroundStyle(isSelected ? tint : AgentPalette.secondaryText)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(isSelected ? 0.12 : 0.08))
            )

        if isSelected {
            badge
                .accessibilityLabel("Active project, \(projectName)")
                .accessibilityAddTraits(.isSelected)
                .accessibilityIdentifier("projectSwitcherActiveRow")
        } else {
            badge
        }
    }

    func projectSwitchDetail(_ candidate: Project) -> String {
        let projectID = candidate.id
        let chatCount = conversations.filter { $0.project?.id == projectID }.count
        let artifactCount = candidate.artifacts.count
        return "\(candidate.workspaceName) · \(chatCount) chat\(chatCount == 1 ? "" : "s") · \(artifactCount) artifact\(artifactCount == 1 ? "" : "s")"
    }

    func projectSwitchIdentifier(_ candidate: Project) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = candidate.workspaceName.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .joined()
        return sanitized.isEmpty ? candidate.id.uuidString : sanitized
    }

    var projectReviewSection: some View {
        let review = summary.review
        let tint = self.reviewTint(for: review.recommendation)
        return sectionShell(
            title: "Project Review",
            subtitle: "\(review.healthScore)% · \(review.recommendation.displayName)",
            symbol: review.recommendation.symbolName,
            tint: tint,
            usesGlass: true
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    projectReviewScoreGauge(score: review.healthScore, tint: tint)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(review.headline)
                            .font(.system(size: 15, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.ink)
                            .lineLimit(2)
                        Text(review.detail)
                            .font(.system(size: 11, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.secondaryText)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 8) {
                    missionOSStateBadge(
                        label: "Decision",
                        value: review.recommendation.displayName,
                        symbol: review.recommendation.symbolName,
                        tint: tint
                    )
                    missionOSStateBadge(
                        label: "Proof",
                        value: review.proofFreshness,
                        symbol: "checkmark.seal.fill",
                        tint: self.proofFreshnessTint
                    )
                    missionOSStateBadge(
                        label: "Risks",
                        value: "\(review.riskCount)",
                        symbol: review.riskCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                        tint: review.riskCount == 0 ? AgentPalette.green : AgentPalette.rose
                    )
                }

                VStack(spacing: 7) {
                    ForEach(review.findings) { finding in
                        projectReviewFindingRow(finding, compact: false)
                    }
                }
            }
            .accessibilityElement(children: .contain)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectReviewSection")
    }

    var projectPlanDeepSection: some View {
        let contract = summary.missionContract
        let tint = missionOSTint(for: contract)
        return sectionShell(
            title: "Project Plan",
            subtitle: "\(contract.phase.displayName) · \(contract.gateSummary)",
            symbol: contract.phase.symbolName,
            tint: tint
        ) {
            VStack(alignment: .leading, spacing: 12) {
                missionPhaseTrack(contract)

                VStack(alignment: .leading, spacing: 8) {
                    missionSignal(
                        title: "Active step",
                        value: contract.nextAction,
                        symbol: commandSymbol(for: contract.recommendedIntent),
                        tint: commandTint(for: contract.recommendedIntent),
                        accessibilityIdentifier: "projectPlanActiveStep"
                    )
                    missionSignal(
                        title: "Why this is next",
                        value: nextStepReason,
                        symbol: "arrow.triangle.branch",
                        tint: AgentPalette.cyan,
                        accessibilityIdentifier: "projectPlanWhyNextDeep"
                    )
                    missionSignal(
                        title: "Completion rule",
                        value: contract.proofRequirement,
                        symbol: "checkmark.seal.fill",
                        tint: AgentPalette.green,
                        accessibilityIdentifier: "projectPlanCompletionRule"
                    )
                }
                .padding(11)
                .background(AgentPalette.row.opacity(0.62), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    Text("Success Criteria")
                        .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.tertiaryText)
                        .textCase(.uppercase)

                    ForEach(Array(contract.successCriteria.enumerated()), id: \.offset) { index, criterion in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1)")
                                .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                                .foregroundStyle(tint)
                                .frame(width: 20, height: 20)
                                .background(tint.opacity(0.10), in: Circle())
                            Text(criterion)
                                .font(.system(size: 10.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                                .foregroundStyle(AgentPalette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(11)
                .background(AgentPalette.surfaceAlt.opacity(0.30), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .accessibilityElement(children: .contain)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectPlanDeepSection")
    }


    struct ProjectMetricCard: Identifiable {
        let id: String
        let value: String
        let label: String
        let detail: String
        let symbol: String
        let tint: Color
    }

    var projectMetricCards: [ProjectMetricCard] {
        [
            ProjectMetricCard(
                id: "chats",
                value: "\(summary.conversationCount)",
                label: "Chats",
                detail: latestChatDetail,
                symbol: "bubble.left.and.bubble.right.fill",
                tint: AgentPalette.cyan
            ),
            ProjectMetricCard(
                id: "runs",
                value: "\(summary.toolRunCount)",
                label: "History",
                detail: latestRunDetail,
                symbol: "wrench.and.screwdriver.fill",
                tint: AgentPalette.lilac
            ),
            ProjectMetricCard(
                id: "artifacts",
                value: "\(summary.artifactCount)",
                label: "Artifacts",
                detail: latestArtifactDetail,
                symbol: "shippingbox.fill",
                tint: AgentPalette.green
            ),
            ProjectMetricCard(
                id: "events",
                value: "\(summary.eventCount)",
                label: "Events",
                detail: summary.failureCount == 0 ? summary.lastEventTitle : "\(summary.failureCount) to review",
                symbol: "timeline.selection",
                tint: summary.failureCount == 0 ? AgentPalette.indigo : AgentPalette.rose
            )
        ]
    }

    var projectSignals: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Project metrics")
                .accessibilityIdentifier("projectMetricGrid")

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(projectMetricCards) { metric in
                    signalCard(metric)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectMetricGrid")
    }

    var projectCommandCenter: some View {
        sectionShell(
            title: "Mission Control",
            subtitle: commandReadout,
            symbol: "command",
            tint: commandTint(for: selectedCommandIntent)
        ) {
            VStack(alignment: .leading, spacing: 12) {
                commandIntentGrid
                commandContextField
                commandActionBar
                commandSurfaceLinks
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("projectCommandCenter")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projectCommandCenter")
    }

    var commandIntentGrid: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ProjectCommandIntent.allCases) { intent in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation((reduceMotion || !AgentPerformance.allowsDecorativeMotion) ? nil : .smooth(duration: 0.24)) {
                            selectedCommandIntent = intent
                        }
                    } label: {
                        commandIntentCard(intent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(intent.displayName). \(commandDetail(for: intent))")
                    .accessibilityAddTraits(selectedCommandIntent == intent ? .isSelected : [])
                    .accessibilityIdentifier("projectCommandIntent-\(intent.rawValue)")
                }
            }
            .padding(.horizontal, 1)
        }
    }

    func commandIntentCard(_ intent: ProjectCommandIntent) -> some View {
        let selected = selectedCommandIntent == intent
        let recommended = recommendedCommandIntent == intent
        let tint = commandTint(for: intent)

        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 7) {
                Image(systemName: commandSymbol(for: intent))
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Text(intent.compactName)
                    .font(.system(size: 11.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)

                if recommended {
                    Text("SMART")
                        .font(.system(size: 7.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 5)
                        .frame(height: 16)
                        .background(tint.opacity(0.11), in: Capsule(style: .continuous))
                        .accessibilityHidden(true)
                }
            }

            Text(commandDetail(for: intent))
                .font(.system(size: 9.5, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(selected ? AgentPalette.secondaryText : AgentPalette.tertiaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(width: 148, height: 66, alignment: .leading)
        .agentControlSurface(radius: 15, tint: tint.opacity(selected ? 0.16 : 0.08), selected: selected)
    }

    var commandContextField: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(commandTint(for: selectedCommandIntent))
                Text("Context")
                    .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                Spacer(minLength: 0)
                if !trimmedCommandContext.isEmpty {
                    Button {
                        commandContext = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(AgentPalette.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear project command context")
                    .accessibilityIdentifier("projectCommandContextClear")
                }
            }

            TextField("Goal, constraint, file, or artifact", text: $commandContext, axis: .vertical)
                .font(.system(size: 12, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.ink)
                .textInputAutocapitalization(.sentences)
                .lineLimit(2...4)
                .padding(10)
                .frame(minHeight: 48, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AgentPalette.row.opacity(0.72))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(commandTint(for: selectedCommandIntent).opacity(0.18), lineWidth: 0.55)
                )
                .accessibilityIdentifier("projectCommandContextField")
        }
    }

    var commandActionBar: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: commandSymbol(for: selectedCommandIntent))
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(commandTint(for: selectedCommandIntent))
                    .frame(width: 28, height: 28)
                    .background(commandTint(for: selectedCommandIntent).opacity(0.11), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedCommandIntent.displayName)
                        .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(1)
                    Text(selectedCommandIntent.instructionFocus)
                        .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.secondaryText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 9) {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    draftProjectCommand(project, selectedCommandIntent, trimmedCommandContext)
                } label: {
                    Label("Draft", systemImage: "square.and.pencil")
                        .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .frame(maxWidth: .infinity, minHeight: AgentDesign.minimumTouchTarget)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AgentPalette.ink)
                .agentControlSurface(radius: 14, tint: AgentPalette.cyan.opacity(0.10), selected: false)
                .accessibilityIdentifier("projectCommandDraftButton")

                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    runProjectCommand(project, selectedCommandIntent, trimmedCommandContext)
                } label: {
                    Label(projectRunButtonTitle, systemImage: projectRunButtonSymbol)
                        .font(.system(size: 12, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .frame(maxWidth: .infinity, minHeight: AgentDesign.minimumTouchTarget)
                }
                .buttonStyle(ProjectRunButtonStyle(tint: projectRunButtonTint, isDisabled: commandRunBlocked))
                .disabled(commandRunBlocked)
                .accessibilityHint(commandRunBlocked ? "Finish the current run before starting another project command." : selectedCommandIntent.instructionFocus)
                .accessibilityIdentifier("projectCommandRunButton")
            }
        }
        .padding(10)
        .background(AgentPalette.row.opacity(0.62), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(commandTint(for: selectedCommandIntent).opacity(0.14), lineWidth: 0.55)
        )
    }

    var commandSurfaceLinks: some View {
        HStack(spacing: 8) {
            commandSurfaceLink(title: "Forge", symbol: "sparkles", tab: .forge, tint: AgentPalette.cyan)
            commandSurfaceLink(title: "Workspace", symbol: "folder.fill", tab: .workspace, tint: AgentPalette.storageAccent)
            commandSurfaceLink(title: "History", symbol: "waveform.path.ecg", tab: .history, tint: AgentPalette.lilac)
        }
    }

    func commandSurfaceLink(title: String, symbol: String, tab: AppTab, tint: Color) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            openTab(tab)
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 10.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.secondaryText)
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.plain)
        .agentControlSurface(radius: 12, tint: tint.opacity(0.08), selected: false)
        .accessibilityIdentifier("projectCommandOpen\(title)")
    }

    @ViewBuilder
    var missionOSPanel: some View {
        let _ = AgentPerformance.bodyEvaluation("Project Mission OS Body")
        let contract = summary.missionContract
        let tint = missionOSTint(for: contract)
        sectionShell(
            title: "Mission OS",
            subtitle: "\(contract.readinessScore)% · \(contract.phase.displayName)",
            symbol: "point.3.connected.trianglepath.dotted",
            tint: tint,
            usesGlass: true
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: contract.phase.symbolName)
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(tint)
                        .frame(width: 42, height: 42)
                        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .strokeBorder(tint.opacity(0.22), lineWidth: 0.6)
                        )

                    VStack(alignment: .leading, spacing: 5) {
                        Text(contract.headline)
                            .font(.system(size: 15, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.ink)
                            .lineLimit(2)
                            .minimumScaleFactor(0.82)
                            .accessibilityIdentifier("missionOSHeadline")

                        Text(missionOSDirectiveText(for: contract))
                            .font(.system(size: 11, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.secondaryText)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(contract.readinessScore)")
                            .font(.system(size: 25, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(tint)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .accessibilityIdentifier("missionOSReadinessScore")
                        Text("ready")
                            .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                            .foregroundStyle(AgentPalette.tertiaryText)
                    }
                    .frame(width: 52, alignment: .trailing)
                }

                missionOSReadinessBar(score: contract.readinessScore, tint: tint)

                HStack(spacing: 8) {
                    missionOSStateBadge(
                        label: "Phase",
                        value: contract.phase.displayName,
                        symbol: contract.phase.symbolName,
                        tint: tint
                    )
                    missionOSStateBadge(
                        label: "Run",
                        value: missionOSRunStatusLabel(for: contract),
                        symbol: commandSymbol(for: contract.recommendedIntent),
                        tint: commandTint(for: contract.recommendedIntent)
                    )
                    missionOSStateBadge(
                        label: "Status",
                        value: missionOSDecisionStatusLabel(for: contract),
                        symbol: "arrow.triangle.branch",
                        tint: missionOSDecisionTint(for: contract)
                    )
                }

                missionSignal(
                    title: "Proof requirement",
                    value: contract.proofRequirement,
                    symbol: "checkmark.seal.fill",
                    tint: missionOSGateTint(.satisfied)
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("missionOSPanel")
    }

    var missionOSGateSection: some View {
        let contract = summary.missionContract
        let tint = missionOSTint(for: contract)

        return sectionShell(
            title: "Mission Gates",
            subtitle: "\(contract.gates.filter { $0.state == .satisfied }.count)/\(contract.gates.count) clear",
            symbol: "checklist.checked",
            tint: tint
        ) {
            VStack(spacing: 0) {
                ForEach(Array(contract.gates.enumerated()), id: \.element.id) { index, gate in
                    missionOSGateRow(gate)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(gate.title). \(gate.state.displayName). \(gate.detail)")
                        .accessibilityIdentifier("missionOSGate-\(gate.id)")

                    if index < contract.gates.count - 1 {
                        Divider()
                            .overlay(AgentPalette.border.opacity(0.34))
                            .padding(.leading, 42)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(AgentPalette.row.opacity(0.66), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(tint.opacity(0.14), lineWidth: 0.55)
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("missionOSGateSection")
    }

    func missionOSReadinessBar(score: Int, tint: Color) -> some View {
        ProgressView(value: Double(max(0, min(score, 100))), total: 100)
            .progressViewStyle(.linear)
            .tint(tint)
            .scaleEffect(x: 1, y: 0.72, anchor: .center)
            .clipShape(Capsule())
            .frame(maxWidth: .infinity)
            .frame(height: 8)
            .accessibilityHidden(true)
    }

    func missionOSDirectiveText(for contract: MissionOSContract) -> String {
        let directive = contract.operatorDirective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directive.isEmpty else { return contract.proofRequirement }

        if !contract.blockingGates.isEmpty {
            let recoveryText = directive
                .replacingOccurrences(of: "\(ProjectCommandIntent.fixBlocker.displayName): ", with: "")
                .replacingOccurrences(of: "\(ProjectCommandIntent.fixBlocker.displayName):", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return recoveryText.isEmpty ? "Run will recover from the active blocker." : "Run will recover: \(recoveryText)"
        }

        return directive
    }

    func missionOSRunStatusLabel(for contract: MissionOSContract) -> String {
        if !contract.blockingGates.isEmpty { return "Recovery" }

        switch contract.recommendedIntent {
        case .continueMission:
            return "Continue"
        case .planNext:
            return "Plan"
        case .verifyWork:
            return "Verify"
        case .improveArtifact:
            return "Improve"
        case .fixBlocker:
            return "Recovery"
        case .reviewEvidence:
            return "Review"
        }
    }

    func missionOSDecisionStatusLabel(for contract: MissionOSContract) -> String {
        if !contract.blockingGates.isEmpty { return "Blocked" }

        switch contract.decisionLabel {
        case "Review approval":
            return "Waiting"
        case "Ready to review":
            return "Proof ready"
        case "Needs checkpoint":
            return "Checkpoint"
        case "Needs verification":
            return "Verify next"
        case "Needs proof":
            return "Proof next"
        case "Continue mission":
            return "Ready"
        default:
            return contract.decisionLabel
        }
    }

    func missionOSGateRow(_ gate: MissionOSGate) -> some View {
        let tint = missionOSGateTint(gate.state)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: gate.state.symbolName)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(gate.title)
                        .font(.system(size: 11.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(AgentPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Text(gate.state.displayName)
                        .font(.system(size: 8.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(tint.opacity(0.10), in: Capsule(style: .continuous))
                    Spacer(minLength: 0)
                }

                Text(gate.detail)
                    .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 9)
    }

    var statusBadge: some View {
        miniBadge(title: summary.statusText, symbol: statusSymbol, tint: statusTint)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(summary.statusText)
            .accessibilityIdentifier("projectStatusPill")
    }

    var missionCopy: String {
        summary.missionText
    }


    var latestChatDetail: String {
        guard let latest = projectConversations.first else {
            return "No chats yet"
        }
        return latest.title
    }

    var latestRunDetail: String {
        if summary.pendingApprovalCount > 0 {
            return "\(summary.pendingApprovalCount) pending"
        }
        guard let latest = projectRuns.first else {
            return "No receipts yet"
        }
        return "\(runStatusText(latest.status)) · \(latest.name)"
    }

    var latestArtifactDetail: String {
        if let artifact = projectArtifacts.first {
            return artifact.title
        }
        return summary.fileChangeCount == 0 ? "No artifacts yet" : "\(summary.fileChangeCount) file changes"
    }

    var currentWorkText: String {
        if runtimeStatus.isVisible {
            return runtimeStatus.title
        }
        return summary.workflowSpine.currentTitle
    }

    var changedArtifactText: String {
        let spine = summary.workflowSpine
        if spine.changedTitle == spine.changedDetail { return spine.changedTitle }
        return "\(spine.changedTitle): \(spine.changedDetail)"
    }

    var blockerSnapshotText: String {
        summary.workflowSpine.blockerDetail
    }

    var recommendedCommandIntent: ProjectCommandIntent {
        summary.missionContract.recommendedIntent
    }

    var trimmedCommandContext: String {
        commandContext.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var commandRunBlocked: Bool {
        runtimeStatus.blocksCommand
    }

    var projectRunButtonTitle: String {
        switch runtimeStatus.tone {
        case .approval:
            return "Waiting"
        case .working:
            return "Running"
        default:
            return "Run"
        }
    }

    var projectRunButtonSymbol: String {
        switch runtimeStatus.tone {
        case .approval:
            return "checkmark.shield.fill"
        case .working:
            return "waveform"
        default:
            return "play.fill"
        }
    }

    var projectRunButtonTint: Color {
        runtimeStatus.isVisible ? runtimeStatus.tint : commandTint(for: recommendedCommandIntent)
    }

    var commandReadout: String {
        if runtimeStatus.blocksCommand {
            return runtimeStatus.title
        }
        if selectedCommandIntent == recommendedCommandIntent {
            return "Recommended for this project"
        }
        return commandDetail(for: selectedCommandIntent)
    }

    var latestProofText: String {
        let spine = summary.workflowSpine
        if spine.proofTitle == "No proof captured yet" || spine.proofTitle == spine.proofDetail {
            return spine.proofDetail
        }
        return "\(spine.proofTitle): \(spine.proofDetail)"
    }

    var nextStepReason: String {
        let contract = summary.missionContract
        if let gate = contract.blockingGates.first {
            return "Clears \(gate.title.lowercased()): \(gate.detail)"
        }
        if summary.pendingApprovalCount > 0 {
            return "A saved run is waiting for review before the next safe action."
        }
        if summary.review.hasStaleProof {
            return summary.workflowSpine.proofDetail
        }
        let directive = contract.operatorDirective.trimmingCharacters(in: .whitespacesAndNewlines)
        if !directive.isEmpty {
            return directive
        }
        return commandDetail(for: recommendedCommandIntent)
    }

    var expectedProofText: String {
        if summary.review.hasStaleProof {
            return "Refresh proof so it matches the latest project iteration."
        }
        let requirement = summary.missionContract.proofRequirement
        if requirement.contains("Create an openable artifact") {
            return "Create proof: artifact, file change, run, terminal log, or screenshot."
        }
        if requirement.contains("Proof exists, but it still needs") {
            return "Proof exists; add a check, build, or test receipt next."
        }
        if requirement.contains("Close the run with Agent Plan") {
            return "Close with Agent Plan and Agent Proof checkpoints."
        }
        return requirement
    }

    var approvalExpectationText: String {
        if runtimeStatus.tone == .approval {
            return "Approval is waiting now."
        }
        if commandRunBlocked {
            return "Finish the current run before starting another."
        }
        if summary.pendingApprovalCount > 0 {
            return "\(summary.pendingApprovalCount) approval\(summary.pendingApprovalCount == 1 ? "" : "s") already waiting."
        }
        switch recommendedCommandIntent {
        case .reviewEvidence:
            return "No approval expected for read-only evidence review."
        case .verifyWork:
            return "May pause before simulator, shell, or file checks."
        case .fixBlocker:
            return "May pause before mutating files or running recovery tools."
        case .continueMission, .planNext, .improveArtifact:
            return "May pause before edits, commands, or tool use."
        }
    }

    var approvalExpectationSymbol: String {
        runtimeStatus.tone == .approval || summary.pendingApprovalCount > 0 ? "checkmark.shield.fill" : "lock.open.fill"
    }

    var approvalExpectationTint: Color {
        runtimeStatus.tone == .approval || summary.pendingApprovalCount > 0 ? AgentPalette.cyan : AgentPalette.lilac
    }

    var autoContinueStateLine: String {
        if autoContinueState.isCountingDown {
            return "\(autoContinueState.detail) Starts in \(autoContinueState.remainingSeconds)s."
        }
        if !autoContinueState.isEnabled {
            return "Off for this project."
        }
        if autoContinueState.isPaused {
            return "Paused. Resume when ready."
        }
        if autoContinueState.state == .blocked {
            return autoContinueState.detail
        }
        return autoContinueState.detail
    }

    var autoContinueSymbol: String {
        if autoContinueState.isCountingDown { return "timer" }
        if autoContinueState.isPaused { return "pause.circle.fill" }
        if autoContinueState.state == .blocked { return "hand.raised.fill" }
        return autoContinueState.isEnabled ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath"
    }

    var autoContinueTint: Color {
        if autoContinueState.isCountingDown { return AgentPalette.green }
        if autoContinueState.isPaused { return AgentPalette.lilac }
        if autoContinueState.state == .blocked { return AgentPalette.rose }
        return autoContinueState.isEnabled ? AgentPalette.green : AgentPalette.tertiaryText
    }

    var artifactSectionSubtitle: String {
        if projectArtifacts.isEmpty { return "No project artifacts yet" }
        return "\(projectArtifacts.count) project artifact\(projectArtifacts.count == 1 ? "" : "s")"
    }

    var fileChangesSectionSubtitle: String {
        if projectFileChanges.isEmpty { return "No file changes yet" }
        return "\(projectFileChanges.count) recorded change\(projectFileChanges.count == 1 ? "" : "s")"
    }


    var trustTint: Color {
        if summary.failureCount > 0 { return AgentPalette.rose }
        if summary.pendingApprovalCount > 0 { return AgentPalette.lilac }
        return AgentPalette.green
    }

    var proofFreshnessTint: Color {
        if summary.review.hasStaleProof { return AgentPalette.rose }
        if summary.review.hasMissingEvidence { return AgentPalette.lilac }
        return AgentPalette.green
    }

    func reviewTint(for recommendation: ProjectReviewRecommendation) -> Color {
        switch recommendation {
        case .continueMission:
            return AgentPalette.green
        case .verifyWork:
            return AgentPalette.lilac
        case .askUser:
            return AgentPalette.cyan
        case .fixBlocker:
            return AgentPalette.rose
        case .finalReview:
            return AgentPalette.green
        }
    }

    func reviewFindingTint(_ severity: ProjectEventSeverity) -> Color {
        switch severity {
        case .failure:
            return AgentPalette.rose
        case .warning:
            return AgentPalette.lilac
        case .running:
            return AgentPalette.cyan
        case .success:
            return AgentPalette.green
        case .info:
            return AgentPalette.indigo
        }
    }

    func phaseIndex(_ phase: MissionOSPhase) -> Int {
        MissionOSPhase.allCases.firstIndex(of: phase) ?? 0
    }

    func phaseTrackTint(_ phase: MissionOSPhase, contract: MissionOSContract) -> Color {
        if phase == contract.phase {
            return missionOSTint(for: contract)
        }
        if phaseIndex(phase) < phaseIndex(contract.phase) {
            return AgentPalette.green
        }
        return AgentPalette.tertiaryText
    }

    func missionOSTint(for contract: MissionOSContract) -> Color {
        if !contract.blockingGates.isEmpty { return AgentPalette.rose }
        if contract.readinessScore >= 85 { return AgentPalette.green }
        if contract.readinessScore >= 58 { return AgentPalette.lilac }
        return AgentPalette.cyan
    }

    func missionOSDecisionTint(for contract: MissionOSContract) -> Color {
        if !contract.blockingGates.isEmpty { return AgentPalette.rose }
        if contract.readinessScore >= 85 { return AgentPalette.green }
        if contract.phase == .verify || contract.phase == .proof { return AgentPalette.lilac }
        return AgentPalette.cyan
    }

    func missionOSGateTint(_ state: MissionOSGateState) -> Color {
        switch state {
        case .satisfied: AgentPalette.green
        case .waiting: AgentPalette.lilac
        case .blocked: AgentPalette.rose
        }
    }

    func liveProgressTint(for state: WorkspaceProgressStep.State) -> Color {
        switch state {
        case .pending: AgentPalette.tertiaryText
        case .current: AgentPalette.cyan
        case .done: AgentPalette.green
        case .blocked: AgentPalette.rose
        }
    }

    func liveProgressSymbol(for step: WorkspaceProgressStep) -> String {
        switch step.state {
        case .pending:
            return "circle"
        case .current:
            return step.symbolName
        case .done:
            return "checkmark.circle.fill"
        case .blocked:
            return "exclamationmark.triangle.fill"
        }
    }

    func liveProgressStateLabel(_ state: WorkspaceProgressStep.State) -> String {
        switch state {
        case .pending: "Next"
        case .current: "Now"
        case .done: "Done"
        case .blocked: "Blocked"
        }
    }

    func commandSymbol(for intent: ProjectCommandIntent) -> String {
        switch intent {
        case .continueMission: "arrow.triangle.2.circlepath"
        case .planNext: "list.bullet.clipboard.fill"
        case .verifyWork: "checkmark.shield.fill"
        case .improveArtifact: "wand.and.sparkles"
        case .fixBlocker: "wrench.and.screwdriver.fill"
        case .reviewEvidence: "doc.text.magnifyingglass"
        }
    }

    func commandTint(for intent: ProjectCommandIntent) -> Color {
        switch intent {
        case .continueMission: AgentPalette.green
        case .planNext: AgentPalette.cyan
        case .verifyWork: AgentPalette.lilac
        case .improveArtifact: AgentPalette.green
        case .fixBlocker: AgentPalette.rose
        case .reviewEvidence: AgentPalette.indigo
        }
    }

    func commandDetail(for intent: ProjectCommandIntent) -> String {
        let spine = summary.workflowSpine
        switch intent {
        case .continueMission:
            return spine.nextActionDetail.isEmpty ? "Choose the best next action" : spine.nextActionDetail
        case .planNext:
            return "Plan from \(spine.changedDetail)"
        case .verifyWork:
            return summary.review.hasStaleProof ? "Refresh proof for current work" : "Verify \(spine.changedDetail)"
        case .improveArtifact:
            return spine.latestArtifactPath.map { "Improve \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? "Improve \(spine.changedDetail)"
        case .fixBlocker:
            return spine.blockerDetail
        case .reviewEvidence:
            return spine.proofTitle == "No proof captured yet" ? "Read timeline and proof" : "Review \(spine.proofTitle)"
        }
    }

    func miniBadge(title: String, symbol: String, tint: Color) -> some View {
        Label {
            Text(title)
                .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .black))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 0.55)
        )
    }

    func missionOSStateBadge(label: String, value: String, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 7.5, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.tertiaryText)
                .lineLimit(1)

            Label {
                Text(value)
                    .font(.system(size: 10, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } icon: {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .black))
            }
            .foregroundStyle(tint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.18), lineWidth: 0.55)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }


    func missionSignal(title: String, value: String, symbol: String, tint: Color, accessibilityIdentifier: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.tertiaryText)
                Text(value.isEmpty ? "None" : value)
                    .font(.system(size: 12, weight: .bold, design: AgentPalette.interfaceFontDesign))
                    .foregroundStyle(AgentPalette.ink)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(accessibilityIdentifier ?? "")
            }
            Spacer(minLength: 0)
        }
    }
}

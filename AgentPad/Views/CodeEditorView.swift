import SwiftUI
import UIKit

enum EditorTheme: String, CaseIterable, Identifiable {
    case slate = "Slate"
    case cyberpunk = "Cyberpunk"
    case neonDark = "Neon"
    case lightGlass = "Light"
    
    var id: String { rawValue }
    
    var backgroundColor: Color {
        switch self {
        case .slate: AgentPalette.codeBackground
        case .cyberpunk: AgentPalette.surfaceElevated
        case .neonDark: AgentPalette.codeBackground
        case .lightGlass: AgentPalette.isLight ? AgentPalette.surfaceElevated : AgentPalette.surface
        }
    }
    
    var inkColor: UIColor {
        switch self {
        case .slate: UIColor(AgentPalette.codeText)
        case .cyberpunk, .neonDark: UIColor(AgentPalette.codeText)
        case .lightGlass: UIColor(AgentPalette.ink)
        }
    }
    
    var keywordColor: UIColor {
        switch self {
        case .slate: UIColor(AgentPalette.codeKeyword)
        case .cyberpunk, .neonDark, .lightGlass: UIColor(AgentPalette.codeKeyword)
        }
    }
    
    var stringColor: UIColor {
        switch self {
        case .slate: UIColor(AgentPalette.codeString)
        case .cyberpunk, .neonDark, .lightGlass: UIColor(AgentPalette.codeString)
        }
    }
    
    var commentColor: UIColor {
        switch self {
        case .slate: UIColor(AgentPalette.codeComment)
        case .cyberpunk, .neonDark, .lightGlass: UIColor(AgentPalette.codeComment)
        }
    }
    
    var typeColor: UIColor {
        switch self {
        case .slate: UIColor(AgentPalette.codeType)
        case .cyberpunk, .neonDark, .lightGlass: UIColor(AgentPalette.codeType)
        }
    }
}

struct CodeEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let fileName: String
    let relativePath: String
    var workspace: SandboxWorkspace
    var initialLineNumber: Int?
    var onSave: () -> Void

    @State private var fileText = ""
    @State private var selectedRange = NSRange(location: 0, length: 0)
    @State private var showingSaveAlert = false
    @State private var saveMessage = ""
    
    // Config panel options
    @State private var theme: EditorTheme = .slate
    @State private var fontSize: CGFloat = 14
    @State private var searchQuery = ""
    @State private var replaceQuery = ""
    @State private var showingSearchReplace = false
    @State private var documentMetrics = DocumentMetrics()
    @State private var loadFailed = false
    @State private var loadErrorMessage: String?
    @State private var lastSavedText = ""

    private let helpers = ["{", "}", "[", "]", "(", ")", ";", "=", "\"", "'", "<", ">", "/", "\\", "_", "-"]

    private struct DocumentMetrics {
        var lines = 0
        var words = 0
        var characters = 0
    }

    private var hasUnsavedChanges: Bool {
        fileText != lastSavedText
    }

    var body: some View {
        ZStack {
            AgentBackground()
            VStack(spacing: 0) {
                header
                editorStatusStrip
                
                controlPanel
                
                editorArea
                
                keyboardHelpers
                
                footer
            }
        }
        .onAppear {
            loadFile()
        }
        .onChange(of: fileText) {
            updateDocumentMetrics()
        }
        .alert("Save Status", isPresented: $showingSaveAlert) {
            Button("OK", role: .cancel) {
                if saveMessage.contains("successfully") {
                    dismiss()
                }
            }
        } message: {
            Text(saveMessage)
        }
    }

    private var header: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(.borderless)
            .frame(minWidth: AgentDesign.minimumTouchTarget + 8, minHeight: AgentDesign.minimumTouchTarget + 2)
            .contentShape(Rectangle())
            .agentControlSurface(radius: 12)
            .accessibilityIdentifier("codeEditorCancelButton")

            Spacer()

            Text(fileName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(AgentPalette.ink)
                .accessibilityIdentifier("codeEditorFileName")

            Spacer()

            Button("Save") {
                saveFile()
            }
            .buttonStyle(.borderless)
            .frame(minWidth: AgentDesign.minimumTouchTarget + 8, minHeight: AgentDesign.minimumTouchTarget + 2)
            .contentShape(Rectangle())
            .agentControlSurface(radius: 12, tint: AgentPalette.green, selected: true)
            .accessibilityIdentifier("codeEditorSaveButton")
            .disabled(loadFailed)
            .opacity(loadFailed ? 0.45 : 1)
        }
        .padding(.horizontal)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var editorStatusStrip: some View {
        HStack(spacing: 8) {
            Label(loadFailed ? "Load issue" : (hasUnsavedChanges ? "Edited" : "Saved"), systemImage: loadFailed ? "exclamationmark.triangle.fill" : (hasUnsavedChanges ? "pencil" : "checkmark.seal.fill"))
                .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(loadFailed ? AgentPalette.rose : (hasUnsavedChanges ? AgentPalette.lilac : AgentPalette.green))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .agentControlSurface(
                    radius: 10,
                    tint: (loadFailed ? AgentPalette.rose : (hasUnsavedChanges ? AgentPalette.lilac : AgentPalette.green)).opacity(0.12),
                    selected: true
                )

            Text(relativePath)
                .font(.system(size: 10, weight: .semibold, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            Text("\(documentMetrics.lines) lines")
                .font(.system(size: 9, weight: .black, design: AgentPalette.interfaceFontDesign))
                .foregroundStyle(AgentPalette.cyan)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 42)
        .agentSurface(radius: 15, tint: AgentPalette.cyan.opacity(0.06))
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(loadFailed ? "Load issue" : (hasUnsavedChanges ? "Edited" : "Saved")), \(relativePath), \(documentMetrics.lines) lines")
        .accessibilityIdentifier("codeEditorStatusStrip")
    }

    private var controlPanel: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("Theme", selection: $theme) {
                    ForEach(EditorTheme.allCases) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.menu)
                .font(.caption)
                .frame(minWidth: 86, minHeight: AgentDesign.minimumTouchTarget + 2)
                .contentShape(Rectangle())
                .agentControlSurface(radius: 12, tint: AgentPalette.cyan)
                .accessibilityIdentifier("codeEditorThemePicker")
                
                Spacer()
                
                HStack(spacing: 4) {
                    Button {
                        if fontSize > 10 { fontSize -= 1 }
                    } label: {
                        Image(systemName: "minus")
                            .font(.caption.weight(.bold))
                            .frame(width: AgentDesign.minimumTouchTarget + 2, height: AgentDesign.minimumTouchTarget + 2)
                    }
                    .buttonStyle(.plain)
                    .agentControlSurface(radius: 12)
                    .accessibilityLabel("Decrease font size")
                    .accessibilityIdentifier("codeEditorDecreaseFont")
                    
                    Text("\(Int(fontSize)) pt")
                        .font(.caption.weight(.semibold))
                        .frame(minWidth: 48)
                    
                    Button {
                        if fontSize < 24 { fontSize += 1 }
                    } label: {
                        Image(systemName: "plus")
                            .font(.caption.weight(.bold))
                            .frame(width: AgentDesign.minimumTouchTarget + 2, height: AgentDesign.minimumTouchTarget + 2)
                    }
                    .buttonStyle(.plain)
                    .agentControlSurface(radius: 12)
                    .accessibilityLabel("Increase font size")
                    .accessibilityIdentifier("codeEditorIncreaseFont")
                }
                
                Spacer()
                
                Button {
                    withAnimation(.smooth(duration: 0.25)) {
                        showingSearchReplace.toggle()
                    }
                } label: {
                    Label("Find", systemImage: "magnifyingglass")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(showingSearchReplace ? AgentPalette.cyan : .secondary)
                        .frame(minWidth: AgentDesign.minimumTouchTarget + 2, minHeight: AgentDesign.minimumTouchTarget + 2)
                }
                .buttonStyle(.plain)
                .agentControlSurface(radius: 12, tint: AgentPalette.cyan, selected: showingSearchReplace)
                .accessibilityIdentifier("codeEditorFindToggle")
            }
            .padding(.horizontal)
            .padding(.top, 4)
            
            if showingSearchReplace {
                searchReplacePanel
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private var searchReplacePanel: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("Find query...", text: $searchQuery)
                    .font(.system(.caption, design: .monospaced))
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.none)
                    .padding(8)
                    .frame(minHeight: AgentDesign.minimumTouchTarget + 2)
                    .agentControlSurface(radius: 10, tint: AgentPalette.cyan)
                    .accessibilityIdentifier("codeEditorFindField")
                
                Button {
                    findNext()
                } label: {
                    Text("Find Next")
                        .font(.caption.weight(.bold))
                        .frame(minWidth: 88, minHeight: AgentDesign.minimumTouchTarget + 2)
                }
                .buttonStyle(.plain)
                .agentControlSurface(radius: 12, tint: AgentPalette.cyan, selected: false)
                .accessibilityIdentifier("codeEditorFindNext")
                .disabled(searchQuery.isEmpty)
            }
            
            HStack(spacing: 8) {
                TextField("Replace with...", text: $replaceQuery)
                    .font(.system(.caption, design: .monospaced))
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.none)
                    .padding(8)
                    .frame(minHeight: AgentDesign.minimumTouchTarget + 2)
                    .agentControlSurface(radius: 10, tint: AgentPalette.cyan)
                    .accessibilityIdentifier("codeEditorReplaceField")
                
                Button {
                    replaceSelected()
                } label: {
                    Text("Replace")
                        .font(.caption.weight(.bold))
                        .frame(minWidth: 82, minHeight: AgentDesign.minimumTouchTarget + 2)
                }
                .buttonStyle(.plain)
                .agentControlSurface(radius: 12, tint: AgentPalette.cyan, selected: false)
                .accessibilityIdentifier("codeEditorReplace")
                .disabled(searchQuery.isEmpty)
                
                Button {
                    replaceAll()
                } label: {
                    Text("All")
                        .font(.caption.weight(.bold))
                        .frame(minWidth: AgentDesign.minimumTouchTarget + 2, minHeight: AgentDesign.minimumTouchTarget + 2)
                }
                .buttonStyle(.plain)
                .agentControlSurface(radius: 12, tint: AgentPalette.cyan, selected: false)
                .accessibilityIdentifier("codeEditorReplaceAll")
                .disabled(searchQuery.isEmpty)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
    }

    private var editorArea: some View {
        Group {
            if loadFailed {
                AgentCenteredStateView(
                    title: "File could not load",
                    detail: loadErrorMessage ?? "NovaForge protected this file from being overwritten by an empty editor buffer.",
                    symbol: "doc.badge.exclamationmark",
                    tint: AgentPalette.rose
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(18)
                .agentSurface(radius: 20, tint: AgentPalette.rose.opacity(0.08))
            } else {
                RepresentableCodeEditor(text: $fileText, selectedRange: $selectedRange, theme: theme, fontSize: fontSize)
                    .padding(10)
                    .background(theme.backgroundColor.opacity(0.85))
                    .agentGlass(radius: 20)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    private func helperAccessibilityID(_ helper: String) -> String {
        let suffix: String
        switch helper {
        case "{": suffix = "leftBrace"
        case "}": suffix = "rightBrace"
        case "[": suffix = "leftBracket"
        case "]": suffix = "rightBracket"
        case "(": suffix = "leftParen"
        case ")": suffix = "rightParen"
        case ";": suffix = "semicolon"
        case "=": suffix = "equals"
        case "\"": suffix = "quote"
        case "'": suffix = "apostrophe"
        case "<": suffix = "lessThan"
        case ">": suffix = "greaterThan"
        case "/": suffix = "slash"
        case "\\": suffix = "backslash"
        case "_": suffix = "underscore"
        case "-": suffix = "dash"
        default:
            suffix = helper.unicodeScalars
                .map { String(format: "%02X", $0.value) }
                .joined(separator: "")
        }
        return "codeEditorHelper-\(suffix)"
    }

    private var keyboardHelpers: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(helpers, id: \.self) { helper in
                    Button {
                        insertCharacter(helper)
                    } label: {
                        Text(helper)
                            .font(.system(.body, design: .monospaced, weight: .bold))
                            .frame(width: AgentDesign.minimumTouchTarget + 2, height: AgentDesign.minimumTouchTarget + 2)
                    }
                    .buttonStyle(.plain)
                    .agentControlSurface(radius: 12)
                    .accessibilityLabel("Insert \(helper)")
                    .accessibilityIdentifier(helperAccessibilityID(helper))
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    private var footer: some View {
        HStack {
            Text("Lines: \(documentMetrics.lines)")
            Spacer()
            Text("Words: \(documentMetrics.words)")
            Spacer()
            Text("Chars: \(documentMetrics.characters)")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .agentSurface(radius: 12)
        .padding(.horizontal)
        .padding(.bottom, 12)
    }

    private func loadFile() {
        do {
            let contents = try workspace.read(relativePath)
            fileText = contents
            lastSavedText = contents
            if let initialLineNumber {
                selectedRange = Self.selectionRange(forLine: initialLineNumber, in: contents)
            }
            loadFailed = false
            loadErrorMessage = nil
        } catch {
            fileText = ""
            lastSavedText = ""
            loadFailed = true
            loadErrorMessage = "Failed to load \(relativePath): \(error.localizedDescription)"
            saveMessage = loadErrorMessage ?? "Failed to load \(relativePath)."
            showingSaveAlert = true
        }
        updateDocumentMetrics()
    }

    private static func selectionRange(forLine lineNumber: Int, in text: String) -> NSRange {
        let nsText = text as NSString
        guard nsText.length > 0 else { return NSRange(location: 0, length: 0) }

        let targetLine = max(1, lineNumber)
        var currentLine = 1
        var selectedRange: NSRange?
        nsText.enumerateSubstrings(
            in: NSRange(location: 0, length: nsText.length),
            options: [.byLines, .substringNotRequired]
        ) { _, lineRange, _, stop in
            if currentLine == targetLine {
                selectedRange = lineRange
                stop.pointee = true
            }
            currentLine += 1
        }

        return selectedRange ?? NSRange(location: nsText.length, length: 0)
    }

    private func updateDocumentMetrics() {
        guard !fileText.isEmpty else {
            documentMetrics = DocumentMetrics()
            return
        }
        let lineCount = fileText.reduce(into: 1) { count, character in
            if character.isNewline {
                count += 1
            }
        }
        let wordCount = fileText.split(whereSeparator: \.isWhitespace).count
        documentMetrics = DocumentMetrics(lines: lineCount, words: wordCount, characters: fileText.count)
    }

    private func saveFile() {
        guard !loadFailed else {
            saveMessage = "This file did not load correctly, so NovaForge will not overwrite it with a blank buffer."
            showingSaveAlert = true
            return
        }
        do {
            try workspace.write(relativePath, contents: fileText)
            lastSavedText = fileText
            saveMessage = "File saved successfully."
            onSave()
        } catch {
            saveMessage = "Failed to save: \(error.localizedDescription)"
        }
        showingSaveAlert = true
    }

    private func insertCharacter(_ char: String) {
        let textStr = fileText
        let start = max(0, min(selectedRange.location, textStr.count))
        
        let index = textStr.index(textStr.startIndex, offsetBy: start, default: textStr.endIndex)
        fileText.insert(contentsOf: char, at: index)
        
        selectedRange = NSRange(location: start + char.count, length: 0)
    }

    private func findNext() {
        guard !searchQuery.isEmpty else { return }
        let textStr = fileText as NSString
        let start = selectedRange.location + selectedRange.length
        
        var searchRange = NSRange(location: start, length: textStr.length - start)
        var index = textStr.range(of: searchQuery, options: .caseInsensitive, range: searchRange)
        
        if index.location == NSNotFound {
            searchRange = NSRange(location: 0, length: textStr.length)
            index = textStr.range(of: searchQuery, options: .caseInsensitive, range: searchRange)
        }
        
        if index.location != NSNotFound {
            selectedRange = index
        }
    }

    private func replaceSelected() {
        guard !searchQuery.isEmpty else { return }
        let start = selectedRange.location
        let length = selectedRange.length
        
        if length > 0, start >= 0, start + length <= fileText.count {
            let range = fileText.index(fileText.startIndex, offsetBy: start)..<fileText.index(fileText.startIndex, offsetBy: start + length)
            fileText.replaceSubrange(range, with: replaceQuery)
            selectedRange = NSRange(location: start, length: replaceQuery.count)
        }
    }

    private func replaceAll() {
        fileText = fileText.replacingOccurrences(of: searchQuery, with: replaceQuery, options: .caseInsensitive)
    }
}

private extension String {
    func index(_ index: String.Index, offsetBy offset: Int, default defaultIndex: String.Index) -> String.Index {
        self.index(index, offsetBy: offset, limitedBy: endIndex) ?? defaultIndex
    }
}

struct RepresentableCodeEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var selectedRange: NSRange
    let theme: EditorTheme
    let fontSize: CGFloat

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.backgroundColor = .clear
        
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        
        // Initial highlight
        textView.attributedText = highlight(text, theme: theme, fontSize: fontSize)
        
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text || context.coordinator.lastTheme != theme || context.coordinator.lastFontSize != fontSize {
            let selected = clampedRange(selectedRange, in: text)
            uiView.attributedText = highlight(text, theme: theme, fontSize: fontSize)
            uiView.selectedRange = selected
            context.coordinator.lastTheme = theme
            context.coordinator.lastFontSize = fontSize
        }

        let targetRange = clampedRange(selectedRange, in: text)
        if !NSEqualRanges(uiView.selectedRange, targetRange) {
            uiView.selectedRange = targetRange
            if targetRange.length > 0 {
                uiView.scrollRangeToVisible(targetRange)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: RepresentableCodeEditor
        var lastTheme: EditorTheme?
        var lastFontSize: CGFloat?

        init(_ parent: RepresentableCodeEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            let selected = parent.clampedRange(textView.selectedRange, in: textView.text)
            let highlighted = parent.highlight(textView.text, theme: parent.theme, fontSize: parent.fontSize)
            textView.attributedText = highlighted
            textView.selectedRange = selected
            
            parent.text = textView.text
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            parent.selectedRange = parent.clampedRange(textView.selectedRange, in: textView.text)
        }
    }
    
    func clampedRange(_ range: NSRange, in text: String) -> NSRange {
        let length = text.utf16.count
        let location = max(0, min(range.location, length))
        let rangeLength = max(0, min(range.length, length - location))
        return NSRange(location: location, length: rangeLength)
    }
    
    func highlight(_ text: String, theme: EditorTheme, fontSize: CGFloat) -> NSAttributedString {
        let attributedString = NSMutableAttributedString(string: text)
        let range = NSRange(location: 0, length: text.utf16.count)
        
        attributedString.addAttribute(.foregroundColor, value: theme.inkColor, range: range)
        attributedString.addAttribute(.font, value: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular), range: range)
        
        let keywords = [
            "\\b(func|struct|class|import|let|var|return|if|else|guard|switch|case|init|self|true|false|nil|for|in|while|try|catch|throw|throws|enum|extension|protocol|private|fileprivate|public|internal|open|static|mutating|async|await|override)\\b"
        ]
        
        func applyRegex(pattern: String, color: UIColor) {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let matches = regex.matches(in: text, options: [], range: range)
                for match in matches {
                    attributedString.addAttribute(.foregroundColor, value: color, range: match.range)
                }
            }
        }
        
        // 1. Capitalized Types
        applyRegex(pattern: "\\b([A-Z][a-zA-Z0-9_]*)\\b", color: theme.typeColor)
        
        // 2. Keywords
        for keywordPattern in keywords {
            applyRegex(pattern: keywordPattern, color: theme.keywordColor)
        }
        
        // 3. Strings
        applyRegex(pattern: "\"[^\"]*\"", color: theme.stringColor)
        applyRegex(pattern: "'[^']*'", color: theme.stringColor)
        
        // 4. Comments
        applyRegex(pattern: "//.*", color: theme.commentColor)
        applyRegex(pattern: "/\\*[^*]*\\*+(?:[^/*][^*]*\\*+)*/", color: theme.commentColor)
        
        return attributedString
    }
}

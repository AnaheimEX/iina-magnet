//
//  DisclaimerSheet.swift
//  IinaMagnet
//
//  The bilingual modal users see on first launch (and after any version bump).
//  Behaviour: zh-Hans / en tabs, markdown rendered, "I Agree" button enabled
//  only after the user scrolls to the bottom of the active tab.

import SwiftUI

public struct DisclaimerSheet: View {

    private let coordinator: DisclaimerCoordinator
    private let onAcknowledged: () -> Void

    @State private var selectedLanguage: Language
    @State private var hasReachedBottomZH: Bool = false
    @State private var hasReachedBottomEN: Bool = false

    private enum Language: String, CaseIterable, Identifiable {
        case zhHans, en
        var id: String { rawValue }
        var label: String {
            switch self {
            case .zhHans: return "中文"
            case .en:     return "English"
            }
        }
        var resourceName: String {
            switch self {
            case .zhHans: return "Disclaimer.zh-Hans"
            case .en:     return "Disclaimer.en"
            }
        }
    }

    public init(coordinator: DisclaimerCoordinator, onAcknowledged: @escaping () -> Void) {
        self.coordinator = coordinator
        self.onAcknowledged = onAcknowledged
        // Default to Chinese if system language begins with zh; otherwise English.
        let langCode = Locale.current.language.languageCode?.identifier ?? "en"
        _selectedLanguage = State(initialValue: langCode == "zh" ? .zhHans : .en)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tabContent
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 540)
    }

    private var header: some View {
        HStack {
            Text(selectedLanguage == .zhHans ? "使用免责声明" : "Disclaimer of Use")
                .font(.title2.bold())
            Spacer()
            Picker("", selection: $selectedLanguage) {
                ForEach(Language.allCases) { lang in
                    Text(lang.label).tag(lang)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
        }
        .padding()
    }

    private var tabContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let attributed = Self.loadMarkdown(named: selectedLanguage.resourceName) {
                    Text(attributed)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.bottom)
                } else {
                    Text("Failed to load disclaimer text. Refusing to proceed.")
                        .foregroundStyle(.red)
                        .padding()
                }
                // Sentinel that flips the per-language "reached bottom" flag.
                Color.clear
                    .frame(height: 1)
                    .onAppear { markBottomReached() }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(action: acknowledge) {
                Text(selectedLanguage == .zhHans ? "我已阅读并同意" : "I Have Read and Agree")
                    .padding(.horizontal, 8)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!isCurrentTabRead)
            .help(isCurrentTabRead
                  ? (selectedLanguage == .zhHans ? "" : "")
                  : (selectedLanguage == .zhHans
                     ? "请先滚动到底部完整阅读后再确认。"
                     : "Please scroll to the bottom to read the full text before accepting."))
        }
        .padding()
    }

    private var isCurrentTabRead: Bool {
        switch selectedLanguage {
        case .zhHans: return hasReachedBottomZH
        case .en:     return hasReachedBottomEN
        }
    }

    private func markBottomReached() {
        switch selectedLanguage {
        case .zhHans: hasReachedBottomZH = true
        case .en:     hasReachedBottomEN = true
        }
    }

    private func acknowledge() {
        do {
            try coordinator.accept()
            onAcknowledged()
        } catch {
            // SwiftData save failed; surface to user via alert in Issue 03 integration.
            // Phase 0 baseline: log and refuse to proceed.
            assertionFailure("DisclaimerCoordinator.accept failed: \(error)")
        }
    }

    // MARK: - Markdown loading

    /// Loads the bundled markdown file and returns an AttributedString.
    /// Uses `.inlineOnlyPreservingWhitespace` so paragraph breaks render via newlines
    /// (full markdown rendering is heavier than we need; PR rendering can come later).
    static func loadMarkdown(named name: String) -> AttributedString? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "md"),
              let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .utf8) else {
            return nil
        }
        return try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
    }
}

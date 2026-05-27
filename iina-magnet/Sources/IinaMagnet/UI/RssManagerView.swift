//
//  RssManagerView.swift
//  IinaMagnet
//
//  SwiftUI window: manage SubscriptionSources + their SubscriptionRules,
//  preview latest Feed items, see hit history. Backed entirely by SwiftData
//  @Query so external changes (e.g. scheduler updates) reflect live.

import SwiftUI
import SwiftData

public struct RssManagerView: View {

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SubscriptionSource.displayName) private var sources: [SubscriptionSource]
    @State private var selectedSourceId: PersistentIdentifier?
    @State private var showAddSheet = false

    public init() {}

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let id = selectedSourceId, let source = sources.first(where: { $0.persistentModelID == id }) {
                SourceDetailView(source: source)
            } else {
                ContentUnavailableView("Select a subscription source", systemImage: "antenna.radiowaves.left.and.right")
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddSourceSheet { url, name in
                let new = SubscriptionSource(url: url, displayName: name)
                modelContext.insert(new)
                try? modelContext.save()
                selectedSourceId = new.persistentModelID
                Task { await SubscriptionScheduler.shared.rescheduleAll() }
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(sources, id: \.persistentModelID, selection: $selectedSourceId) { source in
                HStack {
                    statusDot(for: source.lastPollResult, enabled: source.enabled)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.displayName).font(.body)
                        Text(source.url.host ?? source.url.absoluteString)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .tag(source.persistentModelID)
            }
            Divider()
            HStack {
                Button { showAddSheet = true } label: { Image(systemName: "plus") }
                Button(role: .destructive) { deleteSelected() }
                       label: { Image(systemName: "minus") }
                       .disabled(selectedSourceId == nil)
                Spacer()
            }
            .padding(8)
            .buttonStyle(.borderless)
        }
        .frame(minWidth: 240)
        .navigationTitle("RSS Manager")
    }

    private func statusDot(for result: PollResult?, enabled: Bool) -> some View {
        let color: Color = {
            if !enabled { return .gray }
            switch result {
            case .success: return .green
            case .error:   return .orange
            case nil:      return .blue
            }
        }()
        return Circle().fill(color).frame(width: 8, height: 8)
    }

    private func deleteSelected() {
        guard let id = selectedSourceId,
              let source = sources.first(where: { $0.persistentModelID == id }) else { return }
        modelContext.delete(source)
        try? modelContext.save()
        selectedSourceId = nil
        Task { await SubscriptionScheduler.shared.rescheduleAll() }
    }
}

// MARK: - Source detail

private struct SourceDetailView: View {

    @Bindable var source: SubscriptionSource
    @Environment(\.modelContext) private var modelContext
    @State private var tab: DetailTab = .settings

    enum DetailTab: String, CaseIterable { case settings, rules, feed }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Settings").tag(DetailTab.settings)
                Text("Rules").tag(DetailTab.rules)
                Text("Feed").tag(DetailTab.feed)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()

            switch tab {
            case .settings: settingsTab
            case .rules:    rulesTab
            case .feed:     feedTab
            }
        }
        .toolbar {
            Button("Poll now") {
                Task { await SubscriptionScheduler.shared.pollNow(sourceId: source.persistentModelID) }
            }
        }
    }

    // MARK: Settings tab

    private var settingsTab: some View {
        Form {
            Section("General") {
                TextField("Display name", text: $source.displayName)
                TextField("URL", text: Binding(get: { source.url.absoluteString },
                                                set: { source.url = URL(string: $0) ?? source.url }))
                Picker("Poll interval", selection: $source.pollIntervalSeconds) {
                    Text("15 min").tag(900)
                    Text("30 min").tag(1800)
                    Text("1 hour").tag(3600)
                    Text("3 hours").tag(10800)
                    Text("6 hours").tag(21600)
                    Text("12 hours").tag(43200)
                }
                Toggle("Enabled", isOn: $source.enabled)
            }
            Section("Authentication") {
                TextField("Cookie header", text: Binding(get: { source.cookieHeader ?? "" },
                                                          set: { source.cookieHeader = $0.isEmpty ? nil : $0 }))
                    .help("Cookies for sources behind login (e.g. mikanani.me MyBangumi)")
            }
            Section("Status") {
                if let last = source.lastPolledAt {
                    Text("Last polled: \(last.formatted(date: .abbreviated, time: .standard))")
                        .foregroundStyle(.secondary)
                }
                if case .error(let msg) = source.lastPollResult {
                    Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: source.enabled) { _, _ in
            try? modelContext.save()
            Task { await SubscriptionScheduler.shared.rescheduleAll() }
        }
    }

    // MARK: Rules tab

    private var rulesTab: some View {
        VStack(spacing: 0) {
            List {
                ForEach(source.rules) { rule in
                    RuleEditorRow(rule: rule)
                }
                .onDelete { offsets in
                    for i in offsets { modelContext.delete(source.rules[i]) }
                    try? modelContext.save()
                }
            }
            HStack {
                Button {
                    let r = SubscriptionRule(name: "New rule")
                    r.source = source
                    modelContext.insert(r)
                    try? modelContext.save()
                } label: { Label("Add rule", systemImage: "plus") }
                Spacer()
            }
            .padding(8)
        }
    }

    // MARK: Feed tab

    @Query private var feedItems: [FeedItem]

    init(source: SubscriptionSource) {
        self.source = source
        let sourceID = source.persistentModelID
        self._feedItems = Query(
            filter: #Predicate<FeedItem> { $0.source?.persistentModelID == sourceID },
            sort: \.publishedAt,
            order: .reverse
        )
    }

    private var feedTab: some View {
        Table(feedItems) {
            TableColumn("Matched", value: \.matched.description).width(60)
            TableColumn("Title", value: \.title)
            TableColumn("Published") { item in
                Text(item.publishedAt.formatted(date: .abbreviated, time: .shortened))
            }.width(140)
        }
    }
}

private struct RuleEditorRow: View {
    @Bindable var rule: SubscriptionRule
    @State private var includeText = ""
    @State private var excludeText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Name", text: $rule.name)
                .textFieldStyle(.roundedBorder)
            Toggle("Enabled", isOn: $rule.enabled)
                .toggleStyle(.switch)
            TextField("Include (comma-separated)", text: $includeText)
                .textFieldStyle(.roundedBorder)
                .onAppear { includeText = rule.include.joined(separator: ", ") }
                .onChange(of: includeText) { _, v in
                    rule.include = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                }
            TextField("Exclude (comma-separated)", text: $excludeText)
                .textFieldStyle(.roundedBorder)
                .onAppear { excludeText = rule.exclude.joined(separator: ", ") }
                .onChange(of: excludeText) { _, v in
                    rule.exclude = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                }
            TextField("Regex (optional, takes precedence)",
                      text: Binding(get: { rule.regex ?? "" }, set: { rule.regex = $0.isEmpty ? nil : $0 }))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            HStack {
                Text("Hits: \(rule.hitCount)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(6)
    }
}

// MARK: - Add source

private struct AddSourceSheet: View {
    let onSave: (URL, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add subscription source").font(.headline)
            TextField("URL", text: $urlText).textFieldStyle(.roundedBorder)
            TextField("Display name", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    guard let url = URL(string: urlText), !name.isEmpty else { return }
                    onSave(url, name); dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(URL(string: urlText) == nil || name.isEmpty)
            }
        }
        .padding()
        .frame(width: 460)
    }
}

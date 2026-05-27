//
//  MagnetSettingsView.swift
//  IinaMagnet
//
//  SwiftUI settings window. Tabs for General / BitTorrent / RSS / About.

import SwiftUI

public struct MagnetSettingsView: View {

    @State private var settings = AppSettings.shared
    @State private var tab: Tab = .general

    enum Tab: String, CaseIterable, Identifiable {
        case general, bittorrent, rss, about
        var id: String { rawValue }
        var label: String {
            switch self {
            case .general:    return "General"
            case .bittorrent: return "BitTorrent"
            case .rss:        return "RSS"
            case .about:      return "About"
            }
        }
        var systemImage: String {
            switch self {
            case .general:    return "gearshape"
            case .bittorrent: return "arrow.up.arrow.down"
            case .rss:        return "antenna.radiowaves.left.and.right"
            case .about:      return "info.circle"
            }
        }
    }

    public init() {}

    public var body: some View {
        TabView(selection: $tab) {
            generalTab.tabItem { Label(Tab.general.label, systemImage: Tab.general.systemImage) }.tag(Tab.general)
            btTab.tabItem { Label(Tab.bittorrent.label, systemImage: Tab.bittorrent.systemImage) }.tag(Tab.bittorrent)
            rssTab.tabItem { Label(Tab.rss.label, systemImage: Tab.rss.systemImage) }.tag(Tab.rss)
            aboutTab.tabItem { Label(Tab.about.label, systemImage: Tab.about.systemImage) }.tag(Tab.about)
        }
        .frame(minWidth: 560, minHeight: 420)
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section("Paths") {
                pathPicker(label: "Cache",
                           url: Binding(get: { settings.cacheDirectory }, set: { settings.cacheDirectory = $0 }))
                pathPicker(label: "Completed",
                           url: Binding(get: { settings.completedDirectory }, set: { settings.completedDirectory = $0 }))
                Toggle("Move to completed folder when download finishes",
                       isOn: Binding(get: { settings.autoMoveOnCompletion },
                                     set: { settings.autoMoveOnCompletion = $0 }))
            }
            Section("Disk") {
                Stepper("Warn when free space drops below \(settings.diskWarnThresholdGB) GB",
                        value: Binding(get: { settings.diskWarnThresholdGB },
                                       set: { settings.diskWarnThresholdGB = $0 }),
                        in: 0...500, step: 5)
            }
        }
        .formStyle(.grouped)
    }

    private func pathPicker(label: String, url: Binding<URL>) -> some View {
        HStack {
            Text(label).frame(width: 80, alignment: .leading)
            Text(url.wrappedValue.path).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.directoryURL = url.wrappedValue
                if panel.runModal() == .OK, let picked = panel.url {
                    url.wrappedValue = picked
                }
            }
        }
    }

    // MARK: - BT

    private var btTab: some View {
        Form {
            Section("Network") {
                TextField("Listen port",
                          value: Binding(get: { settings.listenPort }, set: { settings.listenPort = $0 }),
                          format: .number)
                Toggle("DHT", isOn: Binding(get: { settings.enableDHT }, set: { settings.enableDHT = $0 }))
                Toggle("PEX", isOn: Binding(get: { settings.enablePEX }, set: { settings.enablePEX = $0 }))
                Toggle("LSD", isOn: Binding(get: { settings.enableLSD }, set: { settings.enableLSD = $0 }))
                Toggle("UPnP / NAT-PMP (off by default; opens router)",
                       isOn: Binding(get: { settings.enableUPnP }, set: { settings.enableUPnP = $0 }))
            }
            Section("Seeding") {
                Picker("Strategy",
                       selection: Binding(get: { settings.seedingMode }, set: { settings.seedingMode = $0 })) {
                    Text("Zero seed (stop at 100%)").tag(AppSettings.SeedingMode.zero)
                    Text("Stop at ratio 1.0").tag(AppSettings.SeedingMode.ratio1x)
                    Text("Stop at ratio 2.0").tag(AppSettings.SeedingMode.ratio2x)
                    Text("Seed forever").tag(AppSettings.SeedingMode.forever)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - RSS

    private var rssTab: some View {
        Form {
            Section("Defaults for new subscriptions") {
                Picker("Poll interval",
                       selection: Binding(get: { settings.defaultPollIntervalSeconds },
                                          set: { settings.defaultPollIntervalSeconds = $0 })) {
                    Text("15 min").tag(900)
                    Text("30 min").tag(1800)
                    Text("1 hour").tag(3600)
                    Text("3 hours").tag(10800)
                }
                Toggle("Auto-start downloads when a rule matches",
                       isOn: Binding(get: { settings.autoStartDownloadOnMatch },
                                     set: { settings.autoStartDownloadOnMatch = $0 }))
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - About

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("iina-magnet").font(.title.bold())
            Text("Version 0.1.0 (private fork; GPL-3.0)")
                .foregroundStyle(.secondary)
            Divider()
            Text("This software is a personal fork of iina with RSS / BitTorrent / Library extensions. It does not ship trackers, indexes, or content. Users are responsible for the legality of what they download.")
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            HStack {
                Button("View Disclaimer") {
                    WindowFactory.shared.open(.disclaimer, title: "Disclaimer",
                                              contentSize: .init(width: 720, height: 600)) {
                        DisclaimerSheet(
                            coordinator: DisclaimerCoordinator(context: PersistenceController.shared.container.mainContext),
                            onAcknowledged: {}
                        )
                    }
                }
            }
        }
        .padding(20)
    }
}

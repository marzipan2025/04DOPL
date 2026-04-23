import SwiftUI
import AppKit

private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            AppDelegate.restoreSettingsWindowStyle(window)
            window.minSize = NSSize(width: 640, height: 460)
            window.setContentSize(NSSize(
                width: max(window.frame.width, 640),
                height: max(window.frame.height, 460)
            ))
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            AppDelegate.restoreSettingsWindowStyle(window)
            window.minSize = NSSize(width: 640, height: 460)
        }
    }
}

struct SettingsWindowView: View {
    @State private var selectedTab: SettingsTab? = .general
    
    enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case playback = "Playback"
        case appearance = "Appearance"
        
        var id: String { self.rawValue }
        
        var icon: String {
            switch self {
            case .general:    return "gearshape.fill"
            case .playback:   return "play.rectangle.fill"
            case .appearance: return "paintbrush.fill"
            }
        }
        
        var color: Color {
            switch self {
            case .general:    return .purple
            case .playback:   return .blue
            case .appearance: return .orange
            }
        }
    }
    
    var body: some View {
        ZStack {
            SettingsWindowConfigurator()

            HStack(spacing: 0) {
                sidebar
                Divider()
                detailPane
            }
        }
        .frame(minWidth: 640, minHeight: 460)
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .underPageBackgroundColor),
                    Color(nsColor: .windowBackgroundColor)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 4) {
                ForEach(SettingsTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        HStack(spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(tab.color.gradient)
                                Image(systemName: tab.icon)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                            .frame(width: 24, height: 24)

                            Text(tab.rawValue)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.primary)

                            Spacer()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(
                                    selectedTab == tab
                                    ? Color.primary.opacity(0.09)
                                    : .clear
                                )
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 18)

            Spacer(minLength: 0)
        }
        .frame(width: 184)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let tab = selectedTab {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(tab.color.gradient)
                            Image(systemName: tab.icon)
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 64, height: 64)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(tab.rawValue)
                                .font(.system(size: 22, weight: .bold))

                            Text(tab.subtitle)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 24)

                    switch tab {
                    case .general:
                        GeneralSettingsView()
                    case .playback:
                        PlaybackSettingsView()
                    case .appearance:
                        AppearanceSettingsView()
                    }
                }
                .padding(.top, -18)
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        } else {
            ContentUnavailableView("Select a category", systemImage: "sidebar.left")
        }
    }
}

private extension SettingsWindowView.SettingsTab {
    var subtitle: String {
        switch self {
        case .general:
            return "Core app behavior and launch defaults"
        case .playback:
            return "Video speed and playback tuning"
        case .appearance:
            return "Theme and visual presentation"
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content
    let backgroundColor: Color
    
    init(
        _ title: String,
        backgroundColor: Color = Color(nsColor: .controlBackgroundColor).opacity(0.92),
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.backgroundColor = backgroundColor
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            
            VStack(spacing: 0) {
                content
            }
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
        }
    }
}

struct SettingsRow<Content: View>: View {
    let label: String
    let content: Content
    let showDivider: Bool
    let extraVerticalPadding: CGFloat
    
    init(
        _ label: String,
        showDivider: Bool = true,
        extraVerticalPadding: CGFloat = 0,
        @ViewBuilder content: () -> Content
    ) {
        self.label = label
        self.showDivider = showDivider
        self.extraVerticalPadding = extraVerticalPadding
        self.content = content()
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                }
                Spacer()
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11 + extraVerticalPadding)
            
            if showDivider {
                Divider()
                    .padding(.leading, 16)
            }
        }
    }
}

struct GeneralSettingsView: View {
    @AppStorage("autoPlayOnOpen") private var autoPlayOnOpen = true
    @AppStorage("rememberPlaybackPosition") private var rememberPlaybackPosition = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection("Behavior") {
                SettingsRow("Auto-play on Open") {
                    Toggle("", isOn: $autoPlayOnOpen)
                        .labelsHidden()
                }
                SettingsRow("Remember Playback Position", showDivider: false) {
                    Toggle("", isOn: $rememberPlaybackPosition)
                        .labelsHidden()
                }
            }
        }
    }
}

struct PlaybackSettingsView: View {
    @AppStorage("defaultPlaybackSpeed") private var defaultPlaybackSpeed = 1.0
    @AppStorage("loopMultiFilePlayback") private var loopMultiFilePlayback = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection("Speed") {
                SettingsRow("Default Playback Speed", showDivider: false) {
                    HStack {
                        Slider(value: $defaultPlaybackSpeed, in: 0.5...2.0, step: 0.25)
                            .frame(width: 130)
                        Text(String(format: "%.1fx", defaultPlaybackSpeed))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }

            SettingsSection(
                "Playback",
                backgroundColor: Color(nsColor: NSColor(calibratedWhite: 0.92, alpha: 1.0))
            ) {
                SettingsRow("Loop Multi-file Playback", showDivider: false, extraVerticalPadding: 4) {
                    Toggle("", isOn: $loopMultiFilePlayback)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
        }
    }
}

struct AppearanceSettingsView: View {
    @AppStorage("preferredAppearance") private var preferredAppearance = 0 
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection("Theme") {
                SettingsRow("Appearance", showDivider: false) {
                    Picker("", selection: $preferredAppearance) {
                        Text("Auto").tag(0)
                        Text("Light").tag(1)
                        Text("Dark").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
            }
        }
    }
}

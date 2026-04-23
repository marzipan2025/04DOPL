import SwiftUI
import AppKit

private let settingsWindowBackground = Color(nsColor: NSColor(calibratedWhite: 0.11, alpha: 1.0))
private let settingsSidebarBackground = Color(nsColor: NSColor(calibratedWhite: 0.07, alpha: 1.0))
private let settingsPanelBackground = Color(nsColor: NSColor(calibratedWhite: 0.14, alpha: 1.0))
private let settingsPanelStroke = Color.white.opacity(0.08)
private let settingsDividerColor = Color.white.opacity(0.08)

private enum SettingsFont {
    static func light(_ size: CGFloat) -> Font {
        .custom("BPdotsUnicase-Light", size: size)
    }

    static func regular(_ size: CGFloat) -> Font {
        .custom("BPdotsUnicase", size: size)
    }

    static func bold(_ size: CGFloat) -> Font {
        .custom("BPdotsUnicase-Bold", size: size)
    }
}

private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            AppDelegate.restoreSettingsWindowStyle(window)
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1.0)
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
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1.0)
            window.minSize = NSSize(width: 640, height: 460)
        }
    }
}

struct SettingsWindowView: View {
    @State private var selectedTab: SettingsTab? = .general
    
    enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case playback = "Playback"
        case licences = "Licences"
        
        var id: String { self.rawValue }
        
        var icon: String {
            switch self {
            case .general:    return "gearshape.fill"
            case .playback:   return "play.rectangle.fill"
            case .licences:   return "doc.text.fill"
            }
        }
        
        var color: Color {
            switch self {
            case .general:    return .purple
            case .playback:   return .blue
            case .licences:   return .orange
            }
        }
    }
    
    var body: some View {
        ZStack {
            SettingsWindowConfigurator()

            HStack(spacing: 0) {
                sidebar
                Rectangle()
                    .fill(settingsDividerColor)
                    .frame(width: 1)
                detailPane
            }
        }
        .frame(minWidth: 640, minHeight: 460)
        .background(settingsWindowBackground)
        .preferredColorScheme(.dark)
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
                                .font(SettingsFont.regular(14))
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
                                    ? Color.white.opacity(0.12)
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
        .background(settingsSidebarBackground)
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
                                .font(SettingsFont.bold(26))

                            Text(tab.subtitle)
                                .font(SettingsFont.light(14))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 24)

                    switch tab {
                    case .general:
                        GeneralSettingsView()
                    case .playback:
                        PlaybackSettingsView()
                    case .licences:
                        LicencesSettingsView()
                    }
                }
                .padding(.top, -18)
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(settingsWindowBackground)
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
            return "Playback behavior and peek controls"
        case .licences:
            return "Third-party notices and license information"
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content
    let backgroundColor: Color
    
    init(
        _ title: String,
        backgroundColor: Color = settingsPanelBackground,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.backgroundColor = backgroundColor
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(SettingsFont.regular(14))
                .foregroundColor(.secondary)
            
            VStack(spacing: 0) {
                content
            }
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(settingsPanelStroke, lineWidth: 0.5)
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
        extraVerticalPadding: CGFloat = 4,
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
                        .font(SettingsFont.regular(16))
                }
                Spacer()
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11 + extraVerticalPadding)
            
            if showDivider {
                Rectangle()
                    .fill(settingsDividerColor)
                    .frame(height: 1)
                    .padding(.horizontal, 16)
            }
        }
    }
}

struct GeneralSettingsView: View {
    @AppStorage("autoPlayOnOpen") private var autoPlayOnOpen = true
    @AppStorage("rememberPlaybackPosition") private var rememberPlaybackPosition = true
    @AppStorage(AppAccentColor.storageKey) private var accentColorRaw = AppAccentColor.defaultChoice.rawValue
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection("Behavior") {
                SettingsRow("Auto-play on Open") {
                    Toggle("", isOn: $autoPlayOnOpen)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                SettingsRow("Remember Playback Position", showDivider: false) {
                    Toggle("", isOn: $rememberPlaybackPosition)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            SettingsSection("Appearance") {
                SettingsRow("Accent Color", showDivider: false, extraVerticalPadding: 4) {
                    HStack(spacing: 13) {
                        ForEach(AppAccentColor.allCases) { choice in
                            AccentColorSwatch(
                                choice: choice,
                                isSelected: AppAccentColor.choice(for: accentColorRaw) == choice
                            ) {
                                accentColorRaw = choice.rawValue
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct AccentColorSwatch: View {
    let choice: AppAccentColor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(choice.color)

                if isSelected {
                    Circle()
                        .stroke(Color.white, lineWidth: 0.5)
                        .padding(4)
                }
            }
            .frame(width: 28, height: 28)
            .overlay(
                Circle()
                    .stroke(Color.primary.opacity(0.14), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help(choice.label)
        .accessibilityLabel(choice.label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

struct PlaybackSettingsView: View {
    @AppStorage("loopMultiFilePlayback") private var loopMultiFilePlayback = false
    @AppStorage("tapToPeek") private var tapToPeek = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection("Playback") {
                SettingsRow("Loop Multi-file Playback") {
                    Toggle("", isOn: $loopMultiFilePlayback)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                SettingsRow("Tap to Peek", showDivider: false) {
                    Toggle("", isOn: $tapToPeek)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
        }
    }
}

struct LicencesSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    Text(Self.licenseText)
                        .font(SettingsFont.regular(13))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 18)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 18)
                }
                .frame(maxWidth: .infinity, minHeight: 340, maxHeight: 340)
            }
            .background(settingsPanelBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(settingsPanelStroke, lineWidth: 0.5)
            )
        }
    }

    private static let licenseText = """
    04dopl third-party notices

    FFmpeg
    License: GPL-3.0-or-later
    Website: https://ffmpeg.org
    Bundled use: media probing, remuxing, and fallback transcoding for formats not handled directly by AVFoundation.

    FFmpeg libraries bundled in this app
    - libavdevice.62.dylib
    - libavfilter.11.dylib
    - libavformat.62.dylib
    - libavcodec.62.dylib
    - libswresample.6.dylib
    - libswscale.9.dylib
    - libavutil.60.dylib

    Additional bundled media libraries
    - libvmaf: BSD-2-Clause-Patent
    - OpenSSL 3: Apache-2.0
    - libvpx: BSD-3-Clause
    - dav1d: BSD-2-Clause
    - LAME: LGPL-2.0-or-later
    - Opus: BSD-3-Clause
    - SVT-AV1: BSD-3-Clause
    - x264: GPL-2.0-or-later
    - x265: GPL-2.0-or-later

    BPdots Unicase font family
    Copyright (c) 2007 George Triantafyllakos. All rights reserved.
    Website: http://www.backpacker.gr
    Bundled files:
    - bpdots.unicase-regular.otf
    - bpdots.unicase-light.otf
    - bpdots.unicase-bold.otf

    Apple frameworks
    This app also uses system frameworks provided by macOS, including SwiftUI, AppKit, AVFoundation, WebKit, UniformTypeIdentifiers, and Accelerate.

    -----

    If you believe any required notice or license information is missing, need support, or would like to discuss professional collaboration related to this app, please contact us through the project repository on GitHub:

    https://github.com/marzipan2025/04DOPL
    """
}

import SwiftUI
import AppKit

private let settingsWindowBackground = Color(nsColor: NSColor(calibratedWhite: 0.11, alpha: 1.0))
private let settingsSidebarBackground = Color(nsColor: NSColor(calibratedWhite: 0.095, alpha: 1.0))
private let settingsPanelStroke = Color.white.opacity(0.08)
private let settingsDividerColor = Color.white.opacity(0.08)
// 배경(0.07~0.11)보다 약간 밝은 비활성 텍스트, 활성 대비용 밝은 텍스트
private let settingsInactiveText = Color.white.opacity(0.30)
private let settingsRowText = Color.white.opacity(0.88)
private let settingsGroupTitleText = Color.white.opacity(0.52)

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
            window.minSize = NSSize(width: 408, height: 400)
            window.setContentSize(NSSize(
                width: max(window.frame.width, 408),
                height: 400
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
            window.minSize = NSSize(width: 408, height: 400)
            window.setContentSize(NSSize(
                width: max(window.frame.width, 408),
                height: 400
            ))
        }
    }
}

struct SettingsWindowView: View {
    @State private var selectedTab: SettingsTab? = .general
    @AppStorage(AppAccentColor.storageKey) private var accentColorRaw = AppAccentColor.defaultChoice.rawValue

    private var accentColor: Color {
        AppAccentColor.choice(for: accentColorRaw).color
    }

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case shortcuts = "Shortcuts"
        case licences = "Licences"

        var id: String { self.rawValue }

        var icon: String {
            switch self {
            case .general:    return "gearshape.fill"
            case .shortcuts:  return "command"
            case .licences:   return "doc.text.fill"
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
        .frame(minWidth: 408, minHeight: 400)
        .background(settingsWindowBackground)
        .preferredColorScheme(.dark)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 2) {
                ForEach(SettingsTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Text(tab.rawValue)
                            .font(SettingsFont.regular(16))
                            .foregroundStyle(selectedTab == tab ? accentColor : settingsInactiveText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 10)
                            .padding(.trailing, 6)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 18)

            Spacer(minLength: 0)
        }
        .frame(width: 147)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(settingsSidebarBackground)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let tab = selectedTab {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tab.rawValue)
                        .font(SettingsFont.bold(26))
                        .foregroundStyle(accentColor)

                    Text(tab.subtitle)
                        .font(SettingsFont.light(14))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 6)
                .padding(.horizontal, 28)

                Rectangle()
                    .fill(settingsDividerColor)
                    .frame(height: 1)
                    .padding(.top, 24)
                    .padding(.horizontal, 28)

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        switch tab {
                        case .general:
                            GeneralSettingsView()
                        case .shortcuts:
                            ShortcutsSettingsView()
                        case .licences:
                            LicencesSettingsView()
                        }
                    }
                    .padding(.top, 20)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
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
        case .shortcuts:
            return "Key inputs and gestures"
        case .licences:
            return "Third-party Licenses and copyrights"
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content

    init(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(SettingsFont.bold(16))
                .tracking(2.4)
                .foregroundStyle(settingsGroupTitleText)

            VStack(spacing: 0) {
                content
            }
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
                        .font(SettingsFont.light(16))
                        .foregroundStyle(settingsRowText)
                }
                Spacer()
                content
            }
            .padding(.vertical, 10 + extraVerticalPadding)

            if showDivider {
                Rectangle()
                    .fill(settingsDividerColor)
                    .frame(height: 1)
            }
        }
    }
}

/// OS 스위치 대신 쓰는 텍스트 토글. 현재 상태 단어만 강조 (ON=accent, OFF=밝은 회색).
struct OnOffToggle: View {
    @Binding var isOn: Bool
    @AppStorage(AppAccentColor.storageKey) private var accentColorRaw = AppAccentColor.defaultChoice.rawValue

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 7) {
                Text("ON")
                    .foregroundStyle(isOn ? AppAccentColor.choice(for: accentColorRaw).color : settingsInactiveText)
                Text("/")
                    .foregroundStyle(settingsInactiveText)
                Text("OFF")
                    .foregroundStyle(isOn ? settingsInactiveText : Color.white.opacity(0.75))
            }
            .font(SettingsFont.bold(16))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

struct GeneralSettingsView: View {
    @AppStorage("rememberPlaybackPosition") private var rememberPlaybackPosition = false
    @AppStorage("autoResizeWindowToVideo") private var autoResizeWindowToVideo = true
    @AppStorage("adaptiveSubtitleColor") private var adaptiveSubtitleColor = true
    @AppStorage("subtitleBackdropWhilePeeking") private var subtitleBackdropWhilePeeking = false
    @AppStorage("loopMultiFilePlayback") private var loopMultiFilePlayback = false
    @AppStorage("tapToPeek") private var tapToPeek = false
    @AppStorage("preventFullscreenDisplaySleep") private var preventFullscreenDisplaySleep = false
    @AppStorage(AppAccentColor.storageKey) private var accentColorRaw = AppAccentColor.defaultChoice.rawValue
    @State private var isResetConfirmationVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection("Behavior") {
                SettingsRow("Remember Playback Position") {
                    OnOffToggle(isOn: $rememberPlaybackPosition)
                }
                SettingsRow("Playback Loop") {
                    OnOffToggle(isOn: $loopMultiFilePlayback)
                }
                SettingsRow("Tap to Peek") {
                    OnOffToggle(isOn: $tapToPeek)
                }
                SettingsRow("Auto-resize Window to Video") {
                    OnOffToggle(isOn: $autoResizeWindowToVideo)
                }
                SettingsRow("Prevent Display Sleep in Fullscreen", showDivider: false) {
                    OnOffToggle(isOn: $preventFullscreenDisplaySleep)
                }
            }

            SettingsSection("Appearance") {
                SettingsRow("Accent Color", extraVerticalPadding: 4) {
                    HStack(spacing: 10) {
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
                SettingsRow("Adaptive Subtitle Color") {
                    OnOffToggle(isOn: $adaptiveSubtitleColor)
                }
                SettingsRow("Subtitle Backdrop While Peeking", showDivider: false) {
                    OnOffToggle(isOn: $subtitleBackdropWhilePeeking)
                }
            }

            VStack(alignment: .leading, spacing: 18) {
                Text("This will permanently clear preferences, history, cache, and remembered app state. It cannot be undone.")
                    .font(SettingsFont.regular(14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        isResetConfirmationVisible.toggle()
                    } label: {
                        SettingsFooterButtonLabel(
                            title: isResetConfirmationVisible ? "Cancel" : "Reset Everything",
                            foregroundColor: .primary,
                            backgroundColor: Color.white.opacity(0.08),
                            strokeColor: settingsPanelStroke
                        )
                    }
                    .buttonStyle(.plain)

                    if isResetConfirmationVisible {
                        Button {
                            NotificationCenter.default.post(name: .resetAppStateRequested, object: nil)
                            isResetConfirmationVisible = false
                        } label: {
                            SettingsFooterButtonLabel(
                                title: "Are you sure?",
                                foregroundColor: .white,
                                backgroundColor: AppAccentColor.choice(for: accentColorRaw).color
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct SettingsFooterButtonLabel: View {
    let title: String
    let foregroundColor: Color
    let backgroundColor: Color
    var strokeColor: Color? = nil

    var body: some View {
        Text(title)
            .font(SettingsFont.regular(14))
            .foregroundStyle(foregroundColor)
            .offset(y: -2)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay {
                if let strokeColor {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(strokeColor, lineWidth: 0.5)
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
                        .padding(3)
                }
            }
            .frame(width: 22, height: 22)
            .overlay(
                Circle()
                    .stroke(Color.primary.opacity(0.14), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(choice.label)
        .accessibilityLabel(choice.label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct ShortcutItem: Identifiable {
    let id = UUID()
    let input: String
    let action: String
}

private struct ShortcutRow: View {
    let item: ShortcutItem
    let showDivider: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                Text(item.action)
                    .font(SettingsFont.light(16))
                    .foregroundStyle(settingsRowText)

                Spacer()

                Text(item.input)
                    .font(SettingsFont.regular(13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.vertical, 12)

            if showDivider {
                Rectangle()
                    .fill(settingsDividerColor)
                    .frame(height: 1)
            }
        }
    }
}

struct ShortcutsSettingsView: View {
    private let generalKeyInputs: [ShortcutItem] = [
        .init(input: "Cmd + O", action: "Open file"),
        .init(input: "Cmd + U", action: "Open URL"),
        .init(input: "Cmd + I", action: "Open playback info"),
        .init(input: "Cmd + P", action: "Open subtitle file"),
        .init(input: "Cmd + E", action: "Export dot image as PNG"),
        .init(input: "Cmd + ,", action: "Open settings")
    ]

    private let playbackKeyInputs: [ShortcutItem] = [
        .init(input: "Space", action: "Play, pause, or resume last media"),
        .init(input: "Return", action: "Toggle fullscreen"),
        .init(input: "Left / Right", action: "Seek backward or forward by 10 seconds"),
        .init(input: "Shift + Left / Right", action: "Open previous or next file"),
        .init(input: ", / .", action: "Move one timeline column left or right"),
        .init(input: "0 to 9", action: "Jump to 0% through 90% of playback"),
        .init(input: "Up / Down", action: "Raise or lower volume"),
        .init(input: "W / S", action: "Increase or decrease dot size"),
        .init(input: "A / D", action: "Tighten or widen dot spacing"),
        .init(input: "Z", action: "Reset dot size and spacing"),
        .init(input: "B", action: "Background style"),
        .init(input: "T", action: "Toggle always on top"),
        .init(input: "P", action: "Switch subtitle source, or turn subtitles off"),
        .init(input: "[ / ]", action: "Decrease or increase subtitle size"),
        .init(input: "Cmd + 0", action: "Resize video window"),
        .init(input: "Cmd + - / =", action: "Zoom window out or in")
    ]

    private let generalGestures: [ShortcutItem] = [
        .init(input: "Drop File on Window", action: "Open media or replace the current file"),
        .init(input: "Double Click", action: "Toggle fullscreen")
    ]

    private let playbackGestures: [ShortcutItem] = [
        .init(input: "Single Click", action: "Play, pause, or resume last media"),
        .init(input: "Right Click on Dots", action: "Jump to the clicked playback position"),
        .init(input: "Scroll", action: "Adjust volume"),
        .init(input: "Fullscreen Drag", action: "Adjust dot size and spacing"),
        .init(input: "Peek Dot", action: "Hold to peek, or tap-toggle when Tap to Peek is on")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection("General Inputs") {
                ForEach(Array(generalKeyInputs.enumerated()), id: \.element.id) { index, item in
                    ShortcutRow(item: item, showDivider: index < generalKeyInputs.count - 1)
                }
            }

            SettingsSection("Playback Inputs") {
                ForEach(Array(playbackKeyInputs.enumerated()), id: \.element.id) { index, item in
                    ShortcutRow(item: item, showDivider: index < playbackKeyInputs.count - 1)
                }
            }

            SettingsSection("General Gestures") {
                ForEach(Array(generalGestures.enumerated()), id: \.element.id) { index, item in
                    ShortcutRow(item: item, showDivider: index < generalGestures.count - 1)
                }
            }

            SettingsSection("Playback Gestures") {
                ForEach(Array(playbackGestures.enumerated()), id: \.element.id) { index, item in
                    ShortcutRow(item: item, showDivider: index < playbackGestures.count - 1)
                }
            }
        }
    }
}

struct LicencesSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Self.licenseText)
                .font(SettingsFont.regular(13))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 2)

            Link(Self.repositoryURL.absoluteString, destination: Self.repositoryURL)
                .font(SettingsFont.regular(13))
                .foregroundStyle(.blue)
                .padding(.top, 2)
                .padding(.leading, 2)

            Spacer()
                .frame(height: 42)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let repositoryURL = URL(string: "https://github.com/marzipan2025/04DOPL")!

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
    """
}

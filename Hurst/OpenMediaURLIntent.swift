import AppIntents
import AppKit
import Foundation

struct OpenMediaURLIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Media URL"
    static var description = IntentDescription("Opens a directly playable media URL in 04dopl.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "URL")
    var url: String

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$url)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .result() }

        if NSApp.windows.first?.contentView != nil {
            NotificationCenter.default.post(
                name: .externalOpenMediaURL,
                object: nil,
                userInfo: ["url": value]
            )
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                NotificationCenter.default.post(
                    name: .externalOpenMediaURL,
                    object: nil,
                    userInfo: ["url": value]
                )
            }
        }

        return .result()
    }
}

struct HurstShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenMediaURLIntent(),
            phrases: [
                "Open media URL in \(.applicationName)",
                "Play media URL in \(.applicationName)"
            ],
            shortTitle: "Open Media URL",
            systemImageName: "link"
        )
    }
}

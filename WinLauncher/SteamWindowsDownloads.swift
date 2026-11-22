import Foundation

/// Opt-in platform override for Steam's own macOS client. Steam reads this file
/// before it builds the Library UI; a console command after launch is too late.
struct SteamWindowsDownloads {
    enum State: Equatable {
        case unavailable
        case disabled
        case enabled
        case enabledOutsideWinLauncher
        case conflictingOverride
    }

    enum ConfigurationError: LocalizedError {
        case steamUnavailable
        case unreadableConfiguration
        case conflictingOverride
        case modifiedManagedBlock

        var errorDescription: String? {
            switch self {
            case .steamUnavailable:
                String(localized: "The macOS Steam client is not installed or has not finished its first launch.")
            case .unreadableConfiguration:
                String(localized: "Steam's developer configuration is not UTF-8 text. WinLauncher left it unchanged.")
            case .conflictingOverride:
                String(localized: "Steam already has a platform override. Remove that setting before enabling this mode.")
            case .modifiedManagedBlock:
                String(localized: "The WinLauncher section in Steam's configuration was edited. WinLauncher left it unchanged.")
            }
        }
    }

    private static let begin = "# WinLauncher Windows downloads: begin"
    private static let end = "# WinLauncher Windows downloads: end"
    private static let override = "@sSteamCmdForcePlatformType windows"
    private static let block = "\n\(begin)\n\(override)\n\(end)\n"

    let clientMacOS: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        clientMacOS = home.appendingPathComponent(
            "Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS",
            isDirectory: true
        )
    }

    init(clientMacOS: URL) {
        self.clientMacOS = clientMacOS
    }

    var configurationURL: URL { clientMacOS.appendingPathComponent("steam_dev.cfg") }

    func state() -> State {
        guard FileManager.default.fileExists(atPath: clientMacOS.appendingPathComponent("steam_osx").path)
        else { return .unavailable }
        guard let contents = try? readConfiguration() else { return .conflictingOverride }
        let overrides = platformOverrides(in: contents)
        if contents.contains(Self.begin) || contents.contains(Self.end) {
            return contents.contains(Self.block) && overrides == [Self.override]
                ? .enabled : .conflictingOverride
        }
        if overrides.contains(Self.override) { return .enabledOutsideWinLauncher }
        return overrides.isEmpty ? .disabled : .conflictingOverride
    }

    func enable() throws {
        guard state() != .unavailable else { throw ConfigurationError.steamUnavailable }
        let contents = try readConfiguration()
        if contents.contains(Self.begin) || contents.contains(Self.end) {
            guard contents.contains(Self.block), platformOverrides(in: contents) == [Self.override]
            else { throw ConfigurationError.modifiedManagedBlock }
            return
        }
        guard platformOverrides(in: contents).isEmpty else { throw ConfigurationError.conflictingOverride }
        try writeConfiguration(contents + Self.block)
    }

    func disable() throws {
        let contents = try readConfiguration()
        guard contents.contains(Self.begin) || contents.contains(Self.end) else { return }
        guard contents.contains(Self.block) else { throw ConfigurationError.modifiedManagedBlock }
        let restored = contents.replacingOccurrences(of: Self.block, with: "")
        if restored.isEmpty {
            try FileManager.default.removeItem(at: configurationURL)
        } else {
            try writeConfiguration(restored)
        }
    }

    private func readConfiguration() throws -> String {
        guard FileManager.default.fileExists(atPath: configurationURL.path) else { return "" }
        let data = try Data(contentsOf: configurationURL)
        guard let contents = String(data: data, encoding: .utf8) else {
            throw ConfigurationError.unreadableConfiguration
        }
        return contents
    }

    private func writeConfiguration(_ contents: String) throws {
        try Data(contents.utf8).write(to: configurationURL, options: .atomic)
    }

    private func platformOverrides(in contents: String) -> [String] {
        contents.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("@sSteamCmdForcePlatformType") }
    }
}

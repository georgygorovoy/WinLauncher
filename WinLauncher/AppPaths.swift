import Foundation

struct AppPaths: Sendable {
    let root: URL

    init(fileManager: FileManager = .default) {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("WinLauncher", isDirectory: true)
    }

    var libraryFile: URL { root.appendingPathComponent("Library.json") }
    var engineSelection: URL { root.appendingPathComponent("Engine.json") }
    var engines: URL { root.appendingPathComponent("Engines", isDirectory: true) }
    var engineCache: URL { root.appendingPathComponent("Cache", isDirectory: true) }
    var dependencies: URL { root.appendingPathComponent("Dependencies", isDirectory: true) }
    var androidSDK: URL { root.appendingPathComponent("Android/SDK", isDirectory: true) }
    var androidAVDs: URL { root.appendingPathComponent("Android/AVD", isDirectory: true) }
    var androidCache: URL { root.appendingPathComponent("Android/Downloads", isDirectory: true) }
    var androidUser: URL { root.appendingPathComponent("Android/User", isDirectory: true) }
    var prefix: URL { root.appendingPathComponent("Environments/default/prefix", isDirectory: true) }
    var imports: URL { prefix.appendingPathComponent("drive_c/users/Public/WinLauncher", isDirectory: true) }
    var logs: URL { root.appendingPathComponent("Logs", isDirectory: true) }
    var extractedIcons: URL { prefix.appendingPathComponent("windata/cxmenu/icons/hicolor", isDirectory: true) }

    func hostURL(forWindowsPath windowsPath: String) -> URL? {
        guard windowsPath.lowercased().hasPrefix("c:\\") else { return nil }
        let relative = String(windowsPath.dropFirst(3)).replacingOccurrences(of: "\\", with: "/")
        return prefix.appendingPathComponent("drive_c/\(relative)")
    }

    func extractedIcon(for executableName: String, applicationName: String) -> URL? {
        let keys = [executableName, applicationName].map {
            $0.lowercased().filter { $0.isLetter || $0.isNumber }
        }.filter { !$0.isEmpty }
        guard let enumerator = FileManager.default.enumerator(
            at: extractedIcons,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var matches: [URL] = []
        while let url = enumerator.nextObject() as? URL, matches.count < 40 {
            guard url.pathExtension.lowercased() == "png" else { continue }
            let candidate = url.deletingPathExtension().lastPathComponent.lowercased()
                .filter { $0.isLetter || $0.isNumber }
            if keys.contains(where: { candidate.contains($0) || $0.contains(candidate) }) {
                matches.append(url)
            }
        }
        return matches.max { iconSize($0) < iconSize($1) }
    }

    private func iconSize(_ url: URL) -> Int {
        url.pathComponents.compactMap { component in
            component.split(separator: "x", maxSplits: 1).first.flatMap { Int($0) }
        }.max() ?? 0
    }

    func createBaseDirectories(fileManager: FileManager = .default) throws {
        for directory in [root, logs, engines, engineCache, dependencies, androidSDK, androidAVDs,
                          androidCache, androidUser, prefix.deletingLastPathComponent()] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        }
    }
}

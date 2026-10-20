import Foundation

struct DetectedWindowsApplication: Sendable {
    let name: String
    let windowsPath: String
}

actor InstalledApplicationDetector {
    private let paths: AppPaths

    init(paths: AppPaths) {
        self.paths = paths
    }

    func detect() -> [DetectedWindowsApplication] {
        let known: [(String, String)] = [
            ("Ubisoft Connect", "C:\\Program Files (x86)\\Ubisoft\\Ubisoft Game Launcher\\UbisoftConnect.exe"),
            ("Trackmania", "C:\\Program Files (x86)\\Ubisoft\\Ubisoft Game Launcher\\games\\Trackmania\\Trackmania.exe"),
            ("Steam", "C:\\Program Files (x86)\\Steam\\steam.exe"),
            ("Epic Games Launcher", "C:\\Program Files (x86)\\Epic Games\\Launcher\\Portal\\Binaries\\Win64\\EpicGamesLauncher.exe"),
            ("Battle.net", "C:\\Program Files (x86)\\Battle.net\\Battle.net.exe"),
            ("EA app", "C:\\Program Files\\Electronic Arts\\EA Desktop\\EA Desktop\\EALauncher.exe")
        ]
        var result: [DetectedWindowsApplication] = []
        var claimed = Set<String>()
        for (name, windowsPath) in known where fileExists(windowsPath) {
            result.append(.init(name: name, windowsPath: windowsPath))
            claimed.insert(windowsPath.lowercased())
        }

        for rootName in ["Program Files", "Program Files (x86)"] {
            let root = paths.prefix.appendingPathComponent("drive_c/\(rootName)", isDirectory: true)
            guard let vendors = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for vendor in vendors where isDirectory(vendor) && !ignoredDirectory(vendor.lastPathComponent) {
                let vendorPrefix = "c:\\\(rootName.lowercased())\\\(vendor.lastPathComponent.lowercased())\\"
                if claimed.contains(where: { $0.hasPrefix(vendorPrefix) }) { continue }
                guard let candidate = bestExecutable(in: vendor),
                      !claimed.contains(candidate.windowsPath.lowercased()) else { continue }
                result.append(candidate)
                claimed.insert(candidate.windowsPath.lowercased())
            }
        }
        return result
    }

    private func bestExecutable(in folder: URL) -> DetectedWindowsApplication? {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        var best: (score: Int, url: URL)?
        let baseDepth = folder.pathComponents.count
        while let url = enumerator.nextObject() as? URL {
            let depth = url.pathComponents.count - baseDepth
            if depth > 5 {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == "exe",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let lower = url.deletingPathExtension().lastPathComponent.lowercased()
            guard !ignoredExecutable(lower) else { continue }
            var score = 100 - depth * 8
            let folderName = folder.lastPathComponent.lowercased()
            if normalized(lower).contains(normalized(folderName)) || normalized(folderName).contains(normalized(lower)) {
                score += 50
            }
            if lower.contains("launcher") || lower.contains("client") { score += 12 }
            if best == nil || score > best!.score { best = (score, url) }
        }
        guard let url = best?.url else { return nil }
        let driveC = paths.prefix.appendingPathComponent("drive_c", isDirectory: true).path + "/"
        guard url.path.hasPrefix(driveC) else { return nil }
        let relative = String(url.path.dropFirst(driveC.count)).replacingOccurrences(of: "/", with: "\\")
        let displayName = cleanName(url.deletingPathExtension().lastPathComponent, fallback: folder.lastPathComponent)
        return .init(name: displayName, windowsPath: "C:\\\(relative)")
    }

    private func fileExists(_ windowsPath: String) -> Bool {
        guard windowsPath.lowercased().hasPrefix("c:\\") else { return false }
        let relative = String(windowsPath.dropFirst(3)).replacingOccurrences(of: "\\", with: "/")
        return FileManager.default.fileExists(
            atPath: paths.prefix.appendingPathComponent("drive_c/\(relative)").path
        )
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func ignoredDirectory(_ name: String) -> Bool {
        ["common files", "internet explorer", "windows media player", "windows nt"]
            .contains(name.lowercased())
    }

    private func ignoredExecutable(_ name: String) -> Bool {
        let fragments = [
            "unins", "uninstall", "setup", "install", "update", "updater", "crash", "report",
            "service", "helper", "webcore", "webview", "renderer", "redist", "vc_redist", "dxsetup"
        ]
        return fragments.contains { name.contains($0) }
    }

    private func normalized(_ value: String) -> String {
        value.filter { $0.isLetter }
    }

    private func cleanName(_ executableName: String, fallback: String) -> String {
        var value = executableName
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        for suffix in [" Launcher", " Client", " x64", " 64"] where value.lowercased().hasSuffix(suffix.lowercased()) {
            value.removeLast(suffix.count)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : value
    }
}

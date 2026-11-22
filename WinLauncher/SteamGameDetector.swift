import Foundation

struct SteamWindowsGame: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let executable: URL
    let artwork: URL?
}

struct SteamGameDetector {
    let steamRoot: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        steamRoot = home.appendingPathComponent("Library/Application Support/Steam", isDirectory: true)
    }

    init(steamRoot: URL) {
        self.steamRoot = steamRoot
    }

    func detect() -> [SteamWindowsGame] {
        let fileManager = FileManager.default
        var libraries = [steamRoot]
        let folders = steamRoot.appendingPathComponent("steamapps/libraryfolders.vdf")
        if let text = try? String(contentsOf: folders, encoding: .utf8) {
            for path in Self.values(for: "path", in: text) {
                let library = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
                if !libraries.contains(library) { libraries.append(library) }
            }
        }

        var games: [SteamWindowsGame] = []
        var claimed = Set<String>()
        for library in libraries {
            let steamapps = library.appendingPathComponent("steamapps", isDirectory: true)
            guard let manifests = try? fileManager.contentsOfDirectory(
                at: steamapps, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for manifest in manifests where manifest.lastPathComponent.hasPrefix("appmanifest_") &&
                manifest.pathExtension == "acf" {
                guard let text = try? String(contentsOf: manifest, encoding: .utf8),
                      let id = Self.value(for: "appid", in: text),
                      !id.isEmpty, id.allSatisfy(\.isNumber), !claimed.contains(id),
                      let name = Self.value(for: "name", in: text),
                      let folder = Self.value(for: "installdir", in: text),
                      !folder.isEmpty, folder != ".", folder != "..",
                      !folder.contains("/"), !folder.contains("\\") else { continue }
                let gameFolder = steamapps.appendingPathComponent("common/\(folder)", isDirectory: true)
                guard let executable = Self.executable(in: gameFolder, matching: folder) else { continue }
                let cache = steamRoot.appendingPathComponent("appcache/librarycache/\(id)", isDirectory: true)
                let artwork = (try? fileManager.contentsOfDirectory(
                    at: cache, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                ))?.first(where: { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) })
                games.append(.init(id: id, name: name, executable: executable, artwork: artwork))
                claimed.insert(id)
            }
        }
        return games.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func executable(in folder: URL, matching name: String) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return nil }
        let candidates = files.filter { url in
            url.pathExtension.caseInsensitiveCompare("exe") == .orderedSame &&
            safeExecutableName(url.lastPathComponent) &&
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true &&
            !["setup", "install", "uninstall", "update", "crash", "redist"].contains(where: { fragment in
                url.lastPathComponent.lowercased().contains(fragment)
            })
        }
        let normalizedName = name.lowercased().filter(\.isLetter)
        return candidates.max { left, right in
            func score(_ url: URL) -> Int {
                let stem = url.deletingPathExtension().lastPathComponent.lowercased().filter(\.isLetter)
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return (stem == normalizedName ? 1_000_000_000 : 0) + min(size, 500_000_000)
            }
            return score(left) < score(right)
        }
    }

    private static func safeExecutableName(_ name: String) -> Bool {
        name.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || " ._-()".unicodeScalars.contains($0))
        }
    }

    private static func value(for key: String, in text: String) -> String? {
        values(for: key, in: text).first
    }

    private static func values(for key: String, in text: String) -> [String] {
        let pattern = "(?m)^\\s*\"\(NSRegularExpression.escapedPattern(for: key))\"\\s*\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap {
            guard let valueRange = Range($0.range(at: 1), in: text) else { return nil }
            return String(text[valueRange])
        }
    }
}

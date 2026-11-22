import AppKit
import CryptoKit
import Foundation

/// Repairs Steam's cached launch entries while Steam is closed. The cache is
/// versioned and Steam can replace entries when it refreshes game metadata.
struct SteamPlayBridge: Sendable {
    enum BridgeError: LocalizedError {
        case unsupportedCache
        case malformedCache
        case changedDuringRepair
        case missingLauncher
        case steamRunning

        var errorDescription: String? {
            switch self {
            case .unsupportedCache: String(localized: "Steam changed its appinfo.vdf format. WinLauncher left it unchanged.")
            case .malformedCache: String(localized: "Steam's appinfo.vdf could not be read safely. WinLauncher left it unchanged.")
            case .changedDuringRepair: String(localized: "Steam updated appinfo.vdf during repair. WinLauncher will retry later.")
            case .missingLauncher: String(localized: "The Steam Play launcher is missing from this WinLauncher build.")
            case .steamRunning: String(localized: "Steam is open. Close it so WinLauncher can repair the launch cache.")
            }
        }
    }

    struct Result: Sendable {
        let checked: Int
        let repaired: Int
    }

    struct Inspection: Sendable {
        let routed: Int
        let needsRepair: Int
        let unavailable: Int

        var isHealthy: Bool { needsRepair == 0 && unavailable == 0 }
    }

    let steamRoot: URL
    let sourceLauncher: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         sourceLauncher: URL? = Bundle.main.url(forResource: "steam-play-launch", withExtension: "sh")) {
        steamRoot = home.appendingPathComponent("Library/Application Support/Steam", isDirectory: true)
        self.sourceLauncher = sourceLauncher ?? URL(fileURLWithPath: "/nonexistent/steam-play-launch.sh")
    }

    init(steamRoot: URL, sourceLauncher: URL) {
        self.steamRoot = steamRoot
        self.sourceLauncher = sourceLauncher
    }

    /// Reads Steam's cache without changing it. Safe to call while Steam is open.
    func inspect(games: [SteamWindowsGame]) throws -> Inspection {
        let candidates = games.filter(safe)
        guard !candidates.isEmpty else { return Inspection(routed: 0, needsRepair: 0, unavailable: 0) }
        let cache = steamRoot.appendingPathComponent("appcache/appinfo.vdf")
        guard FileManager.default.fileExists(atPath: cache.path) else {
            return Inspection(routed: 0, needsRepair: 0, unavailable: candidates.count)
        }
        let editor = try AppInfoEditor(Data(contentsOf: cache))
        let source = try? Data(contentsOf: sourceLauncher)
        var routed = 0
        var needsRepair = 0
        var unavailable = 0
        for game in candidates where !editor.isNativeMac(game) {
            if editor.isRouted(game) {
                let launcher = launcherURL(for: game)
                if let source, (try? Data(contentsOf: launcher)) == source,
                   FileManager.default.isExecutableFile(atPath: launcher.path) {
                    routed += 1
                } else {
                    needsRepair += 1
                }
            } else if editor.isOriginal(game) {
                needsRepair += 1
            } else {
                unavailable += 1
            }
        }
        return Inspection(routed: routed, needsRepair: needsRepair, unavailable: unavailable)
    }

    func repair(games: [SteamWindowsGame]) throws -> Result {
        guard !games.isEmpty else { return Result(checked: 0, repaired: 0) }
        guard !SteamProcessState.isRunning() else { throw BridgeError.steamRunning }
        guard FileManager.default.fileExists(atPath: sourceLauncher.path) else { throw BridgeError.missingLauncher }
        let cache = steamRoot.appendingPathComponent("appcache/appinfo.vdf")
        guard FileManager.default.fileExists(atPath: cache.path) else { return Result(checked: 0, repaired: 0) }
        let original = try Data(contentsOf: cache)
        var editor = try AppInfoEditor(original)
        var changedGames: [SteamWindowsGame] = []
        var supportedGames: [SteamWindowsGame] = []
        var checked = 0
        for game in games {
            guard safe(game) else { continue }
            if let changed = try editor.route(game) {
                checked += 1
                supportedGames.append(game)
                if changed { changedGames.append(game) }
            }
        }
        guard try Data(contentsOf: cache) == original else { throw BridgeError.changedDuringRepair }
        var repairedIDs = Set(changedGames.map(\.id))
        for game in supportedGames {
            if try installLauncher(for: game) { repairedIDs.insert(game.id) }
        }
        guard !changedGames.isEmpty else { return Result(checked: checked, repaired: repairedIDs.count) }
        let updated = try editor.encoded()
        let backup = cache.deletingLastPathComponent().appendingPathComponent(
            "appinfo.vdf.winlauncher-backup-\(Int(Date().timeIntervalSince1970))"
        )
        try original.write(to: backup, options: .atomic)
        guard !SteamProcessState.isRunning() else { throw BridgeError.steamRunning }
        guard try Data(contentsOf: cache) == original else { throw BridgeError.changedDuringRepair }
        let permissions = (try? FileManager.default.attributesOfItem(atPath: cache.path)[.posixPermissions]) as? NSNumber
        try updated.write(to: cache, options: .atomic)
        if let permissions {
            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: cache.path)
        }
        do {
            let verified = try AppInfoEditor(Data(contentsOf: cache))
            for game in changedGames {
                guard verified.isRouted(game) else { throw BridgeError.malformedCache }
            }
        } catch {
            // Restore only if the bytes are still the ones we wrote.
            if (try? Data(contentsOf: cache)) == updated { try? original.write(to: cache, options: .atomic) }
            throw error
        }
        return Result(checked: checked, repaired: repairedIDs.count)
    }

    /// Remove WinLauncher's own cached launch commands when a native-first
    /// Steam Play compatibility tool takes over game selection and launching.
    func restore(games: [SteamWindowsGame]) throws -> Result {
        guard !games.isEmpty else { return Result(checked: 0, repaired: 0) }
        let cache = steamRoot.appendingPathComponent("appcache/appinfo.vdf")
        guard FileManager.default.fileExists(atPath: cache.path) else { return Result(checked: 0, repaired: 0) }
        let original = try Data(contentsOf: cache)
        var editor = try AppInfoEditor(original)
        var changedGames: [SteamWindowsGame] = []
        var checked = 0
        for game in games where safe(game) {
            if let changed = try editor.restore(game) {
                checked += 1
                if changed { changedGames.append(game) }
            }
        }
        guard !changedGames.isEmpty else { return Result(checked: checked, repaired: 0) }
        let updated = try editor.encoded()
        guard try Data(contentsOf: cache) == original else { throw BridgeError.changedDuringRepair }
        let backup = cache.deletingLastPathComponent().appendingPathComponent(
            "appinfo.vdf.winlauncher-backup-\(Int(Date().timeIntervalSince1970))"
        )
        try original.write(to: backup, options: .atomic)
        guard try Data(contentsOf: cache) == original else { throw BridgeError.changedDuringRepair }
        let permissions = (try? FileManager.default.attributesOfItem(atPath: cache.path)[.posixPermissions]) as? NSNumber
        try updated.write(to: cache, options: .atomic)
        if let permissions {
            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: cache.path)
        }
        do {
            let verified = try AppInfoEditor(Data(contentsOf: cache))
            for game in changedGames {
                guard verified.isOriginal(game) else { throw BridgeError.malformedCache }
            }
        } catch {
            if (try? Data(contentsOf: cache)) == updated { try? original.write(to: cache, options: .atomic) }
            throw error
        }
        return Result(checked: checked, repaired: changedGames.count)
    }

    private func safe(_ game: SteamWindowsGame) -> Bool {
        let folder = game.executable.deletingLastPathComponent().lastPathComponent
        let executable = game.executable.lastPathComponent
        return !game.id.isEmpty && game.id.allSatisfy(\.isNumber) &&
            !folder.isEmpty && folder != "." && folder != ".." &&
            folder.range(of: #"^[A-Za-z0-9 ._()-]+$"#, options: .regularExpression) != nil &&
            executable.range(of: #"^[A-Za-z0-9._()-]+\.exe$"#, options: .regularExpression) != nil
    }

    private func installLauncher(for game: SteamWindowsGame) throws -> Bool {
        let destination = launcherURL(for: game)
        let source = try Data(contentsOf: sourceLauncher)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let needsInstall = (try? Data(contentsOf: destination)) != source
        if needsInstall {
            try source.write(to: destination, options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        return needsInstall
    }

    private func launcherURL(for game: SteamWindowsGame) -> URL {
        game.executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WinLauncher/steam-play-launch.sh")
    }
}

enum SteamProcessState {
    static func isRunning() -> Bool {
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        check.arguments = ["-x", "steam_osx"]
        check.standardOutput = FileHandle.nullDevice
        check.standardError = FileHandle.nullDevice
        guard (try? check.run()) != nil else { return false }
        check.waitUntilExit()
        return check.terminationStatus == 0
    }
}

struct SteamProcessLog {
    let steamRoot: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        steamRoot = home.appendingPathComponent("Library/Application Support/Steam", isDirectory: true)
    }

    func failedLaunchIDsInCurrentSession() -> Set<String> {
        let log = steamRoot.appendingPathComponent("logs/gameprocess_log.txt")
        guard let data = try? Data(contentsOf: log),
              let text = String(data: data.suffix(1_000_000), encoding: .utf8) else { return [] }
        var failed = Set<String>()
        for line in text.components(separatedBy: .newlines) {
            if line.contains("] Client version:") { failed.removeAll() }
            guard line.contains("Failed running GameID "), line.contains("(OS Error 0)"),
                  let marker = line.range(of: "Failed running GameID ") else { continue }
            let tail = line[marker.upperBound...]
            let id = tail.prefix(while: \.isNumber)
            if !id.isEmpty { failed.insert(String(id)) }
        }
        return failed
    }
}

private struct AppInfoEditor {
    private indirect enum Value {
        case object([Entry])
        case string(String)
        case number(UInt32)
    }
    private struct Entry {
        var key: String
        var value: Value
    }
    private struct Record {
        let start: Int
        let end: Int
        let header: Data
        var entries: [Entry]
    }

    private let original: Data
    private let tableStart: Int
    private var strings: [String]
    private var records: [UInt32: Record] = [:]
    private var changed = Set<UInt32>()
    private let launcherPath = "../WinLauncher/steam-play-launch.sh"

    init(_ data: Data) throws {
        original = data
        guard data.count >= 20,
              Self.uint64(data, at: 0) == 0x107564429,
              let offset = Self.uint64(data, at: 8),
              offset >= 20, offset < data.count else { throw SteamPlayBridge.BridgeError.unsupportedCache }
        tableStart = Int(offset)
        var cursor = tableStart
        guard let count = Self.uint32(data, at: cursor), count < 100_000 else {
            throw SteamPlayBridge.BridgeError.malformedCache
        }
        cursor += 4
        var pool: [String] = []
        for _ in 0..<count { pool.append(try Self.readString(data, cursor: &cursor)) }
        guard cursor == data.count else { throw SteamPlayBridge.BridgeError.malformedCache }
        strings = pool

        cursor = 16
        while cursor + 4 <= tableStart {
            guard let id = Self.uint32(data, at: cursor) else { throw SteamPlayBridge.BridgeError.malformedCache }
            if id == 0 {
                guard cursor + 4 == tableStart else { throw SteamPlayBridge.BridgeError.malformedCache }
                break
            }
            guard let size = Self.uint32(data, at: cursor + 4), size >= 60,
                  cursor + Int(size) + 8 <= tableStart else { throw SteamPlayBridge.BridgeError.malformedCache }
            let end = cursor + Int(size) + 8
            var valueCursor = cursor + 68
            let entries = try Self.readEntries(data, cursor: &valueCursor, strings: pool)
            guard valueCursor == end else { throw SteamPlayBridge.BridgeError.malformedCache }
            records[id] = Record(start: cursor, end: end, header: data.subdata(in: cursor..<(cursor + 68)), entries: entries)
            cursor = end
        }
    }

    mutating func route(_ game: SteamWindowsGame) throws -> Bool? {
        guard let id = UInt32(game.id), var record = records[id] else { return nil }
        // A dual-platform app belongs to native macOS Steam. Only a real Steam
        // compatibility tool can select its Windows depots per game.
        if isNativeMac(game) { return nil }
        let arguments = "\(game.id) \"\(game.executable.deletingLastPathComponent().lastPathComponent)\" \"\(game.executable.lastPathComponent)\""
        var found = false
        var modified = false
        for rootIndex in record.entries.indices where record.entries[rootIndex].key == "appinfo" {
            guard case .object(var app) = record.entries[rootIndex].value else { continue }
            for configIndex in app.indices where app[configIndex].key == "config" {
                guard case .object(var config) = app[configIndex].value else { continue }
                for launchIndex in config.indices where config[launchIndex].key == "launch" {
                    guard case .object(var launches) = config[launchIndex].value else { continue }
                    for optionIndex in launches.indices {
                        guard case .object(var option) = launches[optionIndex].value,
                              let exeIndex = option.firstIndex(where: { $0.key == "executable" }),
                              case .string(let executable) = option[exeIndex].value else { continue }
                        let isOriginal = executable == game.executable.lastPathComponent
                        let isOurs = executable == launcherPath
                        guard isOriginal || isOurs else { continue }
                        if isOriginal && option.contains(where: { $0.key == "arguments" }) { continue }
                        if let os = option.first(where: { $0.key == "config" }),
                           case .object(let flags) = os.value,
                           let list = flags.first(where: { $0.key == "oslist" }),
                           case .string(let platforms) = list.value,
                           !platforms.contains("windows") { continue }
                        found = true
                        if isOriginal || option.first(where: { $0.key == "arguments" }).flatMap({
                            if case .string(let value) = $0.value { value } else { nil }
                        }) != arguments {
                            option[exeIndex].value = .string(launcherPath)
                            if let argumentIndex = option.firstIndex(where: { $0.key == "arguments" }) {
                                option[argumentIndex].value = .string(arguments)
                            } else {
                                option.append(Entry(key: "arguments", value: .string(arguments)))
                            }
                            launches[optionIndex].value = .object(option)
                            modified = true
                        }
                    }
                    config[launchIndex].value = .object(launches)
                }
                app[configIndex].value = .object(config)
            }
            record.entries[rootIndex].value = .object(app)
        }
        guard found else { return nil }
        if modified { records[id] = record; changed.insert(id) }
        return modified
    }

    mutating func restore(_ game: SteamWindowsGame) throws -> Bool? {
        guard let id = UInt32(game.id), var record = records[id] else { return nil }
        var found = false
        var modified = false
        for rootIndex in record.entries.indices where record.entries[rootIndex].key == "appinfo" {
            guard case .object(var app) = record.entries[rootIndex].value else { continue }
            for configIndex in app.indices where app[configIndex].key == "config" {
                guard case .object(var config) = app[configIndex].value else { continue }
                for launchIndex in config.indices where config[launchIndex].key == "launch" {
                    guard case .object(var launches) = config[launchIndex].value else { continue }
                    for optionIndex in launches.indices {
                        guard case .object(var option) = launches[optionIndex].value,
                              let exeIndex = option.firstIndex(where: { $0.key == "executable" }),
                              case .string(let executable) = option[exeIndex].value else { continue }
                        if executable == game.executable.lastPathComponent { found = true; continue }
                        guard executable == launcherPath,
                              let argumentsIndex = option.firstIndex(where: { $0.key == "arguments" }),
                              case .string(let arguments) = option[argumentsIndex].value,
                              arguments.hasPrefix("\(game.id) \"") else { continue }
                        found = true
                        option[exeIndex].value = .string(game.executable.lastPathComponent)
                        option.remove(at: argumentsIndex)
                        launches[optionIndex].value = .object(option)
                        modified = true
                    }
                    config[launchIndex].value = .object(launches)
                }
                app[configIndex].value = .object(config)
            }
            record.entries[rootIndex].value = .object(app)
        }
        guard found else { return nil }
        if modified { records[id] = record; changed.insert(id) }
        return modified
    }

    func isOriginal(_ game: SteamWindowsGame) -> Bool {
        guard let id = UInt32(game.id), let record = records[id] else { return false }
        for root in record.entries where root.key == "appinfo" {
            guard case .object(let app) = root.value else { continue }
            for config in app where config.key == "config" {
                guard case .object(let fields) = config.value else { continue }
                for launch in fields where launch.key == "launch" {
                    guard case .object(let choices) = launch.value else { continue }
                    for choice in choices {
                        guard case .object(let option) = choice.value else { continue }
                        if option.contains(where: { if case .string(let value) = $0.value { $0.key == "executable" && value == game.executable.lastPathComponent } else { false } }) {
                            return true
                        }
                    }
                }
            }
        }
        return false
    }

    func isNativeMac(_ game: SteamWindowsGame) -> Bool {
        guard let id = UInt32(game.id), let record = records[id] else { return false }
        for root in record.entries where root.key == "appinfo" {
            guard case .object(let app) = root.value else { continue }
            for common in app where common.key == "common" {
                guard case .object(let fields) = common.value else { continue }
                for platform in fields where platform.key == "oslist" {
                    if case .string(let list) = platform.value,
                       list.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).contains("macos") {
                        return true
                    }
                }
            }
        }
        return false
    }

    func isRouted(_ game: SteamWindowsGame) -> Bool {
        guard let id = UInt32(game.id), let record = records[id] else { return false }
        let expected = "\(game.id) \"\(game.executable.deletingLastPathComponent().lastPathComponent)\" \"\(game.executable.lastPathComponent)\""
        for root in record.entries where root.key == "appinfo" {
            guard case .object(let app) = root.value else { continue }
            for config in app where config.key == "config" {
                guard case .object(let fields) = config.value else { continue }
                for launch in fields where launch.key == "launch" {
                    guard case .object(let choices) = launch.value else { continue }
                    for choice in choices {
                        guard case .object(let option) = choice.value else { continue }
                        if option.contains(where: { if case .string(let value) = $0.value { $0.key == "executable" && value == launcherPath } else { false } }) &&
                           option.contains(where: { if case .string(let value) = $0.value { $0.key == "arguments" && value == expected } else { false } }) {
                            return true
                        }
                    }
                }
            }
        }
        return false
    }

    mutating func encoded() throws -> Data {
        var result = Data(original.prefix(16))
        var cursor = 16
        while cursor + 4 < tableStart {
            guard let id = Self.uint32(original, at: cursor), id != 0,
                  let record = records[id] else { throw SteamPlayBridge.BridgeError.malformedCache }
            if changed.contains(id) {
                let body = try encodeEntries(record.entries)
                var header = record.header
                Self.putUInt32(UInt32(body.count + 60), into: &header, at: 4)
                header.replaceSubrange(24..<44, with: Insecure.SHA1.hash(data: text(record.entries)).withUnsafeBytes { Data($0) })
                header.replaceSubrange(48..<68, with: Insecure.SHA1.hash(data: body).withUnsafeBytes { Data($0) })
                result.append(header)
                result.append(body)
            } else {
                result.append(original.subdata(in: record.start..<record.end))
            }
            cursor = record.end
        }
        result.append(contentsOf: [0, 0, 0, 0])
        let newTableStart = result.count
        Self.putUInt64(UInt64(newTableStart), into: &result, at: 8)
        Self.appendUInt32(UInt32(strings.count), to: &result)
        for value in strings { result.append(contentsOf: value.utf8); result.append(0) }
        return result
    }

    private mutating func encodeEntries(_ entries: [Entry]) throws -> Data {
        var result = Data()
        for entry in entries {
            let index: Int
            if let existing = strings.firstIndex(of: entry.key) { index = existing }
            else { strings.append(entry.key); index = strings.count - 1 }
            switch entry.value {
            case .object(let children):
                result.append(0)
                Self.appendUInt32(UInt32(index), to: &result)
                result.append(try encodeEntries(children))
            case .string(let value):
                result.append(1)
                Self.appendUInt32(UInt32(index), to: &result)
                result.append(contentsOf: value.utf8)
                result.append(0)
            case .number(let value):
                result.append(2)
                Self.appendUInt32(UInt32(index), to: &result)
                Self.appendUInt32(value, to: &result)
            }
        }
        result.append(8)
        return result
    }

    private func text(_ entries: [Entry], depth: Int = 0) -> Data {
        var output = Data()
        let tabs = String(repeating: "\t", count: depth)
        for entry in entries {
            let key = entry.key.replacingOccurrences(of: "\\", with: "\\\\")
            switch entry.value {
            case .object(let children):
                output.append(contentsOf: "\(tabs)\"\(key)\"\n\(tabs){\n".utf8)
                output.append(text(children, depth: depth + 1))
                output.append(contentsOf: "\(tabs)}\n".utf8)
            case .string(let value):
                let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
                output.append(contentsOf: "\(tabs)\"\(key)\"\t\t\"\(escaped)\"\n".utf8)
            case .number(let value):
                output.append(contentsOf: "\(tabs)\"\(key)\"\t\t\"\(value)\"\n".utf8)
            }
        }
        return output
    }

    private static func readEntries(_ data: Data, cursor: inout Int, strings: [String]) throws -> [Entry] {
        var entries: [Entry] = []
        while cursor < data.count {
            let type = data[cursor]
            cursor += 1
            if type == 8 { return entries }
            guard let keyIndex = uint32(data, at: cursor), Int(keyIndex) < strings.count else {
                throw SteamPlayBridge.BridgeError.malformedCache
            }
            cursor += 4
            let value: Value
            switch type {
            case 0: value = .object(try readEntries(data, cursor: &cursor, strings: strings))
            case 1: value = .string(try readString(data, cursor: &cursor))
            case 2:
                guard let number = uint32(data, at: cursor) else { throw SteamPlayBridge.BridgeError.malformedCache }
                cursor += 4
                value = .number(number)
            default: throw SteamPlayBridge.BridgeError.unsupportedCache
            }
            entries.append(Entry(key: strings[Int(keyIndex)], value: value))
        }
        throw SteamPlayBridge.BridgeError.malformedCache
    }

    private static func readString(_ data: Data, cursor: inout Int) throws -> String {
        guard cursor < data.count, let end = data[cursor...].firstIndex(of: 0),
              let value = String(data: data.subdata(in: cursor..<end), encoding: .utf8) else {
            throw SteamPlayBridge.BridgeError.malformedCache
        }
        cursor = end + 1
        return value
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << (8 * $1) }
    }
    private static func uint64(_ data: Data, at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        return (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[offset + $1]) << (8 * $1) }
    }
    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
    private static func putUInt32(_ value: UInt32, into data: inout Data, at offset: Int) {
        for byte in 0..<4 { data[offset + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8)) }
    }
    private static func putUInt64(_ value: UInt64, into data: inout Data, at offset: Int) {
        for byte in 0..<8 { data[offset + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8)) }
    }
}

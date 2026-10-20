import CryptoKit
import Foundation

struct WineEngineInstallation: Codable, Sendable, Equatable {
    let name: String
    let version: String
    let winePath: String
    let wineServerPath: String
    let rootPath: String

    var wineURL: URL { URL(fileURLWithPath: winePath) }
    var wineServerURL: URL { URL(fileURLWithPath: wineServerPath) }
    var rootURL: URL { URL(fileURLWithPath: rootPath, isDirectory: true) }
}

actor EngineManager {
    // Pinned and hash-verified so an upstream metadata change cannot silently
    // replace executable code. WineForge carries narrowly scoped, LGPL-licensed
    // launcher fixes for Ubisoft Connect, Battle.net, EA App and Steam on macOS.
    private static let managedVersion = "0.6.0.5"
    private static let managedArchiveURL = URL(
        string: "https://github.com/Alien4042x/WineForge/releases/download/0.6.0.5/WineForge.dmg"
    )!
    private static let managedSHA256 = "6c2fe692b58c3657bba4f84ff28758edaceec8b9d7ba8c2e95b346c7bfd3243e"
    private let paths: AppPaths
    private let runner: ProcessRunner

    init(paths: AppPaths, runner: ProcessRunner) {
        self.paths = paths
        self.runner = runner
    }

    func resolve() async -> WineEngineInstallation? {
        if let engine = await validate(managedWineRoot, preferredName: "WinLauncher WineForge 11") {
            try? save(engine)
            return engine
        }
        if let saved = loadSaved(),
           !isObsoleteManagedEngine(saved),
           let engine = await validate(saved.wineURL, preferredName: saved.name) {
            return engine
        }
        for candidate in automaticCandidates() {
            if let engine = await validate(candidate.url, preferredName: candidate.name) {
                try? save(engine)
                return engine
            }
        }
        return nil
    }

    func resolveOrInstall() async throws -> WineEngineInstallation {
        if let engine = await resolve() { return engine }
        return try await installManagedEngine()
    }

    func select(_ url: URL) async throws -> WineEngineInstallation {
        guard let engine = await validate(url, preferredName: url.deletingPathExtension().lastPathComponent) else {
            throw WinLauncherError.invalidEngine
        }
        try save(engine)
        return engine
    }

    private func validate(_ selectedURL: URL, preferredName: String) async -> WineEngineInstallation? {
        let selected = selectedURL.standardizedFileURL.resolvingSymlinksInPath()
        let candidates = [
            selected,
            selected.appendingPathComponent("bin/wine"),
            selected.appendingPathComponent("bin/wine64"),
            selected.appendingPathComponent("Contents/Resources/wine/bin/wine"),
            selected.appendingPathComponent("Contents/SharedSupport/wine/bin/wine")
        ]
        guard let wine = candidates.first(where: {
            let values = try? $0.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true && FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            return nil
        }
        let bin = wine.deletingLastPathComponent()
        let wineserver = bin.appendingPathComponent("wineserver")
        guard FileManager.default.isExecutableFile(atPath: wineserver.path) else { return nil }
        let root = bin.deletingLastPathComponent()
        guard engineFilesAreComplete(root: root) else { return nil }
        let result = try? await runner.run(
            executable: wine,
            arguments: ["--version"],
            environment: ProcessInfo.processInfo.environment,
            logURL: paths.logs.appendingPathComponent("engine-check.log")
        )
        guard let result, result.terminationStatus == 0 else { return nil }
        let version = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard version.lowercased().contains("wine") else { return nil }
        return WineEngineInstallation(
            name: preferredName.isEmpty ? "Wine" : preferredName,
            version: version,
            winePath: wine.path,
            wineServerPath: wineserver.path,
            rootPath: root.path
        )
    }

    private func automaticCandidates() -> [(name: String, url: URL)] {
        return [
            ("WinLauncher Wine 11", managedWineRoot),
            ("Wine Stable", URL(fileURLWithPath: "/Applications/Wine Stable.app")),
            ("Wine Staging", URL(fileURLWithPath: "/Applications/Wine Staging.app")),
            ("Wine Devel", URL(fileURLWithPath: "/Applications/Wine Devel.app")),
            ("Homebrew Wine", URL(fileURLWithPath: "/opt/homebrew/bin/wine")),
            ("Wine", URL(fileURLWithPath: "/usr/local/bin/wine"))
        ]
    }

    private var managedInstall: URL {
        paths.engines.appendingPathComponent("wineforge-\(Self.managedVersion)", isDirectory: true)
    }

    private var managedWineRoot: URL {
        managedInstall.appendingPathComponent("WineForgeCore", isDirectory: true)
    }

    private func installManagedEngine() async throws -> WineEngineInstallation {
        try paths.createBaseDirectories()
        let archive = paths.engineCache.appendingPathComponent("wineforge-\(Self.managedVersion).dmg")
        if !fileMatchesHash(archive) {
            try? FileManager.default.removeItem(at: archive)
            do {
                let (temporary, response) = try await URLSession.shared.download(from: Self.managedArchiveURL)
                if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
                    throw WinLauncherError.engineDownloadFailed("The server returned HTTP \(http.statusCode).")
                }
                try FileManager.default.moveItem(at: temporary, to: archive)
            } catch let error as WinLauncherError {
                throw error
            } catch {
                throw WinLauncherError.engineDownloadFailed(error.localizedDescription)
            }
        }
        guard fileMatchesHash(archive) else {
            try? FileManager.default.removeItem(at: archive)
            throw WinLauncherError.engineIntegrityFailed
        }

        let staging = paths.engines.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        let mountPoint = staging.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let log = paths.logs.appendingPathComponent("engine-install.log")
        let attachment = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: ["attach", "-nobrowse", "-readonly", "-mountpoint", mountPoint.path, archive.path],
            environment: ProcessInfo.processInfo.environment,
            logURL: log
        )
        guard attachment.terminationStatus == 0 else {
            throw WinLauncherError.engineFilesBlocked(log)
        }
        var isMounted = true
        defer {
            if isMounted {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                process.arguments = ["detach", mountPoint.path, "-force"]
                try? process.run()
                process.waitUntilExit()
            }
        }

        let mountedResources = mountPoint.appendingPathComponent(
            "WineForge.app/Contents/Resources", isDirectory: true
        )
        let mountedCore = mountedResources.appendingPathComponent(
            "Engine/WineForgeCore", isDirectory: true
        )
        let stagedWine = staging.appendingPathComponent("WineForgeCore", isDirectory: true)
        do {
            try FileManager.default.copyItem(at: mountedCore, to: stagedWine)
            let mountedLicenses = mountedResources.appendingPathComponent("Licenses", isDirectory: true)
            if FileManager.default.fileExists(atPath: mountedLicenses.path) {
                try FileManager.default.copyItem(
                    at: mountedLicenses,
                    to: staging.appendingPathComponent("Licenses", isDirectory: true)
                )
            }
        } catch {
            throw WinLauncherError.engineFilesBlocked(log)
        }
        guard let stagedEngine = await validate(stagedWine, preferredName: "WinLauncher WineForge 11") else {
            throw WinLauncherError.engineFilesBlocked(log)
        }

        let detachment = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: ["detach", mountPoint.path],
            environment: ProcessInfo.processInfo.environment,
            logURL: log
        )
        guard detachment.terminationStatus == 0 else {
            throw WinLauncherError.engineInstallationFailed(log)
        }
        isMounted = false
        try? FileManager.default.removeItem(at: mountPoint)

        let backup = paths.engines.appendingPathComponent(".previous", isDirectory: true)
        try? FileManager.default.removeItem(at: backup)
        if FileManager.default.fileExists(atPath: managedInstall.path) {
            try FileManager.default.moveItem(at: managedInstall, to: backup)
        }
        do {
            try FileManager.default.moveItem(at: staging, to: managedInstall)
        } catch {
            if FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.moveItem(at: backup, to: managedInstall)
            }
            throw WinLauncherError.engineInstallationFailed(log)
        }
        try? FileManager.default.removeItem(at: backup)
        guard let installed = await validate(managedWineRoot, preferredName: stagedEngine.name) else {
            throw WinLauncherError.engineFilesBlocked(log)
        }
        try save(installed)
        try? FileManager.default.removeItem(at: archive)
        return installed
    }

    private func isObsoleteManagedEngine(_ engine: WineEngineInstallation) -> Bool {
        let enginesPath = paths.engines.standardizedFileURL.path + "/"
        return engine.rootURL.standardizedFileURL.path.hasPrefix(enginesPath) &&
            engine.rootURL.standardizedFileURL != managedWineRoot.standardizedFileURL
    }

    private func fileMatchesHash(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
                hasher.update(data: data)
            }
        } catch { return false }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return actual == Self.managedSHA256
    }

    private func engineFilesAreComplete(root: URL) -> Bool {
        let windows = root.appendingPathComponent("lib/wine/x86_64-windows", isDirectory: true)
        guard FileManager.default.fileExists(atPath: windows.path) else {
            // A future engine may use a different layout; `wine --version` remains its check.
            return true
        }
        for name in ["kernel32.dll", "ntdll.dll", "shell32.dll", "user32.dll"] {
            guard FileManager.default.isReadableFile(atPath: windows.appendingPathComponent(name).path) else {
                return false
            }
        }
        let win32 = root.appendingPathComponent("lib/wine/i386-windows", isDirectory: true)
        if FileManager.default.fileExists(atPath: win32.path) {
            for name in ["kernel32.dll", "ntdll.dll", "shell32.dll", "user32.dll", "mscoree.dll"] {
                guard FileManager.default.isReadableFile(atPath: win32.appendingPathComponent(name).path) else {
                    return false
                }
            }
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: win32.path)) ?? []
            guard entries.count >= 750 else { return false }
        }
        return true
    }

    private func loadSaved() -> WineEngineInstallation? {
        guard let data = try? Data(contentsOf: paths.engineSelection) else { return nil }
        return try? JSONDecoder().decode(WineEngineInstallation.self, from: data)
    }

    private func save(_ engine: WineEngineInstallation) throws {
        try paths.createBaseDirectories()
        let data = try JSONEncoder().encode(engine)
        try data.write(to: paths.engineSelection, options: .atomic)
    }
}

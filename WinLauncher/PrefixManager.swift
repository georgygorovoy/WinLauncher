import Foundation

actor PrefixManager {
    private let paths: AppPaths
    private let runner: ProcessRunner

    init(paths: AppPaths, runner: ProcessRunner) {
        self.paths = paths
        self.runner = runner
    }

    func prepareIfNeeded(engine: WineEngineInstallation) async throws {
        guard FileManager.default.isExecutableFile(atPath: engine.winePath) else {
            throw WinLauncherError.engineNotInstalled
        }
        try paths.createBaseDirectories()
        let registry = paths.prefix.appendingPathComponent("system.reg")
        let readyMarker = paths.prefix.appendingPathComponent(".winlauncher-ready")
        let expectedIdentity = "\(engine.version)\n\(engine.rootPath)\n"
        if let currentIdentity = try? String(contentsOf: readyMarker, encoding: .utf8),
           currentIdentity == expectedIdentity,
           FileManager.default.fileExists(atPath: registry.path) {
            return
        }
        try FileManager.default.createDirectory(at: paths.prefix, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        _ = try? await runner.run(
            executable: engine.wineServerURL,
            arguments: ["-k"],
            environment: wineEnvironment(engine: engine, includeArchitecture: true),
            logURL: paths.logs.appendingPathComponent("environment-stop.log")
        )
        let result = try await runner.run(
            executable: engine.wineURL,
            arguments: ["wineboot", "--init"],
            environment: wineEnvironment(engine: engine, includeArchitecture: true),
            logURL: paths.logs.appendingPathComponent("environment-init.log")
        )
        guard result.terminationStatus == 0 else {
            throw WinLauncherError.processFailed("Windows Environment setup", result.terminationStatus, result.logURL)
        }
        try? FileManager.default.removeItem(at: paths.prefix.appendingPathComponent("dosdevices/z:"))
        let systemDirectory = paths.prefix.appendingPathComponent("drive_c/windows/system32", isDirectory: true)
        guard FileManager.default.fileExists(atPath: registry.path),
              FileManager.default.fileExists(atPath: systemDirectory.path) else {
            throw WinLauncherError.environmentInitializationFailed(result.logURL)
        }
        try Data(expectedIdentity.utf8).write(to: readyMarker, options: .atomic)
    }

    func importExecutable(_ source: URL) throws -> (windowsPath: String, storedURL: URL) {
        let folderName = UUID().uuidString
        let destinationFolder = paths.imports.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let destination = destinationFolder.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: destination)
        return ("C:\\users\\Public\\WinLauncher\\\(folderName)\\\(source.lastPathComponent)", destination)
    }

    func mapApplicationFolder(for source: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw WinLauncherError.applicationFilesMissing
        }
        let dosDevices = paths.prefix.appendingPathComponent("dosdevices", isDirectory: true)
        let mapping = dosDevices.appendingPathComponent("x:")
        if FileManager.default.fileExists(atPath: mapping.path) {
            try FileManager.default.removeItem(at: mapping)
        }
        try FileManager.default.createSymbolicLink(
            at: mapping,
            withDestinationURL: source.deletingLastPathComponent()
        )
        return "X:\\\(source.lastPathComponent)"
    }

    func repair(engine: WineEngineInstallation) async throws {
        try? FileManager.default.removeItem(at: paths.prefix.appendingPathComponent(".winlauncher-ready"))
        try await prepareIfNeeded(engine: engine)
    }

    func stop(engine: WineEngineInstallation) async throws {
        _ = try await runner.run(
            executable: engine.wineServerURL,
            arguments: ["-k"],
            environment: wineEnvironment(engine: engine),
            logURL: paths.logs.appendingPathComponent("environment-stop.log")
        )
    }

    func runTool(_ arguments: [String], engine: WineEngineInstallation) async throws {
        let result = try await runner.run(
            executable: engine.wineURL,
            arguments: arguments,
            environment: wineEnvironment(engine: engine),
            logURL: paths.logs.appendingPathComponent("tool-\(Int(Date().timeIntervalSince1970)).log")
        )
        guard result.terminationStatus == 0 else {
            throw WinLauncherError.processFailed(arguments.first ?? "Windows tool", result.terminationStatus, result.logURL)
        }
    }

    func wineEnvironment(engine: WineEngineInstallation, includeArchitecture: Bool = false) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["WINEPREFIX"] = paths.prefix.path
        let defaults = UserDefaults.standard
        environment["WINEDEBUG"] = defaults.bool(forKey: "diagnosticLogging") ? "all" : "err+all"
        environment["WINEDLLOVERRIDES"] = "dxgi,d3d10,d3d10core,d3d11,winemetal=b"
        let synchronization = defaults.object(forKey: "synchronizationEnabled") == nil || defaults.bool(forKey: "synchronizationEnabled")
        environment["WINEESYNC"] = synchronization ? "1" : "0"
        environment["WINEMSYNC"] = synchronization ? "1" : "0"
        environment["LC_ALL"] = "C"
        environment["PATH"] = "\(engine.wineURL.deletingLastPathComponent().path):/usr/bin:/bin:/usr/sbin:/sbin"
        var libraryPaths = [engine.rootURL.appendingPathComponent("lib").path]
        let sharedSupport = engine.rootURL.deletingLastPathComponent()
        if sharedSupport.lastPathComponent == "SharedSupport" {
            let contents = sharedSupport.deletingLastPathComponent()
            let frameworks = contents.appendingPathComponent("Frameworks")
            let gstreamer = frameworks.appendingPathComponent("GStreamer.framework/Libraries")
            libraryPaths.insert(frameworks.path, at: 0)
            libraryPaths.append(gstreamer.path)
            environment["GST_PLUGIN_PATH"] = gstreamer.appendingPathComponent("gstreamer-1.0").path
        }
        environment["DYLD_FALLBACK_LIBRARY_PATH"] = libraryPaths.joined(separator: ":")
        let bundledGStreamer = engine.rootURL.appendingPathComponent("lib/gstreamer-1.0", isDirectory: true)
        if FileManager.default.fileExists(atPath: bundledGStreamer.path) {
            environment["GST_PLUGIN_PATH"] = bundledGStreamer.path
            environment["GST_PLUGIN_SYSTEM_PATH"] = bundledGStreamer.path
        }
        let dxmtRuntime = engine.rootURL.appendingPathComponent("lib/dxmt", isDirectory: true)
        let graphicsMode = defaults.string(forKey: "graphicsMode") ?? "Automatic"
        if graphicsMode != "Compatibility", FileManager.default.fileExists(atPath: dxmtRuntime.path) {
            environment["GRAPHICS_BACKEND"] = "dxmt"
            environment["DXMT_RUNTIME_DIR"] = dxmtRuntime.path
            environment["DXMT_CEF_RUNTIME_DIR"] = dxmtRuntime.path
        }
        if graphicsMode == "Compatibility" {
            environment.removeValue(forKey: "GRAPHICS_BACKEND")
            environment.removeValue(forKey: "DXMT_RUNTIME_DIR")
            environment.removeValue(forKey: "DXMT_CEF_RUNTIME_DIR")
        }
        if defaults.bool(forKey: "allowHomeFolder") {
            let mapping = paths.prefix.appendingPathComponent("dosdevices/h:")
            if !FileManager.default.fileExists(atPath: mapping.path) {
                try? FileManager.default.createSymbolicLink(
                    at: mapping,
                    withDestinationURL: FileManager.default.homeDirectoryForCurrentUser
                )
            }
        } else {
            try? FileManager.default.removeItem(at: paths.prefix.appendingPathComponent("dosdevices/h:"))
        }
        if let raw = defaults.string(forKey: "customEnvironmentVariables") {
            for line in raw.split(whereSeparator: \.isNewline) {
                let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2, !pair[0].isEmpty { environment[pair[0]] = pair[1] }
            }
        }
        environment["WINEBOOT_HIDE_DIALOG"] = "1"
        if includeArchitecture { environment["WINEARCH"] = "win64" }
        return environment
    }
}

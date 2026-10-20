import Foundation

struct AndroidRuntimeInstallation: Sendable {
    let sdkRoot: URL
    let adbURL: URL
    let emulatorURL: URL
    let packageToolURL: URL?
    let virtualDeviceName: String
}

struct AndroidLaunchResult: Sendable {
    let packageIdentifier: String
    let logURL: URL
}

actor AndroidRuntimeManager {
    private let paths: AppPaths
    private let runner: ProcessRunner
    private var emulatorProcess: Process?

    init(paths: AppPaths, runner: ProcessRunner) {
        self.paths = paths
        self.runner = runner
    }

    func resolve() async throws -> AndroidRuntimeInstallation {
        guard let root = sdkCandidates().first(where: isUsableSDK) else {
            throw WinLauncherError.androidSDKNotInstalled
        }
        let emulator = root.appendingPathComponent("emulator/emulator")
        let adb = root.appendingPathComponent("platform-tools/adb")
        let listLog = paths.logs.appendingPathComponent("android-avd-list.log")
        let result = try await runner.run(
            executable: emulator,
            arguments: ["-list-avds"],
            environment: toolEnvironment(sdkRoot: root),
            logURL: listLog
        )
        let names = result.output.split(whereSeparator: \.isNewline).map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let avd = preferredVirtualDevice(from: names) else {
            throw WinLauncherError.androidVirtualDeviceMissing
        }
        return AndroidRuntimeInstallation(
            sdkRoot: root,
            adbURL: adb,
            emulatorURL: emulator,
            packageToolURL: packageTool(in: root),
            virtualDeviceName: avd
        )
    }

    func launch(apkURL: URL, knownPackage: String?) async throws -> AndroidLaunchResult {
        let runtime = try await resolve()
        let stamp = Int(Date().timeIntervalSince1970)
        let log = paths.logs.appendingPathComponent("android-\(stamp).log")
        let packageFromAPK: String?
        if let knownPackage {
            packageFromAPK = knownPackage
        } else {
            packageFromAPK = try? await packageIdentifier(
                for: apkURL,
                tool: runtime.packageToolURL,
                environment: toolEnvironment(sdkRoot: runtime.sdkRoot),
                logURL: paths.logs.appendingPathComponent("android-package-\(stamp).log")
            )
        }

        if !(await emulatorIsReady(runtime: runtime, stamp: stamp)) {
            try startEmulator(runtime: runtime, logURL: log)
            try await waitUntilReady(runtime: runtime, stamp: stamp)
        }
        let packagesBefore = try? await thirdPartyPackages(runtime: runtime, stamp: stamp)

        let install = try await runner.run(
            executable: runtime.adbURL,
            arguments: ["-e", "install", "-r", "-d", apkURL.path],
            environment: toolEnvironment(sdkRoot: runtime.sdkRoot),
            logURL: log
        )
        guard install.terminationStatus == 0, install.output.contains("Success") else {
            throw WinLauncherError.androidInstallFailed(log)
        }

        var package = packageFromAPK
        if package == nil, let before = packagesBefore {
            let after = try await thirdPartyPackages(runtime: runtime, stamp: stamp + 1)
            package = after.subtracting(before).sorted().first
        }
        guard let package, !package.isEmpty else {
            throw WinLauncherError.androidPackageUnknown(log)
        }

        let open = try await runner.run(
            executable: runtime.adbURL,
            arguments: ["-e", "shell", "monkey", "-p", package,
                        "-c", "android.intent.category.LAUNCHER", "1"],
            environment: toolEnvironment(sdkRoot: runtime.sdkRoot),
            logURL: log
        )
        guard open.terminationStatus == 0,
              !open.output.localizedCaseInsensitiveContains("no activities found") else {
            throw WinLauncherError.androidPackageUnknown(log)
        }
        return AndroidLaunchResult(packageIdentifier: package, logURL: log)
    }

    func saveSDKRoot(_ url: URL) {
        UserDefaults.standard.set(url.standardizedFileURL.path, forKey: "androidSDKRoot")
    }

    func clearSDKRoot() {
        UserDefaults.standard.removeObject(forKey: "androidSDKRoot")
    }

    private func sdkCandidates() -> [URL] {
        var values: [String] = []
        if let saved = UserDefaults.standard.string(forKey: "androidSDKRoot") { values.append(saved) }
        for key in ["ANDROID_SDK_ROOT", "ANDROID_HOME"] {
            if let value = ProcessInfo.processInfo.environment[key] { values.append(value) }
        }
        values.append(NSHomeDirectory() + "/Library/Android/sdk")
        values.append("/opt/homebrew/share/android-commandlinetools")
        var seen = Set<String>()
        return values.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            .filter { seen.insert($0.path).inserted }
    }

    private func isUsableSDK(_ root: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("platform-tools/adb").path) &&
            FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("emulator/emulator").path)
    }

    private func preferredVirtualDevice(from names: [String]) -> String? {
        let avdRoot = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".android/avd", isDirectory: true)
        let arm = names.first { name in
            let config = avdRoot.appendingPathComponent("\(name).avd/config.ini")
            let value = (try? String(contentsOf: config, encoding: .utf8))?.lowercased() ?? ""
            return value.contains("abi.type=arm64-v8a") || value.contains("arm64-v8a")
        }
        return arm ?? names.first
    }

    private func packageTool(in root: URL) -> URL? {
        let buildTools = root.appendingPathComponent("build-tools", isDirectory: true)
        guard let versions = try? FileManager.default.contentsOfDirectory(
            at: buildTools,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for version in versions.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            for name in ["aapt", "aapt2"] {
                let tool = version.appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: tool.path) { return tool }
            }
        }
        return nil
    }

    private func packageIdentifier(for apk: URL, tool: URL?, environment: [String: String],
                                   logURL: URL) async throws -> String? {
        guard let tool else { return nil }
        let isAAPT2 = tool.lastPathComponent == "aapt2"
        let arguments = isAAPT2 ? ["dump", "packagename", apk.path] : ["dump", "badging", apk.path]
        let result = try await runner.run(executable: tool, arguments: arguments,
                                          environment: environment, logURL: logURL)
        guard result.terminationStatus == 0 else { return nil }
        if isAAPT2 {
            return result.output.split(whereSeparator: \.isWhitespace).first.map(String.init)
        }
        guard let range = result.output.range(of: #"package: name='([^']+)'"#,
                                               options: .regularExpression) else { return nil }
        let match = String(result.output[range])
        return match.split(separator: "'").dropFirst().first.map(String.init)
    }

    private func emulatorIsReady(runtime: AndroidRuntimeInstallation, stamp: Int) async -> Bool {
        let result = try? await runner.run(
            executable: runtime.adbURL,
            arguments: ["-e", "shell", "getprop", "sys.boot_completed"],
            environment: toolEnvironment(sdkRoot: runtime.sdkRoot),
            logURL: paths.logs.appendingPathComponent("android-boot-check-\(stamp).log")
        )
        return result?.terminationStatus == 0 && result?.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    private func startEmulator(runtime: AndroidRuntimeInstallation, logURL: URL) throws {
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logURL)
        let process = Process()
        process.executableURL = runtime.emulatorURL
        process.arguments = ["@\(runtime.virtualDeviceName)", "-no-boot-anim", "-netdelay", "none", "-netspeed", "full"]
        process.environment = toolEnvironment(sdkRoot: runtime.sdkRoot)
        process.standardOutput = handle
        process.standardError = handle
        process.terminationHandler = { _ in try? handle.close() }
        try process.run()
        emulatorProcess = process
    }

    private func waitUntilReady(runtime: AndroidRuntimeInstallation, stamp: Int) async throws {
        for attempt in 0..<150 {
            if await emulatorIsReady(runtime: runtime, stamp: stamp + attempt) { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw WinLauncherError.androidEmulatorDidNotStart(
            paths.logs.appendingPathComponent("android-\(stamp).log")
        )
    }

    private func thirdPartyPackages(runtime: AndroidRuntimeInstallation, stamp: Int) async throws -> Set<String> {
        let result = try await runner.run(
            executable: runtime.adbURL,
            arguments: ["-e", "shell", "pm", "list", "packages", "-3"],
            environment: toolEnvironment(sdkRoot: runtime.sdkRoot),
            logURL: paths.logs.appendingPathComponent("android-packages-\(stamp).log")
        )
        guard result.terminationStatus == 0 else { return [] }
        return Set(result.output.split(whereSeparator: \.isNewline).map {
            String($0).replacingOccurrences(of: "package:", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
    }

    private func toolEnvironment(sdkRoot: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["ANDROID_SDK_ROOT"] = sdkRoot.path
        environment["ANDROID_HOME"] = sdkRoot.path
        return environment
    }
}

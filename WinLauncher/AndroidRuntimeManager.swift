import CryptoKit
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
    private struct ManagedPackage: Sendable {
        let name: String
        let url: URL
        let sha1: String
        let fileName: String
    }

    private static let managedDeviceName = "WinLauncher_API_30"
    private static let packages = [
        ManagedPackage(
            name: "Android platform tools",
            url: URL(string: "https://dl.google.com/android/repository/platform-tools_r37.0.1-darwin.zip")!,
            sha1: "6ae73f4de6452dc57e62ec02b68eed92a4c21661",
            fileName: "platform-tools_r37.0.1-darwin.zip"
        ),
        ManagedPackage(
            name: "Android emulator",
            url: URL(string: "https://dl.google.com/android/repository/emulator-darwin_aarch64-16555280.zip")!,
            sha1: "4cd3b6f14336a0085b8992eeffe637864839b4ce",
            fileName: "emulator-darwin_aarch64-16555280.zip"
        ),
        ManagedPackage(
            name: "Android 11 ARM64 image",
            url: URL(string: "https://dl.google.com/android/repository/sys-img/android/arm64-v8a-30_r02.zip")!,
            sha1: "e96298145a5e0bfd6da4816f51b06c520d8dba72",
            fileName: "arm64-v8a-30_r02.zip"
        )
    ]
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

    func installManagedSupport(
        progress: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> AndroidRuntimeInstallation {
        try paths.createBaseDirectories()
        let staging = paths.root.appendingPathComponent("Android/.install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        var archives: [URL] = []
        for (index, package) in Self.packages.enumerated() {
            await progress("Downloading \(package.name)… \(index + 1) of \(Self.packages.count)")
            archives.append(try await download(package))
        }

        await progress("Installing the lightweight Android runtime…")
        try await extract(archives[0], to: staging, logName: "android-extract-platform-tools.log")
        try await extract(archives[1], to: staging, logName: "android-extract-emulator.log")
        let imageParent = staging.appendingPathComponent("system-images/android-30/default", isDirectory: true)
        try FileManager.default.createDirectory(at: imageParent, withIntermediateDirectories: true)
        try await extract(archives[2], to: imageParent, logName: "android-extract-image.log")
        try normalizeSystemImage(in: imageParent)
        try await compactDiskImages(in: staging)

        guard FileManager.default.isExecutableFile(atPath: staging.appendingPathComponent("platform-tools/adb").path),
              FileManager.default.isExecutableFile(atPath: staging.appendingPathComponent("emulator/emulator").path),
              FileManager.default.fileExists(atPath: staging.appendingPathComponent(
                "system-images/android-30/default/arm64-v8a/system.img"
              ).path) else {
            throw WinLauncherError.androidInstallationFailed(
                paths.logs.appendingPathComponent("android-install.log")
            )
        }

        let backup = paths.root.appendingPathComponent("Android/.previous-sdk", isDirectory: true)
        try? FileManager.default.removeItem(at: backup)
        if FileManager.default.fileExists(atPath: paths.androidSDK.path) {
            try FileManager.default.moveItem(at: paths.androidSDK, to: backup)
        }
        do {
            try FileManager.default.moveItem(at: staging, to: paths.androidSDK)
        } catch {
            if FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.moveItem(at: backup, to: paths.androidSDK)
            }
            throw error
        }
        try? FileManager.default.removeItem(at: backup)
        try createManagedVirtualDevice()
        try await createADBKeyIfNeeded()
        UserDefaults.standard.set(paths.androidSDK.path, forKey: "androidSDKRoot")
        let installation = try await resolve()
        for archive in archives {
            try? FileManager.default.removeItem(at: archive)
        }
        await progress("Android Support is ready.")
        return installation
    }

    func saveSDKRoot(_ url: URL) {
        UserDefaults.standard.set(url.standardizedFileURL.path, forKey: "androidSDKRoot")
    }

    func clearSDKRoot() {
        UserDefaults.standard.removeObject(forKey: "androidSDKRoot")
    }

    private func sdkCandidates() -> [URL] {
        var values: [String] = [paths.androidSDK.path]
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
        let managedAvailable = FileManager.default.fileExists(
            atPath: paths.androidAVDs.appendingPathComponent("\(Self.managedDeviceName).avd/config.ini").path
        )
        if managedAvailable, names.contains(Self.managedDeviceName) { return Self.managedDeviceName }
        let avdRoot = managedAvailable
            ? paths.androidAVDs
            : URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".android/avd", isDirectory: true)
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
        process.arguments = ["@\(runtime.virtualDeviceName)", "-no-boot-anim", "-no-metrics", "-no-snapshot",
                             "-netdelay", "none", "-netspeed", "full"]
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
        environment["ANDROID_USER_HOME"] = paths.androidUser.path
        environment["ADB_VENDOR_KEYS"] = paths.androidUser.path
        if FileManager.default.fileExists(atPath: paths.androidAVDs.path),
           ((try? FileManager.default.contentsOfDirectory(atPath: paths.androidAVDs.path).isEmpty) == false) {
            environment["ANDROID_AVD_HOME"] = paths.androidAVDs.path
        }
        return environment
    }

    private func createADBKeyIfNeeded() async throws {
        let key = paths.androidUser.appendingPathComponent("adbkey")
        if FileManager.default.fileExists(atPath: key.path) { return }
        let adb = paths.androidSDK.appendingPathComponent("platform-tools/adb")
        let result = try await runner.run(
            executable: adb,
            arguments: ["keygen", key.path],
            environment: toolEnvironment(sdkRoot: paths.androidSDK),
            logURL: paths.logs.appendingPathComponent("android-adb-key.log")
        )
        guard result.terminationStatus == 0,
              FileManager.default.fileExists(atPath: key.path) else {
            throw WinLauncherError.androidInstallationFailed(result.logURL)
        }
    }

    private func download(_ package: ManagedPackage) async throws -> URL {
        let destination = paths.androidCache.appendingPathComponent(package.fileName)
        if fileMatchesSHA1(destination, expected: package.sha1) { return destination }
        try? FileManager.default.removeItem(at: destination)
        do {
            let (temporary, response) = try await URLSession.shared.download(from: package.url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw WinLauncherError.androidDownloadFailed("The server returned HTTP \(http.statusCode).")
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch let error as WinLauncherError {
            throw error
        } catch {
            throw WinLauncherError.androidDownloadFailed(error.localizedDescription)
        }
        guard fileMatchesSHA1(destination, expected: package.sha1) else {
            try? FileManager.default.removeItem(at: destination)
            throw WinLauncherError.androidIntegrityFailed
        }
        return destination
    }

    private func fileMatchesSHA1(_ url: URL, expected: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        do {
            while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
                hasher.update(data: data)
            }
        } catch { return false }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined() == expected
    }

    private func extract(_ archive: URL, to destination: URL, logName: String) async throws {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", archive.path, destination.path],
            environment: ProcessInfo.processInfo.environment,
            logURL: paths.logs.appendingPathComponent(logName)
        )
        guard result.terminationStatus == 0 else {
            throw WinLauncherError.androidInstallationFailed(result.logURL)
        }
    }

    private func normalizeSystemImage(in parent: URL) throws {
        let expected = parent.appendingPathComponent("arm64-v8a", isDirectory: true)
        if FileManager.default.fileExists(atPath: expected.appendingPathComponent("system.img").path) { return }
        if FileManager.default.fileExists(atPath: parent.appendingPathComponent("system.img").path) {
            try FileManager.default.createDirectory(at: expected, withIntermediateDirectories: true)
            for item in try FileManager.default.contentsOfDirectory(at: parent,
                                                                     includingPropertiesForKeys: nil)
            where item != expected {
                try FileManager.default.moveItem(at: item, to: expected.appendingPathComponent(item.lastPathComponent))
            }
            return
        }
        throw WinLauncherError.androidInstallationFailed(
            paths.logs.appendingPathComponent("android-install.log")
        )
    }

    private func compactDiskImages(in sdkRoot: URL) async throws {
        let imageRoot = sdkRoot.appendingPathComponent(
            "system-images/android-30/default/arm64-v8a",
            isDirectory: true
        )
        let qemuImage = sdkRoot.appendingPathComponent("emulator/qemu-img")
        guard FileManager.default.isExecutableFile(atPath: qemuImage.path) else {
            throw WinLauncherError.androidInstallationFailed(
                paths.logs.appendingPathComponent("android-compact-images.log")
            )
        }
        for name in ["system", "vendor", "userdata", "encryptionkey"] {
            let source = imageRoot.appendingPathComponent("\(name).img")
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let compacted = imageRoot.appendingPathComponent(".\(name)-compact.img")
            let result = try await runner.run(
                executable: qemuImage,
                arguments: ["convert", "-f", "raw", "-O", "raw", "-S", "4k",
                            source.path, compacted.path],
                environment: ProcessInfo.processInfo.environment,
                logURL: paths.logs.appendingPathComponent("android-compact-images.log")
            )
            guard result.terminationStatus == 0 else {
                try? FileManager.default.removeItem(at: compacted)
                throw WinLauncherError.androidInstallationFailed(result.logURL)
            }
            try FileManager.default.removeItem(at: source)
            try FileManager.default.moveItem(at: compacted, to: source)
        }
    }

    private func createManagedVirtualDevice() throws {
        let device = paths.androidAVDs.appendingPathComponent("\(Self.managedDeviceName).avd", isDirectory: true)
        try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
        let config = """
        AvdId=\(Self.managedDeviceName)
        PlayStore.enabled=false
        abi.type=arm64-v8a
        avd.ini.displayname=WinLauncher Android 11
        avd.ini.encoding=UTF-8
        disk.dataPartition.size=2G
        fastboot.forceColdBoot=yes
        fastboot.forceFastBoot=no
        hw.accelerometer=yes
        hw.audioInput=yes
        hw.battery=yes
        hw.camera.back=virtualscene
        hw.camera.front=emulated
        hw.cpu.arch=arm64
        hw.cpu.ncore=4
        hw.gps=yes
        hw.gpu.enabled=yes
        hw.gpu.mode=auto
        hw.initialOrientation=portrait
        hw.keyboard=yes
        hw.lcd.density=420
        hw.lcd.height=1920
        hw.lcd.width=1080
        hw.mainKeys=no
        hw.ramSize=2048
        hw.sdCard=no
        image.sysdir.1=system-images/android-30/default/arm64-v8a/
        runtime.network.latency=none
        runtime.network.speed=full
        showDeviceFrame=no
        skin.dynamic=yes
        skin.name=1080x1920
        skin.path=_no_skin
        tag.display=Default
        tag.id=default
        target=android-30
        vm.heapSize=384
        """
        try config.write(to: device.appendingPathComponent("config.ini"), atomically: true, encoding: .utf8)
        let descriptor = """
        avd.ini.encoding=UTF-8
        path=\(device.path)
        path.rel=avd/\(Self.managedDeviceName).avd
        target=android-30
        """
        try descriptor.write(
            to: paths.androidAVDs.appendingPathComponent("\(Self.managedDeviceName).ini"),
            atomically: true,
            encoding: .utf8
        )
    }
}

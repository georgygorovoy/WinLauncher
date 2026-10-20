import Foundation

enum ApplicationPlatform: String, Codable, Hashable {
    case windows
    case android
}

struct LibraryApplication: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var windowsPath: String
    var sourceFileName: String
    var sourcePath: String?
    var lastLaunchedAt: Date?
    var environmentID: String
    var platform: ApplicationPlatform?
    var packageIdentifier: String?

    var effectivePlatform: ApplicationPlatform { platform ?? .windows }

    init(id: UUID = UUID(), name: String, windowsPath: String, sourceFileName: String,
         sourcePath: String? = nil,
         lastLaunchedAt: Date? = nil, environmentID: String = "default",
         platform: ApplicationPlatform = .windows,
         packageIdentifier: String? = nil) {
        self.id = id
        self.name = name
        self.windowsPath = windowsPath
        self.sourceFileName = sourceFileName
        self.sourcePath = sourcePath
        self.lastLaunchedAt = lastLaunchedAt
        self.environmentID = environmentID
        self.platform = platform
        self.packageIdentifier = packageIdentifier
    }
}

struct LibraryDocument: Codable {
    var schemaVersion = 1
    var applications: [LibraryApplication] = []
}

enum AppOperation: Equatable {
    case idle
    case installingEngine
    case installingRuntime
    case preparingEnvironment
    case launching(String)
    case preparingAndroid
    case installingAndroidApp

    var message: String? {
        switch self {
        case .idle: nil
        case .installingEngine: "Installing the Windows engine…"
        case .installingRuntime: "Adding .NET support…"
        case .preparingEnvironment: "Preparing the Windows Environment…"
        case .launching(let name): "Opening \(name)…"
        case .preparingAndroid: "Starting Android…"
        case .installingAndroidApp: "Installing Android app…"
        }
    }
}

struct PresentedFailure: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let logURL: URL?
}

struct CompatibilityHelp: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let sourceURL: URL?
    let recommendedURL: URL?
    let recommendedTitle: String
    let canTryAnyway: Bool
    let logURL: URL?
}

enum WinLauncherError: LocalizedError {
    case engineNotInstalled
    case environmentInitializationFailed(URL)
    case noApprovedEngine
    case invalidEngine
    case engineDownloadFailed(String)
    case engineIntegrityFailed
    case engineInstallationFailed(URL)
    case engineFilesBlocked(URL)
    case applicationFilesMissing
    case compatibilityIssue(String, URL)
    case processFailed(String, Int32, URL)
    case androidSDKNotInstalled
    case androidVirtualDeviceMissing
    case androidEmulatorDidNotStart(URL)
    case androidInstallFailed(URL)
    case androidPackageUnknown(URL)

    var errorDescription: String? {
        switch self {
        case .engineNotInstalled:
            "A Windows engine must be installed before opening an app."
        case .environmentInitializationFailed:
            "The Windows Environment was not created completely. Open the diagnostic log for details."
        case .noApprovedEngine:
            "Wine is not installed. Choose an existing Wine application or executable."
        case .invalidEngine:
            "The selected item does not contain a working Wine engine."
        case .engineDownloadFailed(let reason):
            "Windows Support could not be downloaded. \(reason)"
        case .engineIntegrityFailed:
            "The Windows Support download did not pass its integrity check."
        case .engineInstallationFailed:
            "Windows Support could not be installed completely. Open the diagnostic log for details."
        case .engineFilesBlocked:
            "Windows Support was downloaded and verified, but its runtime files could not be installed completely. Open the diagnostic log for details."
        case .applicationFilesMissing:
            "This game was imported as a single .exe by an older build. Choose the original .exe again so its neighboring game files remain available."
        case .compatibilityIssue(let message, _):
            message
        case .processFailed(let name, let status, _):
            "\(name) stopped with status \(status)."
        case .androidSDKNotInstalled:
            "Android Support is not installed. Install Android Studio with the Android Emulator and an ARM64 virtual device, or choose an existing Android SDK in Settings."
        case .androidVirtualDeviceMissing:
            "No compatible Android virtual device was found. Create an ARM64 phone in Android Studio’s Device Manager, then try again."
        case .androidEmulatorDidNotStart:
            "The Android virtual device did not finish starting. Open the diagnostic log for details."
        case .androidInstallFailed:
            "The APK could not be installed. It may target an unsupported Android version or processor architecture."
        case .androidPackageUnknown:
            "The APK was installed, but its launchable application could not be identified."
        }
    }
}

import Foundation

enum CLIError: LocalizedError, Equatable {
    case usage(String)
    case invalidPath(String)
    case missingFile(String)
    case unsafeEnvironmentPath(String)
    case processFailed(executable: String, status: Int32, log: URL?)

    var errorDescription: String? {
        switch self {
        case .usage(let message), .invalidPath(let message), .missingFile(let message),
             .unsafeEnvironmentPath(let message):
            return message
        case .processFailed(let executable, let status, let log):
            let suffix = log.map { " See \($0.path)." } ?? ""
            return "\(executable) exited with status \(status).\(suffix)"
        }
    }
}

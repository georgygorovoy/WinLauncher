import Foundation

struct ParsedArguments: Equatable {
    let command: String
    private(set) var values: [String: [String]]

    init(_ arguments: [String]) throws {
        guard let command = arguments.first else {
            throw CLIError.usage(Self.help)
        }
        self.command = command
        var values: [String: [String]] = [:]
        var index = 1
        while index < arguments.count {
            let token = arguments[index]
            guard token.hasPrefix("--") else {
                throw CLIError.usage("Unexpected argument: \(token)\n\n\(Self.help)")
            }
            let key = String(token.dropFirst(2))
            guard !key.isEmpty else { throw CLIError.usage(Self.help) }
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                throw CLIError.usage("Missing value for --\(key)")
            }
            values[key, default: []].append(arguments[index + 1])
            index += 2
        }
        self.values = values
    }

    func required(_ name: String) throws -> String {
        guard let value = values[name]?.last else {
            throw CLIError.usage("Missing required option --\(name)")
        }
        return value
    }

    func all(_ name: String) -> [String] { values[name] ?? [] }
    func optional(_ name: String) -> String? { values[name]?.last }

    static let help = """
    WinLauncher compatibility laboratory

      winlab doctor --engine <Wine.app, engine root, or wine executable>
      winlab init --engine <path> --environment <path>
      winlab run --engine <path> --environment <path> --exe <path> [--arg <value>] [--set KEY=VALUE]
      winlab installer --engine <path> --environment <path> --exe <path> [--arg <value>] [--set KEY=VALUE]

    Options may be repeated for --arg and --set. The laboratory never downloads Wine or installers.
    """
}

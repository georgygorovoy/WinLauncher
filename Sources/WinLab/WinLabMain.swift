import Darwin
import Foundation

@main
enum WinLabMain {
    static func main() {
        do {
            let arguments = try ParsedArguments(Array(CommandLine.arguments.dropFirst()))
            let lab = Laboratory()
            switch arguments.command {
            case "help", "--help", "-h":
                print(ParsedArguments.help)
            case "doctor":
                let engine = try lab.doctor(enginePath: arguments.required("engine"))
                print("Wine engine ready: \(engine.version)\n\(engine.executablePath)")
            case "init":
                let configuration = try lab.initialize(enginePath: arguments.required("engine"),
                                                       environmentPath: arguments.required("environment"))
                print("Environment initialized with \(configuration.engine.version).")
            case "run", "installer":
                let manifest = try lab.run(operation: arguments.command,
                                           enginePath: arguments.required("engine"),
                                           environmentPath: arguments.required("environment"),
                                           executablePath: arguments.required("exe"),
                                           arguments: arguments.all("arg"), overrides: arguments.all("set"))
                print("Completed with status \(manifest.exitStatus ?? -1). Run ID: \(manifest.id)")
            default:
                throw CLIError.usage("Unknown command: \(arguments.command)\n\n\(ParsedArguments.help)")
            }
        } catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            exit(2)
        }
    }
}

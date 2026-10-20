import Foundation

enum EnvironmentAssignment: Codable, Equatable {
    case followDefault
    case pinned(UUID)

    func resolve(defaultEnvironmentID: UUID) -> UUID {
        switch self {
        case .followDefault:
            return defaultEnvironmentID
        case .pinned(let environmentID):
            return environmentID
        }
    }
}

struct ApplicationEnvironmentPolicy: Codable, Equatable {
    var defaultEnvironmentID: UUID

    func environmentID(for assignment: EnvironmentAssignment) -> UUID {
        assignment.resolve(defaultEnvironmentID: defaultEnvironmentID)
    }
}

import Foundation

/// Private, versioned payload shared by AppKit history and SwiftUI sidebar drags.
/// The process token rejects external/persisted payloads; checkout identity prevents cross-tab mistakes.
struct GitDragPayload: Codable, Equatable, Sendable {
    static let typeIdentifier = "dev.gitcraft.git-object.v1"
    static let processToken = UUID().uuidString
    let token: String
    let checkout: String
    let headOID: String
    let branch: String
    let oids: [String]
    let sourceRef: String?
    let label: String

    init(checkout: String, headOID: String, branch: String, oids: [String], sourceRef: String? = nil, label: String) {
        token = Self.processToken
        self.checkout = checkout
        self.headOID = headOID
        self.branch = branch
        self.oids = oids
        self.sourceRef = sourceRef
        self.label = label
    }

    var data: Data? { try? JSONEncoder().encode(self) }
    static func decode(_ data: Data) -> Self? {
        guard data.count <= 64_000, let payload = try? JSONDecoder().decode(Self.self, from: data),
              payload.token == processToken, !payload.oids.isEmpty, payload.oids.count <= 100,
              Set(payload.oids).count == payload.oids.count,
              ([payload.headOID] + payload.oids).allSatisfy({ oid in
                  [40, 64].contains(oid.count) && oid.utf8.allSatisfy {
                      (48...57).contains($0) || (97...102).contains($0)
                  }
              }) else { return nil }
        return payload
    }
}

enum GitDropTarget: Equatable {
    case head
    case branch(String)
    case branches
    case tags
    case commit(String)
}

enum GitDropAction: String, CaseIterable {
    case merge = "Merge"
    case rebase = "Rebase"
    case cherryPick = "Cherry-pick"
    case squash = "Squash"
    case fixup = "Fixup"
    case createBranch = "Create branch"
    case createTag = "Create tag"
}

struct GitDropResolution: Equatable {
    let action: GitDropAction?
    let message: String
    var isAllowed: Bool { action != nil }
    var hint: String {
        switch action {
        case .merge: return message + "\nHold ⌥ to rebase instead"
        case .rebase: return message + "\nRelease ⌥ to merge instead"
        case .squash: return message + "\nHold ⌥ to fixup instead"
        case .fixup: return message + "\nRelease ⌥ to squash instead"
        default: return message
        }
    }

    static func resolve(_ payload: GitDragPayload, target: GitDropTarget, checkout: String,
                        branch: String, headOID: String?, unavailable: Bool, option: Bool) -> Self {
        func refuse(_ message: String) -> Self { .init(action: nil, message: message) }
        guard payload.token == GitDragPayload.processToken, payload.checkout == checkout else {
            return refuse("Drop within the original checkout")
        }
        guard !unavailable else { return refuse("Finish the current operation first") }
        guard payload.branch == branch, payload.headOID == headOID else {
            return refuse("The branch changed. Start the drag again.")
        }
        guard !branch.isEmpty else { return refuse("Check out a branch first") }
        switch target {
        case .branches, .tags:
            guard payload.oids.count == 1 else { return refuse("Drag one commit or branch") }
            let action: GitDropAction = target == .branches ? .createBranch : .createTag
            return .init(action: action, message: "\(action.rawValue) at \(payload.label)")
        case let .branch(name) where name != branch:
            return refuse("Switch to this branch first")
        case .head, .branch:
            guard payload.oids.count == 1 else { return refuse("Cherry-pick one commit at a time") }
            if payload.sourceRef != nil {
                guard payload.sourceRef != "refs/heads/\(branch)", payload.oids[0] != headOID else {
                    return refuse("This branch is already at HEAD")
                }
                return option
                    ? .init(action: .rebase, message: "Rebase \(branch) onto \(payload.label)")
                    : .init(action: .merge, message: "Merge \(payload.label) into \(branch)")
            }
            guard payload.oids[0] != headOID else { return refuse("This commit is already HEAD") }
            return .init(action: .cherryPick, message: "Cherry-pick \(payload.label) onto \(branch)")
        case let .commit(oid):
            guard payload.sourceRef == nil else { return refuse("Drag commits here to squash them") }
            guard !payload.oids.contains(oid) else { return refuse("Drop onto an older, unselected commit") }
            return .init(action: option ? .fixup : .squash,
                         message: "\(option ? "Fixup" : "Squash") \(payload.oids.count) commit(s) into \(oid.prefix(7))")
        }
    }
}

struct GitDropPlan: Identifiable {
    let id = UUID()
    let payload: GitDragPayload
    let target: GitDropTarget
    let action: GitDropAction
    let message: String
}

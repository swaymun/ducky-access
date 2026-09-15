import Foundation

enum CommandPermissionProfile: String, CaseIterable {
    case askBeforeActions = "Ask before actions"
    case fullAccess = "Full Access"

    static let defaultsKey = "commandPermissionProfile"
    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .askBeforeActions
    }
    var codexPermission: String { self == .fullAccess ? ":danger-full-access" : ":read-only" }
    var showsApprovalPrompts: Bool { self == .askBeforeActions }
}

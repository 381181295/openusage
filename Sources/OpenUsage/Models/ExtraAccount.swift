import Foundation

/// An additional provider account beyond the default one the CLI is logged into. Each becomes its
/// own provider instance, pointed at its own config dir (`CLAUDE_CONFIG_DIR` / `CODEX_HOME`).
struct ExtraAccount: Codable, Identifiable, Hashable, Sendable {
    var provider: String
    var slot: String
    var label: String
    /// Absolute path to the account's CLI config dir (holds its credentials).
    var configDir: String

    var id: String { instanceID }

    var instanceID: String { "\(provider)@\(slot)" }
}

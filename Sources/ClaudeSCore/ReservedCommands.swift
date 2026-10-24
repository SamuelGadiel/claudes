/// First argument of "cs" that is always treated as a command, never as an
/// account slug. `cs add` rejects registering an account with any of these names.
public enum ReservedCommands {
    public static let names: Set<String> = [
        "list", "add", "import", "remove", "set", "default", "status", "usage", "help", "-h", "--help",
        "-v", "--version",
        // Not a CLI command — reserved because it would collide with
        // SharedSessionsDirectory's own folder name (~/.claude-shared-chats).
        SharedSessionsDirectory.reservedSlug,
    ]
}

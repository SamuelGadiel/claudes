/// First argument of "cs" that is always treated as a command, never as an
/// account slug. `cs add` rejects registering an account with any of these names.
public enum ReservedCommands {
    public static let names: Set<String> = [
        "list", "add", "remove", "set", "default", "install-cli", "status", "usage", "help", "-h", "--help",
        "-v", "--version",
    ]
}

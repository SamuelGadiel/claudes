/// Primeiro argumento de "cs" que sempre é tratado como comando, nunca como
/// slug de conta. `cs add` rejeita registrar uma conta com um desses nomes.
public enum ReservedCommands {
    public static let names: Set<String> = [
        "list", "add", "remove", "set", "default", "install-cli", "status", "usage", "help", "-h", "--help",
        "-v", "--version",
    ]
}

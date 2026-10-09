import Foundation

/// Resolve qual conta usar para o diretório atual: .clauderc (subindo
/// diretórios) -> conta default -> nil (comportamento nativo, sem
/// CLAUDE_CONFIG_DIR). nil só deve ocorrer antes da primeira conta existir.
public enum AccountResolver {
    public static func resolve(forCwd cwd: String, in file: AccountsFile) -> RegisteredAccount? {
        if let found = ClauderFile.find(startingAt: cwd),
           let account = AccountsConfig.find(identifier: found.account, in: file) {
            return account
        }
        return AccountsConfig.defaultAccount(in: file)
    }
}

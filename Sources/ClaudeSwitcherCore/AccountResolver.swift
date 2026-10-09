import Foundation

/// Resolves which account to use for the current directory: .clauderc (walking
/// up directories) -> default account -> nil (native behavior, without
/// CLAUDE_CONFIG_DIR). nil should only occur before the first account exists.
public enum AccountResolver {
    public static func resolve(forCwd cwd: String, in file: AccountsFile) -> RegisteredAccount? {
        if let found = ClauderFile.find(startingAt: cwd),
           let account = AccountsConfig.find(identifier: found.account, in: file) {
            return account
        }
        return AccountsConfig.defaultAccount(in: file)
    }
}

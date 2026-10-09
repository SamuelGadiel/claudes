import Foundation

/// Reproduz o nome de diretório que o Claude Code usa em
/// <CLAUDE_CONFIG_DIR>/projects/<dirName>/ para um dado path de projeto.
/// Confirmado empiricamente contra 10 projetos reais nesta máquina
/// (plans/specs/04-sincronizacao-sessoes): não é hash — é o path absoluto
/// com cada "/" substituído por "-". Não resolve symlinks (evidência: os
/// nomes observados batem com o path direto, não com um realpath via
/// /private/var ou /System/Volumes/Data).
enum ProjectHash {
    static func projectDirName(forPath path: String) -> String {
        var expanded = (path as NSString).expandingTildeInPath
        if expanded.count > 1, expanded.hasSuffix("/") {
            expanded.removeLast()
        }
        return expanded.replacingOccurrences(of: "/", with: "-")
    }
}

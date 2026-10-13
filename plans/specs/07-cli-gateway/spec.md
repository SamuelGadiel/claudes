# Spec: CLI `cs` como gateway de terminal

Resolve: expansão de escopo pedida na sessão — substituir os aliases manuais
(`claude`/`claudew`) por um único binário que decide a conta, inspirado
diretamente no padrão do `fvm` (Flutter Version Management).

## Mapeamento com o fvm (confirmado investigando `fvm --help` e um `.fvmrc` real)

| `cs` | equivalente `fvm` |
|---|---|
| `cs list` | `fvm list` |
| `cs add --name <nome> [--dir] [--slug] [--default]` | `fvm install` |
| `cs remove <slug>` | `fvm remove` |
| `cs set <slug>` (na raiz do projeto) | `fvm use <version>` |
| `cs default <slug>` | `fvm global <version>` |
| `cs <slug> [args...]` | `fvm flutter [args...]` — gateway puro |
| `cs` (sozinho) | resolve projeto → default → nativo |
| `.clauderc` com `{"account": "<slug>"}` | `.fvmrc` com `{"flutter": "<versão>"}` |

## Decisão central: `.clauderc` grava o nome lógico, não o path

Diferente do `.vscode/settings.json` (spec 02), que precisa do path absoluto
porque é a extensão oficial da Anthropic quem lê — e por isso é sempre
local/`.gitignore` — o `.clauderc` grava só o **slug** da conta
(`{"account": "work"}`). Isso é seguro de commitar: cada pessoa do time
resolve "work" para o próprio `accounts.json` local. `cs set` escreve os
dois arquivos: `.clauderc` (fonte de verdade portátil) e
`.vscode/settings.json` (projeção derivada, só para a extensão funcionar).

## Resolução de conta (ordem)

1. `.clauderc` do diretório atual, **subindo diretórios** até achar um (igual
   à resolução do `.git`, implementado em `ClauderFile.find`).
2. Conta marcada como default em `accounts.json` (`defaultAccountSlug`).
3. Nenhum `CLAUDE_CONFIG_DIR` setado (comportamento nativo, igual a rodar
   `claude` sem a ferramenta) — só ocorre antes de existir qualquer conta
   registrada.

**Decisão do usuário**: a partir da primeira conta criada, deve *sempre*
existir uma default. A primeira conta cadastrada por `cs add` é promovida a
default automaticamente; `cs add --default` permite escolher outra na
criação; `cs remove` da conta default promove a próxima automaticamente (se
houver alguma restante).

## Modelo de dados

`RegisteredAccount` ganhou um campo `slug` (identificador técnico, estável,
sem espaço/acento/caixa — usado em `cs <slug>`, `cs set`, `cs remove`),
diferente de `name` (só exibição). `accounts.json` passou de array simples
para `AccountsFile { accounts: [...], defaultAccountSlug: String? }`.
Migração automática do formato antigo implementada em `AccountsConfig.load()`
(gera slug a partir do nome, promove a primeira conta a default).

## Slug

`Slug.make(from:)`: dobra acentos (`folding(.diacriticInsensitive)`), baixa
caixa, substitui qualquer sequência de não-alfanuméricos por um único `-`,
sem `-` nas pontas. Testado com "Cliente Teste Ã" → `cliente-teste-a`.

## Palavras reservadas

`list`, `add`, `remove`, `set`, `default`, `help`, `-h`, `--help`, `-v`,
`--version` não podem ser slug de conta (validado em `cs add`) — evita
colisão entre o namespace de comandos e o namespace de contas no gateway
`cs <primeiro-argumento>`.

## Gateway de processo

`ClaudeGateway` resolve o binário `claude` real via `/usr/bin/env` (nunca
hardcoded, nunca via alias de shell — `Process` não herda aliases de
qualquer forma). stdio herdado diretamente (sem `Pipe`) para preservar o TTY
e o modo interativo do Claude Code. Exit code sempre propagado.

**Validado end-to-end**: `cs trabalho auth status` retorna o e-mail da conta
de trabalho (`samuel.gadiel@branef.com.br`), `cs pessoal auth status` retorna
o e-mail pessoal — confirma que `CLAUDE_CONFIG_DIR` chega corretamente ao
processo real do Claude Code em ambos os casos. `cs auth login` é repasse
puro para o comando nativo `claude auth login` (confirmado via
`claude auth --help`) — não implementamos nenhuma lógica de autenticação.

## Fluxo de `cs add`

1. Valida nome/slug (não vazio, não reservado, não duplicado).
2. Resolve `configDir` (`--dir` explícito ou `~/.claude-<slug>` por padrão).
3. Cria o diretório (`mkdir -p`) — não cria estrutura interna, isso é tarefa
   do próprio Claude Code na primeira execução.
4. Registra em `accounts.json`; promove a default se for a primeira conta
   ou se `--default` foi passado.
5. Pergunta interativamente se quer logar agora; se sim, roda
   `claude auth login` de verdade com `CLAUDE_CONFIG_DIR` da conta nova
   (stdio herdado — o usuário vê o fluxo de login real, incluindo
   abertura de browser se for o caso).

## Edge cases testados

- Nome com acento/espaço → slug normalizado corretamente.
- `cs remove` da conta default → promove a próxima automaticamente.
- `.clauderc` resolvido a partir de uma subpasta do projeto (sobe até achar).
- Conta registrada sem credencial no Keychain ainda → `cs list` mostra
  "nenhuma credencial encontrada" em vez de quebrar.
- `claude auth status` sem login retorna `loggedIn: false` e exit code != 0
  — propagado corretamente pelo gateway (não é um bug nosso).

## Arquitetura do Swift Package (preparando para o app de status bar)

O pacote agora tem dois targets: `ClaudeSCore` (library — toda a
lógica: Keychain, contas, `.clauderc`, settings.json, sync, gateway,
instalação) e `cs` (executável — só parsing de argumentos + prints). O
futuro app de status bar (spec 05) vai ser um terceiro target que depende da
mesma `ClaudeSCore`, sem duplicar nada. O Core nunca imprime direto
(`AccountsConfig.load()` retorna `(file, messages)` em vez de fazer
`print()`) — quem decide como exibir é sempre o consumidor (CLI hoje, GUI
depois).

**Importante por design**: `cs` nunca depende do app de status bar estar
rodando. Não há IPC entre os dois — ambos leem `accounts.json` e o Keychain
diretamente. Qualquer IPC futuro (ex.: o app notificar algo quando `cs` troca
de conta) deve ser best-effort e opcional, nunca bloqueante.

## Instalação no PATH (`ShellInstall` / `cs install-cli`)

Cria (ou atualiza) um link simbólico para o binário `cs` em execução dentro
de um diretório já no PATH — mesmo padrão do "Install 'code' command in
PATH" do VS Code. Resolve o caminho do executável **em runtime**
(`CommandLine.arguments[0]`, resolvendo symlinks), nunca hardcoded — por
isso funciona idêntico hoje (`swift run`/`.build/debug/cs`) e depois, quando
`cs` estiver embutido num `.app` (`~/Applications/ClaudeS.app/...` ou
`/Applications/...`).

Ordem de diretórios tentados: `/usr/local/bin` primeiro (convenção histórica
do macOS), `~/.local/bin` como fallback sem sudo. **Validado nesta
máquina**: `/usr/local/bin` não era gravável sem sudo (permissão negada),
caiu automaticamente para `~/.local/bin` (que já estava no PATH real do
usuário) e funcionou — `~/.local/bin/cs list`/`cs pessoal --version`
confirmados funcionando como se já estivesse instalado.

Plano para a distribuição via `.app` (spec 05, ainda não implementado):
1. `cs` compilado em modo release e embutido no bundle, em
   `Contents/Resources/bin/cs`.
2. Na primeira abertura do app, ele chama a mesma lógica de
   `ShellInstall.install()` (ela já é testável e reusável — não precisa ser
   reescrita para a GUI).
3. Se nenhum diretório candidato for gravável, a GUI mostra a instrução
   manual (mesma mensagem que o CLI já imprime) em vez de falhar silenciosa.

## Fora de escopo (por enquanto)

- Empacotar de fato o `.app` (bundle, ícone, assinatura/notarização,
  distribuição via GitHub Releases) — isso é a spec 05.
- Repassar sinais (Ctrl+C) foi observado funcionar por padrão (mesmo grupo
  de processo do terminal), mas não foi testado exaustivamente com sessões
  longas/`--bg`.

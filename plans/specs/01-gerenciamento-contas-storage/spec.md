# Spec: Gerenciamento de contas e storage

Resolve: P1 (múltiplas contas), P5 (adicionar conta sem fricção), P9 (expiração)

## Objetivo

Descobrir quais contas Claude Code existem na máquina, ler seus metadados de
expiração sem fazer nenhuma chamada de rede, e permitir registrar uma conta
nova sem editar aliases/scripts manualmente.

## O que já sabemos (validado nesta máquina)

- Cada conta corresponde a um `CLAUDE_CONFIG_DIR` (ex.: `~/.claude`, `~/.claudew`).
- A credencial fica no Keychain do macOS, classe `genp` (generic password),
  serviço `Claude Code-credentials` — e variantes com sufixo hash
  (`Claude Code-credentials-<hash>`), uma por `CLAUDE_CONFIG_DIR` não-default.
- O conteúdo do item é um JSON com `claudeAiOauth.{accessToken,refreshToken,
  expiresAt,refreshTokenExpiresAt,subscriptionType,rateLimitTier}` e também
  tokens de MCP OAuth de plugins (Atlassian, Figma etc.) — **não tocar nesses
  campos**, são de outros produtos.
- `expiresAt`/`refreshTokenExpiresAt` são epoch millisseconds.

## Regra do sufixo de Keychain — confirmada

`sha256(<path absoluto do CLAUDE_CONFIG_DIR>)`, primeiros 8 caracteres hex.
Validado nesta máquina: `/Users/samuelgadiel/.claude` → `c2f365e1`,
`/Users/samuelgadiel/.claudew` → `f7d651a4`. Serviço de Keychain = `"Claude
Code-credentials"` sem sufixo quando `CLAUDE_CONFIG_DIR` é o default
(`~/.claude`), ou `"Claude Code-credentials-<hash8>"` para qualquer outro
diretório.

Observação: havia um terceiro sufixo (`cc6319df`) nesta máquina que não
corresponde a nenhum `CLAUDE_CONFIG_DIR` conhecido — provável resíduo de um
diretório de teste usado no passado. Não precisa de ação; a descoberta de
contas (R1) só considera `CLAUDE_CONFIG_DIR`s que o usuário registrou
explicitamente, então um sufixo órfão simplesmente não aparece na lista.

## Requisitos funcionais

1. Listar `CLAUDE_CONFIG_DIR`s conhecidos: default (`~/.claude`) + qualquer
   diretório que o usuário tenha registrado explicitamente na nossa config
   (ver R3). Não tentar "adivinhar" outros diretórios por varredura do disco.
2. Para cada `CLAUDE_CONFIG_DIR`, localizar o item de Keychain correspondente
   e extrair `expiresAt`/`refreshTokenExpiresAt`/`subscriptionType` — sem
   nunca persistir `accessToken`/`refreshToken` fora do Keychain.
3. Permitir ao usuário "adicionar conta": o app pede um nome amigável (ex.:
   "Trabalho") e um `CLAUDE_CONFIG_DIR` (sugerindo um novo path tipo
   `~/.claude-<nome>` se vazio). Não há fluxo de login — o usuário faz login
   manualmente com `CLAUDE_CONFIG_DIR=<path> claude` uma vez; nosso app só
   passa a monitorar esse diretório depois.
4. Persistir a lista de contas registradas (nome amigável ↔ `CLAUDE_CONFIG_DIR`)
   num arquivo de config do próprio app (ex. `~/Library/Application
   Support/ClaudeSwitcher/accounts.json`), nunca em texto plano com segredo.

## Leitura de Keychain — como

Usar `Security.framework` (via Swift, `SecItemCopyMatching`) filtrando por
`kSecAttrService`. A primeira leitura de cada item vai disparar o prompt
nativo do macOS pedindo permissão ("ClaudeSwitcher quer acessar... "); é
esperado e deve ser comunicado ao usuário na primeira execução.

## Edge cases

- Item de Keychain não encontrado para um `CLAUDE_CONFIG_DIR` registrado →
  estado "nunca logado / credencial removida", mostrar isso na UI, não travar.
- `expiresAt` (access token) no passado é **normal e não deve gerar alerta** —
  o Claude Code renova o access token automaticamente via `refreshToken` em
  segundo plano (confirmado: nesta máquina a conta Pessoal está com access
  token expirado e funcionando normalmente). O alerta de expiração real
  (consumido por `specs/05-app-status-bar`, P9) deve observar
  `refreshTokenExpiresAt` — é esse que força novo login manual quando passa.
- Dois `CLAUDE_CONFIG_DIR`s apontando pro mesmo hash de Keychain (colisão) →
  log de aviso; não deve acontecer na prática mas não presumir unicidade sem checar.

## Fora de escopo

- Validar o accessToken contra a API da Anthropic (isso é rede — ver P9 "popup
  de expiração" que pode ser só client-side via `expiresAt`, sem round-trip).

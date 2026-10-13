# claudes (ClaudeS) — Visão Geral

## Problema

Uso de múltiplas contas Claude (pessoal + trabalho) no VS Code hoje depende de:
perfis duplicados do VS Code, extensão de terceiro para corrigir isolamento de
credenciais, processo manual pra mover chat entre contas, e nenhuma visibilidade
de uso/expiração. Ver histórico da conversa para o levantamento completo (13 pontos).

## O que este projeto é (estado atual do MVP)

Uma camada de **gerenciamento** sobre contas Claude Code já logadas:

- Descobre contas existentes (diretórios `CLAUDE_CONFIG_DIR` + credenciais no Keychain).
- Decide, por projeto aberto no VS Code, qual conta ele usa — sem precisar de profiles.
- Corrige o bug da extensão oficial da Anthropic que ignora `CLAUDE_CONFIG_DIR`
  fora do processo de launch.
- Chats compartilhados entre contas via diretório único symlinkado (`~/.claude-shared-chats`)
  — não é mais "sync on switch" (cópia pontual), ver `specs/04-sincronizacao-sessoes`.
- Mostra uso e expiração de cada conta num ícone de status bar do macOS, com
  troca de conta por projeto a partir dali, e notifica (expiração de login,
  threshold de uso, renovação de cota) mesmo com o painel fechado.

## O que este projeto NÃO é (hoje)

- Não faz login nem gerencia OAuth. Só lê o que o Claude Code já gravou.
- Não substitui o Claude Code CLI/extensão — opera ao lado deles.
- Não é multi-plataforma nesta fase (macOS only, SwiftUI nativo).

## Visão de longo prazo — por que o nome é "ClaudeS", não "Claude VS Code Switcher"

O escopo do MVP é deliberadamente estreito (macOS + VS Code), mas a visão do
projeto não é. Objetivo declarado: **em qualquer lugar que o Claude atue, este
projeto deve poder atuar também** — o "S" de "ClaudeS" carrega tanto "plural"
(múltiplas contas) quanto "mais do que só isso" (o ecossistema Claude como um
todo, não só uma IDE).

Direções futuras já levantadas (não compromissadas, não no MVP):

- **Outros pontos de integração além da extensão VS Code**: Claude Desktop
  (app Electron oficial — `kevinchau/claude-switcher`, ver Kanban, é referência
  de como outro projeto já ataca esse domínio especificamente), extensão de
  navegador para claude.ai, qualquer outra IDE que ganhe uma extensão oficial
  Claude no futuro.
- **Mais métricas, extraídas do que já coletamos**: custo de API (tokens
  gastos) por projeto e por conta, volume de chats por projeto/conta, e outras
  métricas derivadas dos dados de uso que o monitoramento já lê.
- **Previsão/forecast de uso**: taxa de consumo atual projetada para estimar
  quando uma janela vai esgotar — não só o threshold reativo (75%/90%) que já
  existe, mas um alerta proativo ("nesse ritmo, acaba em X", "abra outra
  sessão/conta agora"). Inspirado no sistema de forecast do
  `kevinchau/claude-switcher` (ver Kanban), mas adaptado ao nosso modelo.
- **Widgets nativos de macOS** mostrando uso sem abrir o painel.

Isso molda decisões de nome/ícone/identidade visual desde já (não esperar o
ecossistema crescer para só então ajustar a marca), mas não força nenhuma
decisão de arquitetura prematura — cada direção acima vira trabalho real só
quando entrar no backlog com detalhe.

## Decisões arquiteturais tomadas

| Decisão | Escolha | Por quê |
|---|---|---|
| Stack do app | Swift/SwiftUI nativo (menu bar `NSStatusItem`) | Acesso nativo a Keychain/Accessibility/AppleScript, sem runtime pesado residente |
| Perfis do VS Code | Eliminados. `CLAUDE_CONFIG_DIR` setado via `.vscode/settings.json` por projeto | Um único perfil, sem duplicar extensões instaladas |
| Patch da extensão oficial | Vendorizar `patch-core.js` + `patch-regexes.js` do projeto `leog/claude-code-config-dir-patcher-vscode` (MIT) e executá-los via `JavaScriptCore` nativo do macOS | Reaproveita a lógica (mantida ativamente pelo autor) sem reimplementar regex frágil nem depender de Node instalado |
| Sincronização de chats | "Sync on switch": copia `projects/<hash-do-path>/*.jsonl` da conta origem pra destino, só do projeto que está trocando | Symlink global foi descartado — risco de concorrência entre contas e perda de granularidade por projeto |
| Detecção de expiração | Leitura direta do Keychain (`Claude Code-credentials*`), campo `expiresAt`/`refreshTokenExpiresAt` em epoch ms | Não depende de nenhuma chamada de rede |
| Uso (quota) por conta | Em aberto — não há API de usage confirmada ainda. Ver `specs/06-monitoramento-uso-expiracao` | Evitar achismo: precisa validação antes de desenhar a UI de abas |

## Riscos transversais conhecidos

- **Fragilidade do patch**: a extensão oficial da Anthropic pode mudar o bundle
  minificado e quebrar os regexes vendorizados. Mitigação: script de verificação
  (adaptado do `check-upstream-patchability.mjs` do leog) roda antes de aplicar.
- **`.vscode/settings.json` versionado**: se o projeto for compartilhado em time,
  não podemos escrever `CLAUDE_CONFIG_DIR` (path local da máquina do usuário) num
  arquivo commitado. Ver `specs/02-integracao-vscode-sem-profiles`.
- **Segredos no Keychain**: qualquer leitura de credencial deve ficar em memória
  o mínimo possível e nunca ser logada/persistida fora do Keychain.

## Fases (grosso modo, refinar no kanban)

1. Fundação: descoberta de contas + leitura de expiração via Keychain.
2. Integração VS Code: escrita de `.vscode/settings.json` + patch vendorizado.
3. App de status bar: listar contas, listar janelas VS Code abertas, trocar conta por projeto.
4. Sincronização de sessões (sync on switch).
5. Monitoramento de uso (depende de validação de API) + popup de expiração.

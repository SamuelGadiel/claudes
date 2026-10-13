# Spec: App de status bar (macOS)

Resolve: P6, P7, P8, P9, P10

## Objetivo

Um único ícone na status bar do macOS. Clique esquerdo abre um painel
customizado (SwiftUI, não um `NSMenu` nativo — necessário para caber barras
de progresso e abas, que um menu nativo não suporta). Clique direito abre um
`NSMenu` clássico (atualizações, sobre, sair).

## Implementado e validado: scaffold funcional

`StatusBarController` (AppKit): `NSStatusItem` com clique esquerdo abrindo
`NSPopover` (conteúdo via `NSHostingController<PanelView>`, SwiftUI) e
clique direito atribuindo temporariamente `statusItem.menu` para abrir um
`NSMenu` clássico (o menu é removido logo depois — mantê-lo fixo faria todo
clique, incluindo o esquerdo, abrir o NSMenu em vez do popover). Validado
rodando de verdade: painel mostra projetos abertos e contas reais, menu
clássico abre com Verificar atualizações/Sobre/Sair funcionando.

**Nota de processo, não de produto**: durante o desenvolvimento, processos
GUI lançados a partir do ambiente de execução do assistente (este, via
terminal controlado por automação) ficam com o `NSStatusItem` posicionado
fora de qualquer tela (`X=-4036`, confirmado via `CGWindowListCopyWindowInfo`
— reproduzido de forma idêntica trocando nome/identificador do bundle,
descartando cache específico do app). Rodando o mesmo binário a partir de um
terminal aberto manualmente pelo usuário, funciona normalmente. Implicação
prática: validação visual da UI depende do usuário rodar e reportar — não
dá para confiar em screenshot tirado a partir deste ambiente para esse app
específico.

## Decisão: lista de projetos abertos, sem detectar "qual está em foco"

Avaliamos e descartamos tentar identificar automaticamente qual janela do
VS Code está em foco. Dois motivos, nessa ordem de peso:

1. **Frágil por design**: o título da janela do VS Code é customizável pelo
   próprio usuário (`window.title` nas settings) — não é uma string estável
   para basear lógica em cima.
2. Para resolver ambiguidade de geometria entre janelas maximizadas
   (confirmado empiricamente: duas janelas do VS Code maximizadas têm
   bounds idênticos via `CGWindowList`), seria necessário pedir permissão
   de Acessibilidade — fricção que o usuário preferiu evitar.

Em vez disso: o painel lista **todos os projetos abertos agora**, lidos de
`~/Library/Application Support/Code/User/globalStorage/storage.json`
(`windowsState.openedWindows[].folder`, uma `file://` URI com o **path
completo** — nenhuma permissão especial necessária para ler esse arquivo).
A lista é dinâmica: abrir/fechar uma janela do VS Code atualiza a lista na
próxima vez que o painel for aberto (ou via watch do arquivo, se quisermos
atualização em tempo real — ver "Fora de escopo"). Sem ambiguidade de nomes:
cada entrada já vem com o path absoluto, não dependemos de nome de pasta.

Cada linha da lista tem: nome da pasta (último componente do path), a conta
atualmente associada a ela, e uma forma de trocar (dispara o mesmo fluxo de
`cs set` — grava `.clauderc` + `.vscode/settings.json`, specs 02/07).

## Segunda seção: sessões `claude` rodando em terminal

Além dos projetos abertos no VS Code, o painel lista processos `claude`
rodando fora de qualquer IDE — detecção validada em `specs/06` via
`sysctl`/`KERN_PROCARGS2` (lê o `CLAUDE_CONFIG_DIR` real do ambiente do
processo, não uma inferência) + `proc_pidinfo`/`PROC_PIDVNODEPATHINFO`
(cwd real). Filtra processos da extensão VS Code pelos flags que só ela
passa (`--output-format stream-json` etc.), para não duplicar com a seção
de projetos.

**Limitação importante a comunicar na UI**: não é possível trocar a conta
de uma sessão **já em execução** — variáveis de ambiente de um processo
rodando são fixas desde que ele iniciou, não há API para alterá-las de
fora. "Trocar" aqui significa atualizar o `.clauderc` daquele diretório
(mesmo mecanismo de `cs set`), valendo a partir da próxima vez que
`claude`/`cs` for rodado ali — a sessão atual continua com a conta antiga
até ser reiniciada. A UI deve deixar isso claro (ex.: "válido na próxima
execução"), não sugerir efeito imediato.

## Arquitetura técnica

- `NSStatusItem` com um botão que distingue clique esquerdo de clique
  direito (`NSStatusBarButton` + checagem do tipo de evento, ou
  `NSEvent.modifierFlags`/`rightMouseDown` — AppKit puro, não dá para usar
  `MenuBarExtra` do SwiftUI aqui porque ele não separa clique esquerdo de
  direito de forma simples).
- Clique esquerdo → `NSPopover` cujo `contentViewController` é um
  `NSHostingController` hospedando a view SwiftUI do painel (permite usar
  `TabView`, `ProgressView` etc. com toda a liberdade do SwiftUI).
- Clique direito → `NSMenu` clássico de verdade (`statusItem.menu`),
  populado com os itens básicos (ver abaixo).
- Toda a lógica de dados vem de `ClaudeSCore` (mesmo Core do `cs`) —
  este target só monta UI em cima dela, igual o `cs` só faz parsing/print
  em cima dela. Nenhuma duplicação de lógica de negócio.

## Layout do painel (clique esquerdo)

```
Projetos abertos (VS Code)
  claudes                      Pessoal   [trocar ▾]
  sivisamais_mobile_agente     Trabalho  [trocar ▾]
―――――――――――――――――――――――――――
Sessões de terminal
  ~/dev/outro-projeto          Trabalho  [trocar ▾ — vale na próxima execução]
―――――――――――――――――――――――――――
[ Pessoal ]  [ Trabalho ]          ← abas
   5h:     ███████░░░ 68%  reseta em 2h40
   Semana: ████░░░░░░ 41%  reseta sex 09:00
   (Extra: ██░░░░░░░░ 15%)         ← só se a conta tiver crédito extra ativo
```

Dados de uso vêm de `specs/06-monitoramento-uso-expiracao` (já resolvida:
endpoint real `GET /api/oauth/usage`, não é mais bloqueio).

## Menu clássico (clique direito)

Verificar atualizações · Sobre o ClaudeS · Sair.

## Modelo de dados

- Conta: `RegisteredAccount` + `AccountStatus` (spec 01), já existentes no
  Core, reusados sem alteração.
- Projeto aberto: `{ path, nome da pasta }`, lido do `storage.json` do VS
  Code — não persistimos isso, é lido fresco a cada abertura do painel.
- Associação projeto↔conta: fonte de verdade é `.clauderc` (spec 07), nunca
  duplicada em config própria do app — evita os dois ficarem
  dessincronizados. `.vscode/settings.json` é escrito como projeção
  derivada no mesmo gesto (mesma função `VSCodeSettings.setConfigDir` que o
  `cs set` já usa).

## Trocar de conta no painel — efeito real

Mesmo fluxo do `cs set`: grava `.clauderc`, atualiza `.vscode/settings.json`
via merge seguro, e (quando a spec 03 — patch do leog — estiver
implementada) garante que a extensão oficial reconheça a mudança. Pergunta
antes se quer sincronizar o histórico daquele projeto (spec 04) da conta
atual para a nova.

## Notificação de expiração

`UserNotifications` (framework nativo) quando `refreshTokenExpiresAt`
(nunca `expiresAt` — ver spec 01) de uma conta estiver próximo ou passado.
Checagem periódica lendo o Keychain (custo de IO desprezível, mesmo
mecanismo de `AccountDiscovery.status`).

## Instalação do `cs` na primeira abertura

Na primeira abertura do app, chama `ShellInstall.install()` (spec 07) para
deixar o comando `cs` disponível no terminal, sem o usuário precisar rodar
nada manualmente. Mostra o resultado (link criado, ou instrução manual se
nenhum diretório candidato for gravável).

## Edge cases

- Nenhuma conta registrada ainda → estado vazio orientando a usar `cs add`
  ou um fluxo equivalente na própria GUI (a decidir: GUI replica `cs add`,
  ou só orienta a rodar o comando — ver próxima rodada de design).
- VS Code não está rodando / `storage.json` não existe → lista de projetos
  vazia, sem erro.
- Projeto aberto sem `.clauderc` ainda → mostra "conta não definida",
  oferece definir uma (ou cai na default, igual o `cs` faz).

## Fora de escopo nesta spec (por enquanto)

- Atualização em tempo real da lista de projetos via file-watch do
  `storage.json` (começar só com "lê fresco ao abrir o painel").
- Fluxo de `add`/`remove` de conta pela própria GUI (replicar o que `cs`
  já faz por linha de comando) — decidir se entra já ou fica para depois.
- Lógica de patch (spec 03) e sincronização de sessão (spec 04) — este app
  só os invoca.
- Janela "cheia" de gerenciamento (fora do painel do ícone) — usuário já
  confirmou não ser prioridade agora.
- Empacotamento do `.app` de distribuição (ícone, assinatura, notarização,
  GitHub Releases) — ver `specs/07-cli-gateway`.

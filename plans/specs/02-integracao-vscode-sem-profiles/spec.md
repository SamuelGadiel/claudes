# Spec: Integração com VS Code sem profiles

Resolve: P2, P12 (um único perfil do VS Code), P7 (trocar conta de um projeto)

## Objetivo

Eliminar a necessidade de perfis duplicados do VS Code. A conta usada num
projeto é decidida por `.vscode/settings.json` daquele projeto, escrito e
mantido pelo nosso app — não pelo usuário manualmente.

## Design

- Chave usada: `claudeCode.environmentVariables`, no formato que a extensão
  oficial já aceita:
  ```json
  "claudeCode.environmentVariables": [
    { "name": "CLAUDE_CONFIG_DIR", "value": "/Users/samuelgadiel/.claudew" }
  ]
  ```
- Nosso app **faz merge**, nunca overwrite: lê o `settings.json` existente,
  atualiza/insere apenas a entrada `CLAUDE_CONFIG_DIR` dentro do array
  `claudeCode.environmentVariables`, preservando qualquer outra config do
  usuário e quaisquer outras variáveis de ambiente que já estejam lá.
- Trocar de conta num projeto = reescrever esse valor. **Validado lendo o
  `extension.js` da extensão oficial (2.1.281, não via teste visual):**
  reload **não é necessário** no caminho normal. A extensão registra
  `watchEnvironmentVariablesSetting()`, que escuta
  `workspace.onDidChangeConfiguration` especificamente para
  `claudeCode.environmentVariables` e, ao detectar mudança, chama
  `refreshEveryHost` — invalida cache de config, dá refresh em cada webview
  aberto e em cada sessão ativa. O VS Code dispara esse evento sozinho ao
  detectar a escrita em `.vscode/settings.json`, sem precisar de foco na
  janela. (Existe uma ressalva só para o watcher de ARQUIVO do
  `CLAUDE_CONFIG_DIR` em si — detectar login/logout feito fora da janela
  dentro do mesmo config dir — que cai para "só após reload" se o fs.watch
  falhar; não é o nosso caso, que muda o próprio valor do setting.)

## Risco crítico: `.vscode/settings.json` versionado em projetos de time

`CLAUDE_CONFIG_DIR` é um path local da máquina do usuário. Se esse arquivo for
commitado (comum em monorepos de empresa), vazamos a estrutura de diretórios
de uma máquina para o time e, pior, forçamos a configuração de conta de uma
pessoa em todas as outras que abrirem o projeto.

Opções (precisam de decisão, não assumir qual usar — perguntar quando chegar
nesse ponto de implementação):

1. **Detectar se `.vscode/settings.json` está versionado** (`git check-ignore`)
   antes de escrever. Se estiver, usar `.vscode/settings.json` mesmo assim
   mas alertar o usuário, ou preferir uma alternativa.
2. **VS Code multi-root workspace file** (`*.code-workspace`) fora do
   controle de versão, com a config de ambiente no nível do workspace.
3. **Settings de nível de pasta não versionada** — verificar se existe
   suporte do VS Code a algo equivalente a ".env.local" para settings (não
   há nativamente; precisaria ser `.vscode/settings.json` em `.git/info/exclude`
   local, o que é frágil porque não viaja com o repo).

Recomendação a validar com o usuário antes de implementar: checar primeiro se
o projeto tem `.vscode/` no `.gitignore`; se sim, usar normalmente; se não,
perguntar ao usuário antes de escrever (não decidir silenciosamente).

## Requisitos funcionais

1. Dado um path de projeto + um `CLAUDE_CONFIG_DIR` alvo, escrever/atualizar
   `.vscode/settings.json` fazendo merge seguro (parse JSON, não regex).
2. Antes de escrever, checar se `.vscode/settings.json` (ou `.vscode/`) está
   sob controle de versão e sinalizar conforme risco acima.
3. Ler o estado atual (qual conta um projeto está usando) direto do
   `settings.json`, sem precisar de outra fonte de verdade duplicada.

## Atualização: `.vscode/settings.json` agora é "projeção derivada"

Desde a spec 07 (CLI `cs`), a fonte de verdade de "qual conta este projeto
usa" passou a ser `.clauderc` (grava o **slug** da conta, não o path — por
isso é seguro commitar). `.vscode/settings.json` continua existindo e sendo
escrito por `cs set` (via `VSCodeSettings.setConfigDir`), mas só porque a
extensão oficial da Anthropic exige isso — ele é sempre local, sempre
`.gitignore`, nunca a fonte de verdade. O risco de versionamento descrito
abaixo continua válido para ele especificamente.

## Atualização: por que isso não bastava sozinho (e o que faltava)

Escrever `claudeCode.environmentVariables` em `.vscode/settings.json` nunca
teve efeito real: esse setting é declarado com `"scope": "machine"` no
`package.json` da extensão oficial, e settings desse scope só podem ser
definidos em *user*/*remote* settings — o VS Code ignora silenciosamente
qualquer valor em workspace settings. Ver `specs/03-patch-extensao-vscode`
para a correção (`VSCodeExtensionPatcher`/`VSCodeExtensionWatcher`, que
muda esse scope para `"window"` no `package.json` instalado). Com essa
correção, o mecanismo descrito abaixo passa a funcionar de fato.

## Implementado e validado

`VSCodeSettings.setConfigDir` (em `Sources/claude-switcher-cli/VSCodeSettings.swift`)
faz o merge via `JSONSerialization` (não regex), sempre grava o
`CLAUDE_CONFIG_DIR` **expandido para path absoluto** (nunca `~`, porque o
processo que lê a env var não expande `~` sozinho — isso é responsabilidade
do shell, que não está no caminho aqui). `GitRisk.swift` implementa a opção 1
listada abaixo (checar `.gitignore`/tracking antes de escrever) — decisão
tomada: sempre escrever e avisar, nunca bloquear silenciosamente, para não
travar o fluxo do usuário em decisão que é dele.

Testado nos três cenários: (a) merge preservando `editor.tabSize` e outra
entrada de `claudeCode.environmentVariables` já existente, (b) arquivo com
comentários JSONC (perda avisada explicitamente), (c) arquivo já commitado
sem `.gitignore` (dispara aviso "ATENÇÃO").

**Limitação conhecida**: comentários JSONC no `settings.json` existente são
perdidos ao salvar (o parser faz fallback de "strip comments" só para
conseguir ler; a escrita final é sempre JSON puro). Aceitável para o MVP;
revisitar com um parser JSONC real se isso incomodar na prática.

## Edge cases

- `.vscode/settings.json` com JSON malformado → não sobrescrever às cegas;
  avisar o usuário e abortar a escrita.
- `claudeCode.environmentVariables` já tem outras variáveis além de
  `CLAUDE_CONFIG_DIR` → preservar todas, só substituir a entrada com
  `name == "CLAUDE_CONFIG_DIR"`.
- Projeto sem pasta `.vscode/` ainda → criar.

## Fora de escopo

- Qualquer lógica de patch da extensão oficial (ver `specs/03-patch-extensao-vscode`).

# Spec: Patch da extensão oficial do VS Code

Resolve: P1 (fallback indevido de conta), P13 (incorporar a correção do leog)

## Atualização: um segundo problema, mais crítico, encontrado depois

Além do problema de `process.env` descrito abaixo, existe uma causa raiz
separada e mais fundamental: `claudeCode.environmentVariables` é declarado
no `package.json` da extensão com `"scope": "machine"` — segundo a
documentação oficial da Microsoft, esse scope só pode ser definido em
*user*/*remote* settings, nunca em *workspace*. O VS Code ignora
silenciosamente qualquer valor desse setting escrito em
`.vscode/settings.json` de um projeto. **Essa era a causa real de por que a
troca de conta nunca tinha efeito, mesmo com o patch do leog aplicado e a
janela recarregada** — confirmado testando no VS Code real depois de trocar
o scope para `"window"` no `package.json` instalado.

Diferente do problema abaixo (que exige reescrever código JS minificado via
regex), esse é editar um campo de um JSON estático — **já implementado**:
`VSCodeExtensionPatcher` (`Sources/ClaudeSCore`) e
`VSCodeExtensionWatcher` (`Sources/ClaudeSApp`, reaplica sozinho via
`DispatchSource` quando a extensão atualiza). Ver kanban para o resumo
completo da investigação.

## Problema de origem (resolvido — ver "Decisão final" abaixo)

A extensão `anthropic.claude-code` tem *storage helpers* internos que leem
`process.env.CLAUDE_CONFIG_DIR` diretamente, enquanto
`claudeCode.environmentVariables` (setado via `.vscode/settings.json`, ver
spec 02) só é aplicado ao ambiente de processos que a extensão *lança*
(terminal/subprocesso), não ao processo da própria extensão rodando dentro
do VS Code. Resultado: a extensão pode continuar lendo a credencial errada
(a do `CLAUDE_CONFIG_DIR` default) mesmo com a config correta no projeto —
isso é a causa raiz do "fallback para conta pessoal" relatado (P3 original).

## Decisão original: vendorizar via JavaScriptCore (substituída)

A decisão original era vendorizar `patch-core.js`/`patch-regexes.js` de
`leog/claude-code-config-dir-patcher-vscode` como arquivos JS e rodá-los via
`JavaScriptCore`. Motivo da época: achar que a lógica era complexa demais
pra portar sem duplicar manutenção.

## Decisão final: reimplementado nativamente em Swift, não vendorizado

Motivador da mudança: a extensão `leog.claude-code-config-dir-patcher`
ficou **um dia inteiro desatualizada** depois de uma atualização da
extensão oficial, deixando o usuário sem conseguir trocar de conta até o
autor corrigir o patch dele. Depender do cronograma de terceiros pra reagir
a mudanças no bundle da Anthropic não é aceitável para o fluxo principal do
app.

Lendo `patch-core.js`/`patch-regexes.js` com esse objetivo em mente: a
lógica é só duas transformações regex puras sobre uma string (`analyze` +
`applyPatch`/`source.replace`), sem estado, sem I/O — trivialmente portável
para `NSRegularExpression` (ICU regex, suporta os mesmos backreferences e
grupos de captura usados nos padrões originais). A complexidade real estava
toda na camada de I/O em volta (retry contra leituras durante um update em
andamento, lock transiente ao escrever), que também foi portada fielmente.

**Implementado**: `ClaudeExtensionJSPatcher` (lógica pura, port 1:1 dos
regexes) + `ClaudeExtensionJSPatchRunner` (I/O: localizar, ler com retry,
backup, escrever com retry) + `ClaudePatchCoordinator` (une esse patch com
o de scope numa chamada só, usada pelo `VSCodeExtensionWatcher` e pelo item
"Reaplicar patch" do menu). Créditos e licença MIT em `ATTRIBUTIONS.md` —
a descoberta dos padrões de regex e do problema em si é trabalho do leog,
mesmo a implementação sendo nossa.

**Validado**: aplicar nosso patch no `extension.js` original produz uma
saída byte-a-byte idêntica à do patch do leog (mesmo tamanho exato). Nosso
`analyze()` reconhece corretamente o formato que o patch dele já tinha
produzido (compatibilidade de leitura preservada, útil enquanto os dois
coexistirem na mesma máquina). Testado de ponta a ponta via I/O real
(restaurando `extension.js`/`package.json` originais e reaplicando),
incluindo idempotência.

**Consequência**: a extensão `leog.claude-code-config-dir-patcher` deixou
de ser uma dependência necessária — pode ser desinstalada. Decisão de
quando fazer isso é do usuário.

## Fluxo de aplicação do patch

1. Localizar a instalação da extensão oficial via
   `VSCodeExtensionPatcher.locateExtensionDir()` (glob em
   `~/.vscode/extensions/anthropic.claude-code-*`, fica com a de maior
   versão se houver mais de uma). macOS only — não suporta Cursor/outros
   forks nem Windows/Linux.
2. Backup (`extension.js.claude-switcher-js-patch.bak`) antes da primeira
   escrita.
3. `ClaudeExtensionJSPatcher.analyze()` decide se já está patchado,
   patchável, ou se o needle não bate (versão não reconhecida — lança
   `ClaudeExtensionJSPatchError.envPatchPointNotFound`, nunca tenta
   heurística alternativa).
4. Se patchável e não patchado: aplica, escreve, confirmado idempotente nos
   testes (reaplicar não muda nada).
5. Reaplicado automaticamente via `VSCodeExtensionWatcher` (`DispatchSource`
   sobre `~/.vscode/extensions`, reativo — ver specs 02) sempre que a
   extensão é atualizada.

## Verificação de compatibilidade (evitar quebra silenciosa)

Não implementado um checker preventivo contra builds futuras (equivalente a
`scripts/check-upstream-patchability.mjs` do leog, que baixa builds do
Marketplace). Hoje a falha é visível na hora: `envPatchPointNotFound` lança
erro explícito (logado pelo `VSCodeExtensionWatcher`, ou mostrado no
`NSAlert` do item "Reaplicar patch"), não falha silenciosamente. Considerar
esse checker preventivo como melhoria futura, não bloqueador.

## Edge cases

- Needle não encontrado (`envPatchable == false` e `envPatched == false`) →
  versão da extensão oficial mudou de forma incompatível — erro explícito,
  nunca heurística alternativa.
- `extension.js` vazio/parcial durante um update em andamento → detectado e
  tratado com retry/backoff (`ClaudeExtensionJSPatchRunner`), nunca lança
  erro nesse caso (seria um falso positivo).
- Usuário restaura/reinstala a extensão oficial → patch se perde; o
  `VSCodeExtensionWatcher` detecta a mudança no diretório e reaplica.
- `extension.js` de plataforma diferente (o leog menciona que win32 difere
  dos demais) → não relevante, projeto é macOS only.

## Fora de escopo

- Telemetria/Sentry do projeto do leog — nunca foi relevante, não
  reimplementado.
- Suporte a Cursor/outros forks do VS Code, Windows, Linux.

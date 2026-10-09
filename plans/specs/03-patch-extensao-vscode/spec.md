# Spec: Patch da extensão oficial do VS Code

Resolve: P1 (fallback indevido de conta), P13 (incorporar a correção do leog)

## Problema de origem

A extensão `anthropic.claude-code` tem *storage helpers* internos que leem
`process.env.CLAUDE_CONFIG_DIR` diretamente, enquanto
`claudeCode.environmentVariables` (setado via `.vscode/settings.json`, ver
spec 02) só é aplicado ao ambiente de processos que a extensão *lança*
(terminal/subprocesso), não ao processo da própria extensão rodando dentro
do VS Code. Resultado: a extensão pode continuar lendo a credencial errada
(a do `CLAUDE_CONFIG_DIR` default) mesmo com a config correta no projeto —
isso é a causa raiz do "fallback para conta pessoal" relatado (P3 original).

## Decisão: vendorizar, não reimplementar

`leog/claude-code-config-dir-patcher-vscode` resolve isso fazendo
substituição de regex sobre o bundle minificado (`extension.js`) da extensão
oficial. A lógica central está isolada em dois arquivos **puros, sem
dependência de `vscode` ou `fs`**: `patch-core.js` e `patch-regexes.js`
(confirmado lendo o código — ver comentário no topo de `patch-core.js`).

Em vez de portar essa lógica pra Swift (o que criaria manutenção duplicada
toda vez que o upstream mudar o bundle minificado), vamos:

1. **Vendorizar** os dois arquivos (`patch-core.js`, `patch-regexes.js`) em
   `vendor/claude-code-patcher/`, com atribuição e licença MIT preservada,
   anotando o commit/tag de origem num `VENDORED_FROM.md`.
2. **Executá-los via `JavaScriptCore`** (framework nativo do macOS, sem
   precisar de Node instalado) a partir do Swift: carregar os dois arquivos
   num `JSContext`, chamar `applyPatch(source)` passando o conteúdo do
   `extension.js` instalado do usuário, receber a string patchada de volta.
3. **Atualizar por sincronização de arquivo**, não por fork: quando o leog
   atualizar os regexes (upstream muda o bundle), rodamos um script local
   que baixa as versões novas de `patch-core.js`/`patch-regexes.js` do repo
   dele e substitui o conteúdo vendorizado, sem tocar no resto do código
   (que é específico de extensão VS Code / Sentry, que não usamos).

## Fluxo de aplicação do patch

1. Localizar a instalação da extensão oficial:
   `~/.vscode/extensions/anthropic.claude-code-*/dist/extension.js` (ou
   equivalente no Cursor/outros forks, se formos suportar — **não assumir**,
   confirmar o path exato quando for implementar).
2. Fazer backup (`extension.js.bak`) antes de qualquer escrita.
3. Rodar `analyze()` (do `patch-core.js`) pra saber se já está patchado,
   patchável, ou se o needle não bate (versão não reconhecida).
4. Se patchável e não patchado: aplicar, escrever o resultado, verificar
   idempotência (reaplicar não deve mudar nada) antes de considerar sucesso.
5. Reaplicar automaticamente quando a extensão for atualizada pelo VS Code
   (detectar mudança de versão/mtime do `extension.js` e reagir).

## Verificação de compatibilidade (evitar quebra silenciosa)

Adaptar a lógica de `scripts/check-upstream-patchability.mjs` do leog
(também reaproveitável, mesma licença) para, periodicamente ou no startup do
nosso app, checar se o `extension.js` atualmente instalado ainda bate com os
needles vendorizados. Se não bater: alertar o usuário na status bar ("patch
desatualizado — pode haver fallback de conta") em vez de falhar silenciosamente.

## Edge cases

- Needle não encontrado (`envPatchable == false` e `envPatched == false`) →
  versão da extensão oficial mudou de forma incompatível. Não tentar aplicar
  heurística alternativa — alertar e aguardar atualização do vendor.
- Usuário restaura/reinstala a extensão oficial → patch se perde, precisa
  reaplicar (hook de detecção de mudança do arquivo).
- `extension.js` de plataforma diferente (o leog menciona que win32 difere
  dos demais) → não relevante pro nosso caso (macOS only), mas documentar.

## Fora de escopo

- Telemetria/Sentry do projeto do leog — não vendorizar `telemetry.json` nem
  a lógica de analytics, só os dois arquivos de patch puro.

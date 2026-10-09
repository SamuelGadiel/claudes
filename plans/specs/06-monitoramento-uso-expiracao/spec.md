# Spec: Monitoramento de uso (quota) por conta

Resolve: P6

## Resolvido — não é mais pesquisa, é um plano de implementação

Confirmado investigando o código-fonte (MIT) de dois apps open source que já
fazem exatamente isso —
[`LunaParker/claude-macos-menu-usage`](https://github.com/LunaParker/claude-macos-menu-usage)
e `hamed-elfayome/Claude-Usage-Tracker`, ambos Swift/SwiftUI — e a issue
pública [`anthropics/claude-code#31021`](https://github.com/anthropics/claude-code/issues/31021).

Existe um endpoint real que o próprio Claude Code usa para alimentar a
barra de status dele:

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <accessToken>
anthropic-beta: oauth-2025-04-20
Accept: application/json
```

Não é documentado publicamente como API oficial, mas é o mesmo mecanismo
que o Claude Code usa internamente — não é um endpoint secreto descoberto
por tráfego de rede nosso, é conhecimento já público/replicado por outros
projetos MIT.

## Resposta da API — confirmado contra as duas contas reais

Implementado e testado de ponta a ponta (`cs usage <slug>`) contra as
contas Pessoal e Trabalho reais. O formato real difere um pouco do que o
projeto de referência documentava (API evoluiu desde então):

- `five_hour` / `seven_day` / `seven_day_opus`: cada um
  `{ utilization: Double? (0-100), resets_at: Date? }` — as barras de
  progresso de sessão (5h) e semanal. `resets_at` vem `null` quando
  `utilization` é 0 (a janela ainda não começou a contar).
- **Datas vêm em ISO 8601 com microssegundos e offset `+00:00`**
  (`"2026-10-12T08:59:59.551118+00:00"`), não no formato que
  `JSONDecoder().dateDecodingStrategy = .iso8601` aceita por padrão (que
  rejeita fração de segundo). Implementado parse customizado com fallback
  (`UsageDateParsing` em `UsageClient.swift`): tenta
  `ISO8601DateFormatter` com `.withFractionalSeconds`, cai para sem fração
  se falhar.
- `extra_usage`: `{ is_enabled, monthly_limit, used_credits, utilization }`
  modelados (a resposta real traz ainda `currency`, `decimal_places`,
  `disabled_reason`, `daily`, `weekly` etc. — ignorados por ora, não
  necessários para as barras do painel). **Decisão**: renderizar como
  terceira barra condicional (só quando `is_enabled == true`).
- A resposta real traz uma quantidade grande de campos extras com nomes de
  código internos da Anthropic (`tangelo`, `iguana_necktie`,
  `omelette_promotional`, `nimbus_quill`, etc.) — todos `null` nas duas
  contas testadas, provavelmente feature flags/experimentos. Não
  declarados no modelo — `Codable` ignora silenciosamente qualquer chave
  não mapeada, não precisa de tratamento especial.
- Removido do modelo (não essencial ao MVP, formato real não bate com o
  que o projeto de referência documentava — era `scope.model.display_name`,
  na prática observamos `{kind, group, percent, severity, resets_at,
  is_active}`): o array `limits[]` de quotas por modelo específico. Revisar
  se algum usuário em plano Max precisar dessa granularidade.

## Mudança de escopo: agora lemos o `accessToken`

Até aqui (`specs/01-gerenciamento-contas-storage`), deliberadamente nunca
líamos `accessToken`/`refreshToken` do Keychain — só os metadados de
expiração. Para chamar esse endpoint, precisamos do `accessToken` de
verdade. Regra mantida: ele fica **só em memória**, nunca é logado, nunca é
escrito em arquivo — usado exclusivamente para montar o header
`Authorization` da requisição, imediatamente.

## Resiliência (copiada da experiência real do `claude-macos-menu-usage`)

O endpoint tem um rate limiter agressivo e retorna 429 persistente com
facilidade (confirmado pela issue #31021 do próprio repo do Claude Code):

- Poll em background: intervalo entre 2 e 5 minutos, nunca mais frequente.
- **Poll condicional**: só dispara quando há sinal de uso real da conta —
  pelo menos um projeto VS Code aberto (`storage.json`) ou pelo menos um
  processo `claude` standalone rodando (ver seção de detecção de processos
  abaixo). Sem nenhum dos dois, o timer continua de pé mas não bate rede —
  evita gastar a cota de rate limit do endpoint sem necessidade.
- **Refresh forçado ao abrir o painel**: clicar no ícone sempre dispara uma
  busca imediata, ignorando o intervalo de poll — o usuário não deveria ver
  um número com até 5 minutos de atraso no momento em que decide olhar.
  O debounce de 15s continua existindo, mas só para o caso degenerado de
  abrir/fechar o painel repetidamente em menos de 15s (nunca para a
  primeira abertura depois de um tempo parado).
- Em 429: respeita `Retry-After` se vier; senão, backoff default de 5
  minutos, com piso mínimo de 60s (nunca menor, mesmo que o header venha
  zerado/inválido).
- Cache das credenciais lidas do Keychain em memória, para não repetir
  leitura (e risco de reprompt de autorização) a cada poll.

## Detecção de sessões `claude` rodando no terminal

Validado nesta máquina, sem nenhuma permissão especial (nem Acessibilidade,
nem Screen Recording — só APIs padrão de processo, mesmo usuário):

- `sysctl` com `KERN_PROCARGS2` dá acesso ao `argv`/`envp` completo de
  qualquer processo do mesmo usuário. Testado contra um processo `claude`
  real: leu `CLAUDE_CONFIG_DIR=/Users/.../.claude` do ambiente — o valor
  **real** que aquele processo está usando, não uma inferência.
- `proc_pidinfo` com `PROC_PIDVNODEPATHINFO` dá o cwd real do processo.
  Testado: retornou o path exato de onde o processo foi lançado.
- **Diferenciar de processos da extensão VS Code** (que também são `claude`
  rodando): a extensão sempre passa flags como `--output-format
  stream-json --input-format stream-json --permission-prompt-tool stdio` —
  nenhum uso manual no terminal passa isso. Filtra por esses flags para não
  duplicar entradas já cobertas pela lista de projetos VS Code (seção
  acima, via `storage.json`).
- Se `CLAUDE_CONFIG_DIR` estiver ausente do ambiente do processo, a conta
  em uso é a default do sistema (`~/.claude`) — resolve normalmente contra
  as contas registradas pelo `configDir`.
- Resultado: o painel ganha uma seção "Sessões de terminal" ao lado de
  "Projetos abertos (VS Code)", cada uma podendo trocar de conta do mesmo
  jeito (ver `specs/05-app-status-bar`).

## Renovação do access token expirado

Confirmado (já vimos isso na spec 01: é normal o access token estar
expirado e o Claude Code renovar sozinho em segundo plano) — mas **para
forçar essa renovação sob nosso controle** antes de chamar o endpoint de
usage, a técnica validada pelo projeto de referência é:

- Rodar `claude mcp list` (não `claude` puro — exige TTY; não
  `claude auth status` — só reporta estado cacheado, **nunca bate um
  endpoint autenticado**, então nunca dispara o refresh OAuth de verdade).
- Via o shell de login do usuário com `-i -l` (`$SHELL -i -l -c "claude mcp
  list"`) — necessário porque um app GUI lançado pelo Finder/LaunchServices
  não herda o PATH do terminal (diferente do nosso `cs`, que já roda dentro
  de um terminal com PATH correto). Isso é uma nota nova para
  `specs/07-cli-gateway`/`05-app-status-bar`: o `ClaudeGateway` atual
  (`/usr/bin/env claude`) só funciona bem chamado de dentro de um terminal;
  chamado pela GUI vai precisar resolver o shell de login do usuário.
- `cwd` fixado em `/tmp` (evita disparar prompts de TCC por acessar
  `~/Desktop`/`~/Documents`/etc. que `claude mcp list` poderia tocar).
- **Nunca enviar SIGTERM** ao processo — um SIGTERM no meio da escrita de
  credenciais faz o Claude Code mover a credencial pra fora do Keychain
  (achado direto do código de referência). Usar timeout + deixar o processo
  seguir seu curso, nunca matar.

## Arquitetura final: protocolo de controle do Claude Agent SDK (não HTTP)

Duas abordagens foram tentadas e descartadas antes de chegar na correta —
registradas aqui porque o caminho até a resposta certa importa tanto quanto
a resposta:

1. **Endpoint HTTP `/api/oauth/usage` direto** (`UsageAPIClient`, ainda
   existe no código): falhava consistentemente para a conta Pessoal (401
   recorrente, depois 429) enquanto claude.ai, CLI e extensão VS Code sempre
   funcionaram. Mantido só como peça de referência/debug manual
   (`cs usage <slug>` passou a usar o mecanismo novo, não este).
2. **statusLine hook** (`code.claude.com/docs/en/statusline`): o Claude Code
   empurra `rate_limits` via stdin a cada resposta de API, sem chamada HTTP
   extra — tecnicamente funcionava, mas **rejeitado pelo usuário**: só
   populava depois de uma interação na sessão, nunca "sob demanda" como a
   tela "Account & Usage" da extensão, que mostra o uso instantaneamente ao
   abrir um chat novo, sem mandar nada. Removido por completo (código e
   configuração nas contas).

**O mecanismo real, descoberto lendo o código da própria extensão
(`extension.js`)**: a tela "Account & Usage" não bate em nenhum endpoint
HTTP diretamente — ela manda uma **control_request** pelo protocolo
`stream-json` do Claude Agent SDK para o processo `claude` já autenticado
(`usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET` → `{"subtype":
"get_usage"}`), e é o próprio binário oficial quem busca o dado real. Isso
explica tudo: delegando a chamada para o binário oficial (que sabe se
autenticar/chamar corretamente), a diferença de comportamento por conta
desaparece — testado e confirmado funcionando perfeitamente para Pessoal e
Trabalho.

`UsageControlClient.fetch(configDir:)` (`Sources/ClaudeSwitcherCore/`)
implementa isso: spawna `claude --input-format stream-json --output-format
stream-json -p` com `CLAUDE_CONFIG_DIR` da conta, escreve
`{"type":"control_request","request_id":"...","request":{"subtype":
"get_usage"}}` no stdin, lê stdout linha a linha até achar a
`control_response` com o `request_id` correspondente, decodifica
`response.response.rate_limits` (mesma estrutura de `UsageWindow`/
`ExtraUsage` já usada pelo client HTTP). Processo finalizado com
`terminate()` — seguro aqui porque é uma leitura, não uma renovação de
credencial no meio de uma escrita (diferente de `CredentialRefresher`, que
nunca mata o processo).

**Resultado**: funciona sob demanda, a qualquer momento, sem exigir nenhuma
sessão ativa nem interação prévia — exatamente o que a tela da extensão faz.
Validado via `cs usage pessoal`/`cs usage trabalho`: ambas retornam dados
reais e corretos, sem nenhum erro.

O `statusline-command.sh` que o usuário tinha configurado antes na conta
Pessoal não foi restaurado — confirmado com ele que não usa mais.

## Causa real do rate limit persistente na conta Pessoal (histórico — mitigado, não era a raiz completa)

Depois de um dia inteiro sem conseguir ver uso da conta Pessoal pelo painel
— enquanto claude.ai, o CLI e a extensão VS Code mostravam normalmente o
tempo todo — ficou claro que a explicação de "instabilidade do endpoint"
sozinha não bastava: se fosse só isso, funcionaria às vezes, não nunca.

Duas causas identificadas, a segunda bem mais provável como raiz real:

1. **`rateLimitTier` diferente por conta**: confirmado lendo o Keychain —
   Pessoal usa `default_claude_ai`, Trabalho usa `default_raven`. É
   plausível que a Anthropic aplique limites mais restritos a esse endpoint
   para esse tier específico (planos Pro individuais vs Team/Enterprise).
2. **O poll rodava em background o dia inteiro, mesmo com o painel
   fechado** — bug nosso. `startPolling()` era chamado uma vez no `init()`
   do `PanelViewModel` e nunca parava, fazendo uma tentativa a cada 3min
   por horas, consumindo continuamente o orçamento (provavelmente baixo,
   por causa do tier) da conta Pessoal sem nunca dar chance dele se
   recuperar. Isso é consistente com "Trabalho sempre funcionou" (tier sem
   essa restrição) e "Pessoal nunca funcionou" (orçamento pequeno,
   constantemente zerado pelo nosso próprio poll).

**Corrigido**: o poll agora só roda enquanto o popover está de fato visível
na tela — `PanelViewModel` é criado e possuído pelo `StatusBarController`
(não mais pela `PanelView` via `@StateObject`), que chama
`startPolling()`/`stopPolling()` no mesmo gesto de abrir/fechar o popover
(`togglePopover()`), reforçado por `onAppear`/`onDisappear` na view. Antes,
o ViewModel vivia e pollava para sempre a partir do momento em que a view
era criada pela primeira vez, independente do popover estar visível.

## Implementado: poll condicional, debounce e cache de último resultado

- Poll em background a cada 3 min (dentro da faixa 2–5min), só dispara
  fetch se houver pelo menos um projeto VS Code aberto ou uma sessão de
  terminal ativa — sem isso, não bate o endpoint à toa.
- Debounce de 15s: trocar de aba ou reabrir o painel não dispara uma nova
  busca se a última bem-sucedida foi há menos de 15s.
- Botão "Tentar novamente" (ação explícita do usuário) sempre ignora o
  debounce.
- Em caso de erro, o painel preserva e continua mostrando o último
  resultado bem-sucedido (`lastUpdated`), com um aviso discreto em laranja
  em vez de substituir tudo por uma tela de erro — o endpoint é instável
  (ver abaixo), um erro pontual não deveria apagar um dado válido.

## Instabilidade confirmada em uso real (painel vs CLI)

Testando a mesma conta (Pessoal) minutos de diferença entre o painel SwiftUI
e `cs usage pessoal`: o CLI recebeu 401 → renovou → 429 (rate limit); o
painel, rodado logo depois, recebeu 401 → renovou → **401 de novo** (não
429). Mesma conta, janela de tempo próxima, resultado diferente — confirma
que o endpoint é genuinamente instável (não é bug nosso tentando reproduzir
um resultado determinístico). Implicações de design:

- A UI nunca deve tratar um 401 pós-renovação como "sua sessão expirou,
  faça login de novo" — a sessão real pode estar perfeitamente ativa (ex.:
  o próprio usuário conversando com o Claude Code na mesma conta, ao mesmo
  tempo, como aconteceu no teste). Mensagem correta: instabilidade
  temporária do endpoint, tentar de novo mais tarde.
- Todo estado de erro no painel tem um botão "Tentar novamente" — o usuário
  nunca fica numa tela sem nenhuma ação possível quando a busca falha.

## Validado end-to-end (`cs usage <slug>`)

- Conta Trabalho: `200 OK`, `five_hour.utilization=0`,
  `seven_day.utilization=76` com `resets_at` convertido corretamente para o
  horário local. Confirma request/headers/parse corretos.
- Conta Pessoal: access token revogado (`"OAuth access token has been
  revoked"`, não só "expirado") → disparou `CredentialRefresher` →
  renovação completou dentro do timeout → segunda tentativa recebeu
  **429 com `Retry-After: 3600`**. Consistente com a issue #31021: o
  rate limiter é por conta/token, e esta sessão já estava consumindo o
  budget dessa mesma conta (Claude Code real rodando em paralelo nela,
  nesta própria conversa). Prova que o backoff documentado acima não é
  teórico — é o comportamento real esperado em uso normal.

## UI: onde isso entra no painel (ver `specs/05-app-status-bar`)

Três barras de progresso por conta (5h, semanal, extra se houver), com
label de porcentagem e horário de reset, dentro da aba daquela conta no
painel customizado.

## Fora de escopo

- Qualquer forma de "prever" o uso antes da API confirmar (ex.: estimar a
  partir dos `.jsonl` locais) — descartado: a API oficial (ainda que não
  documentada) já dá o número exato que a Anthropic usa para throttle, sem
  precisar replicar a lógica de pesos por modelo.

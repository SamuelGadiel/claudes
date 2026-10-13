# Spec: Chats compartilhados entre contas

Resolve: P4

> **Decisão revisada.** A versão original desta spec (sync-on-switch, cópia
> pontual por projeto) foi substituída depois de uso real expor seus
> problemas: duplicação (o chat continuado na conta B nunca volta pra conta
> A), e a cópia inicial só pegava `.jsonl`, perdendo as subpastas por sessão
> (`subagents/`, `tool-results/`). A decisão de symlink foi reaberta e
> revisada com evidência concreta — ver abaixo.

## Decisão: todas as contas compartilham o mesmo `projects/`, via symlink

`<CLAUDE_CONFIG_DIR>/projects` deixa de existir como diretório próprio de
cada conta — é sempre um symlink apontando para `SharedSessionsDirectory`
(`~/.claude-shared-chats`, `Sources/ClaudeSCore/SharedSessionsDirectory.swift`).
Chats passam a pertencer ao **projeto**, não à conta que estava logada quando
foram escritos — não importa qual conta está ativa, o histórico completo de
qualquer projeto está sempre lá.

### Por que symlink, revisado

A spec original rejeitou symlink por dois motivos. Reavaliados:

1. **"Escopo indesejado: unifica todos os projetos entre as contas."**
   Decisão consciente agora: esse é o comportamento desejado, não um efeito
   colateral. Mitigado por uma ferramenta de controle: "Clear Chat
   History" por projeto (ver abaixo) — não é isolamento real entre contas,
   mas dá ao usuário uma forma explícita de não deixar o histórico de um
   projeto específico acumulado indefinidamente.
2. **"Risco de concorrência em `sessions/`."** A própria spec original já
   reconhecia que esse risco era especificamente sobre `~/.claude/sessions/`
   (locks de processo, `<pid>.json`), não sobre `projects/` — só evitou tudo
   por precaução geral. `projects/` continua sem esse problema. Duas contas
   escrevendo a mesma sessão ao mesmo tempo é um cenário raro, e o próprio
   Claude Code já avisa quando detecta isso ("If another Claude Code process
   still has the conversation open..." — confirmado na doc oficial). Não
   tratado agora; revisitar se vier a ser um problema real.

**Confirmado por evidência real, não suposição**: a técnica de symlinkar
`projects/` entre `CLAUDE_CONFIG_DIR`s é usada por múltiplos projetos da
comunidade (não documentada/suportada oficialmente pela Anthropic, mas
relatada funcionando em produção). Validado também por teste próprio: um
diretório contendo um symlink, removido recursivamente, preserva o alvo do
link intacto — `removeAccount` não precisou de nenhuma mudança para "remover
conta, manter os chats" funcionar.

### Por que não uma pasta "nossa" com lógica própria por cima

Cogitado e descartado: tecnicamente equivalente ao symlink direto (o Claude
Code sempre procura `projects/` relativo ao `CLAUDE_CONFIG_DIR` ativo, então
uma pasta "gerenciada por nós" ainda precisaria ser symlinkada de volta) —
mesmos riscos técnicos, mais código nosso por cima sem ganho real.

## Design

### `SharedSessionsDirectory.adopt(configDir:accountSlug:)`

Chamada em todo `addAccount` (criação de conta nova e futura importação de
conta existente — mesmo código, mesma garantia). Nunca lê ou interpreta o
conteúdo de um `.jsonl`/sessão — todo arquivo é tratado como blob opaco:

1. Se `projects/` já é o symlink certo: no-op.
2. Se não existe nada ainda (conta nova): cria o symlink direto.
3. Se já existe uma pasta real com sessões (conta já usada antes de adotar o
   symlink, ou importada de fora): merge por projeto, depois por item dentro
   de cada projeto (arquivo `.jsonl` ou subpasta de sessão inteira):
   - Sem conflito de nome: move.
   - Conflito, conteúdo idêntico (hash): descarta a duplicata, nada perdido.
   - Conflito, conteúdo diferente: **nunca sobrescreve, nunca descarta**. O
     maior (heurística: mais completo/mais recentemente continuado) fica com
     o nome original, continua resumível pelo ID normalmente. O menor é
     preservado ao lado com sufixo `.conflict-from-<origem>`.
4. Remove o `projects/` original (agora vazio) e cria o symlink.

### `SharedSessionsDirectory.clearHistory(forProjectPath:)`

Apaga `<shared>/<dirName>/` inteiro — só aquele projeto, nenhum outro é
tocado. Irreversível; a UI confirma antes de chamar. Acionado por "Clear Chat
History…" na linha de cada projeto no painel.

### `cs migrate-to-shared-sessions`

Roda `adopt` para todas as contas já registradas — não é só para esta
migração pontual: serve também para quem atualizar de uma versão anterior a
este modelo, com contas já cadastradas antes de `projects/` virar symlink.

## Validado

Testado em diretórios descartáveis (`/tmp`), não em dados reais, antes de
rodar em produção:
- Conta nova sem sessões: symlink criado direto.
- Duas contas com projetos sem sobreposição: movidos sem conflito.
- Mesmo projeto em duas contas, um arquivo idêntico nos dois: duplicata
  descartada sem perda.
- Mesmo projeto, mesmo nome de sessão, conteúdo diferente: ambos
  preservados, maior manteve o nome original, menor ganhou sufixo de
  conflito.
- `cs remove` em conta com `projects/` symlinkado: diretório da conta e
  credencial do Keychain removidos, conteúdo compartilhado intacto.

## Fora de escopo (por ora)

- Resolver concorrência real de duas contas ativas escrevendo a mesma sessão
  ao mesmo tempo.
- Isolamento real entre contas (ex.: conta de trabalho nunca ver histórico
  de projetos pessoais) — hoje só existe o "Clear Chat History" manual por
  projeto.
- UI de importação de conta existente (seletor de pasta) — a lógica de
  backend (`addAccount` com `dir` customizado + `adopt`) já suporta isso via
  CLI (`cs add --dir <pasta-existente>`); falta só a UI gráfica equivalente.

# Spec: Sincronização de sessões (chats) entre contas

Resolve: P4

## Decisão: sync-on-switch, não symlink

Symlink global de `projects/` entre `CLAUDE_CONFIG_DIR`s foi descartado por
dois motivos concretos (não só "medo de fragilidade" subjetivo):

1. **Escopo indesejado**: um symlink no nível de `projects/` unifica *todos*
   os projetos entre as duas contas, não só o projeto que o usuário está
   trocando agora. Quebra a expectativa "só esse projeto muda".
2. **Risco de concorrência real**: `~/.claude/sessions/` guarda estado de
   processo ativo (`<pid>.json` + `<pid>.<hash>.key`), amarrado ao processo
   em execução daquele `CLAUDE_CONFIG_DIR`. Compartilhar o diretório todo
   correria o risco de duas contas ativas simultaneamente (ex.: dois
   terminais) colidirem em arquivos de lock que não foram desenhados pra
   isso. `projects/` não tem esse problema isoladamente, mas o padrão geral
   (symlinkar diretórios internos do Claude Code) é arriscado o suficiente
   pra evitar por completo.

## Design: cópia pontual, escopada ao projeto

Quando o usuário troca a conta associada a um projeto (ação feita na spec 05,
status bar):

1. Calcular o nome de diretório do projeto. **Confirmado**: não é hash — é o
   path absoluto com cada `/` substituído por `-`, validado contra os 10
   projetos reais já existentes nesta máquina (`ProjectHash.swift`).
2. Localizar `<CONFIG_DIR_ORIGEM>/projects/<hash>/` e
   `<CONFIG_DIR_DESTINO>/projects/<hash>/`.
3. Copiar os arquivos `.jsonl` da origem para o destino que não existam lá
   ainda (merge por nome de arquivo = `sessionId`), **nunca sobrescrever**
   um `.jsonl` já existente no destino com o mesmo nome (evita perder
   histórico que já estava sendo escrito do lado de destino).
4. Não tocar em `sessions/` (estado de processo ativo) nem em
   `file-history/` nesta primeira versão — são efêmeros/não essenciais ao
   histórico de chat. Reavaliar `file-history` depois se o usuário sentir
   falta do undo de edições ao trocar de conta.

## Requisitos funcionais

1. Cópia unidirecional, disparada manualmente pelo usuário (ação explícita
   "sincronizar e trocar", nunca automática em background).
2. Logar o que foi copiado (quantos arquivos, quais sessionIds) para o
   usuário poder auditar.
3. Se o diretório de destino não existir ainda (conta nunca usada nesse
   projeto), criar.

## Implementado e validado

`sync-sessions <projeto> <conta-origem> <conta-destino>` (`SessionSync.swift`).
Testado: (a) primeira cópia copia todos os `.jsonl`, (b) rodar de novo não
sobrescreve nada e lista o que já existia, (c) projeto sem sessões na conta
de origem retorna erro claro em vez de criar diretório vazio silenciosamente.

## Edge cases

- Conflito de nome de arquivo com conteúdo diferente (não deveria acontecer,
  já que o nome é um UUID de sessão) → não sobrescreve, loga como "já existia".
- Projeto muito grande (muitas sessões antigas) → copiar tudo mesmo, é texto
  (jsonl), custo de IO baixo; não otimizar prematuramente.

## Fora de escopo

- Sincronização bidirecional contínua.
- Resolver concorrência de duas contas ativas ao mesmo tempo no mesmo projeto.

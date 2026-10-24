# root/sudo e TCC/Accessibility como bypass dos prompts do Keychain (macOS)

## O prompt "App X deseja acessar a chave..." é decidido por assinatura de código ou por UID? Rodar como root muda isso para itens do login keychain?

### Takeaway
O modelo de ACL do Keychain Services é fundamentado na **identidade de assinatura de código do processo requisitante** (Designated Requirement / CDHash, armazenado na "trusted-application list" / partition list do item), **não no UID Unix**. Rodar como root não altera essa avaliação: um DTS engineer da Apple confirmou explicitamente que o Keychain não foi desenhado para diferenciar/conceder acesso especial a processos root, e que tentar usar o Keychain para esse fim "definitivamente vai gerar problemas". Classificação: **INVIÁVEL** como bypass legítimo.

### Cited Findings
- "The designated requirement is an explicitly specified designated requirement for the signed code... any code that meets this requirement is considered to be the 'same' for various purposes... if the app saves a password in your keychain, the designated requirement is stored for access control." — [Apple Developer: Code Signing Requirement Language / TN2206](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)
- "The program that initially sets up the keychain items must include other programs in its ACL using... SecTrustedApplication." Code signing é verificado via `SecTrustedApplication`/`SecACL`, e o securityd consulta os entitlements/assinatura do app requisitante. — [Apple Developer Forums: SecTrustedApplicationCreateFromPath removed](https://developer.apple.com/forums/thread/118479); [WWDC 2013 Session 709: "Protecting Secrets with the Keychain"](https://docs.huihoo.com/apple/wwdc/2013/session_709__protecting_secrets_with_the_keychain.pdf)
- "The item's ACL partition list is bound to binary CDHashes, not the signing certificate — dumps show only cdhash: entries." Isso confirma que a granularidade é por hash/identidade de código assinado do binário requisitante, e não por usuário Unix. — [Apple Developer Forums discussion sobre keyring providers e ACL](https://developer.apple.com/forums/thread/761930)
- Resposta direta de um engenheiro de DTS da Apple ao ser perguntado se um processo root pode acessar um item do keychain sem prompt, de forma seletiva via ACL: *"The keychain isn't really intended to be used for this task, and you'll definitely run into issues trying to use it for that."* Ele explica que o Keychain aplica permissões por fronteira de processo (identidade do processo chamador), não por UID, e que mesmo que fosse configurável, não resolveria o problema de segurança de fundo. — [Apple Developer Forums: "Access to a keychain item for process running as root" (thread 737888)](https://developer.apple.com/forums/thread/737888)
- "macOS keychain access control binds 'Always Allow' to a binary's code signature, and an ad-hoc signature gives the binary no stable identity to match against" — reforça que a decisão de "sempre permitir" é amarrada à assinatura, não ao usuário/UID que executa o processo. — [GitHub Issue DataDog/pup #542](https://github.com/DataDog/pup/issues/542)

### Inferences
- Como a ACL é resolvida por Designated Requirement/CDHash do binário chamador (nível de código assinado), rodar o mesmo binário não assinado/ad-hoc como root ou como usuário normal produz exatamente o mesmo resultado em termos de avaliação de ACL — root não "pula" a etapa de verificação de assinatura, porque essa etapa não depende de UID.
- Um processo root diferente do processo que originalmente criou o item (ex.: um daemon root de terceiros) é tratado pelo securityd como um requisitante *não listado* na trusted-application list do item — logo, ainda recebe o prompt (ou falha silenciosamente se não houver sessão de UI, ver próxima seção), exatamente como qualquer outro processo não autorizado.

### Gaps
- Não há documentação oficial da Apple enumerando formalmente "o Keychain Services avalia ACLs com base em code signature e nunca em UID" como frase única; a conclusão é inferida combinando a documentação de Designated Requirement/TN2206, a resposta de DTS no fórum, e múltiplos relatos técnicos consistentes sobre CDHash/partition list. Nenhuma fonte contradisse essa conclusão.

---

## Existe algum caso documentado de um processo root conseguir ler um item do login keychain de outro usuário/app sem prompt, legitimamente (não via exploit)?

### Takeaway
Não foi encontrado nenhum caso **legítimo e documentado** de root lendo silenciosamente um item do login keychain de outro usuário/app sem estar na trusted-application list do item. O único caso documentado de leitura silenciosa e abrangente do keychain sem prompt é o exploit **KeySteal** (CVE-2019-8526), que é uma vulnerabilidade de dia zero corrigida pela Apple — não uma permissão root suportada. Classificação: **INVIÁVEL** (via mecanismo legítimo).

### Cited Findings
- KeySteal: "A macOS <= 10.14.3 Keychain exploit... allows you to access passwords inside the Keychain without a user prompt... Neither root access nor administrator privileges are required, and no password prompts are generated... capable of extracting passwords from the Login and System keychains... works even if System Integrity Protection is enabled, or Access Control Lists are set up." Vulnerabilidade atribuída CVE-2019-8526, corrigida pela Apple em 10.14.4. — [GitHub: LinusHenze/Keysteal](https://github.com/LinusHenze/Keysteal); [BetaNews: KeySteal huge macOS vulnerability](https://betanews.com/article/macos-keysteal-keychain-vulnerability/)
- Ponto crucial: o próprio autor do exploit (Linus Henze) demonstra justamente que esse comportamento **não é o comportamento normal/suportado** — é uma falha que a Apple precisou corrigir, confirmando que, fora da vulnerabilidade, o modelo de ACL por assinatura/trusted-application funciona como barreira mesmo contra root.
- Um daemon LaunchDaemon root tentando acessar o login keychain do usuário encontra, em vez de bypass, erros de "user interaction not allowed" quando não há sessão de UI, ou segue as mesmas regras de ACL de qualquer outro processo: "A daemon launched by 'launchd' is only able to access the System Keychain... not the user's login keychain" (sem configuração especial de sessão). — [Apple Developer Forums: "System Keychain not available from a Daemon" (759976)](https://developer.apple.com/forums/thread/759976); [Apple Developer Forums: "Launch Daemon is not able to access login keychain entries" (656000)](https://developer.apple.com/forums/thread/656000)

### Inferences
- O caso KeySteal é evidência indireta forte de que, *sem* uma vulnerabilidade, nem mesmo root consegue ler itens do keychain de outro app/usuário sem prompt — caso contrário o exploit não seria noticiado como "0-day" significativo e não exigiria correção da Apple.

### Gaps
- Não foi possível confirmar o estado atual (2023-2026) de exploits equivalentes ao KeySteal em versões modernas (Ventura/Sonoma/Sequoia) — presume-se corrigido e sem substituto público conhecido, mas a pesquisa não cobriu CVEs recentes especificamente sobre bypass de ACL de Keychain em 2024-2026.

---

## O System Keychain tem modelo de confiança diferente? Processos root podem gravar/ler lá sem prompt? Isso ajudaria um item migrado para lá?

### Takeaway
O System Keychain (`/Library/Keychains/System.keychain`) **é gravável apenas por root** no nível de arquivo, e scripts/daemons root conseguem rotineiramente adicionar/ler itens lá programaticamente sem prompt de UI (padrão comum em deployments MDM/enterprise) — mas **isso só é relevante se o processo que cria/gerencia o item for o próprio root/você controlando o item**. Como o enunciado da pesquisa deixa claro que o item hoje é criado e gerenciado por um **CLI de terceiros fora do seu controle**, migrar para o System Keychain não resolveria nada: você não pode forçar o CLI de terceiros a escrever ali, e mesmo que escrevesse, o ACL/trusted-application list daquele item ainda seria amarrado à assinatura de código do CLI de terceiros, não à sua. Classificação: **PARCIALMENTE VIÁVEL em teoria, INVIÁVEL no seu cenário concreto** (dependência de terceiro).

### Cited Findings
- "The System keychain file is only writable by root, and if you're running a LaunchDaemon without specifying the user, it runs as root." — [Apple Developer Forums: "System keychain from daemon access requires root?" (657874)](https://developer.apple.com/forums/thread/657874)
- Fluxo documentado de automação: `sudo security add-trusted-cert -d -p basic -k /Library/Keychains/System.keychain` e `security add-generic-password -a <account> -s <service> -w <password>` são comandos padrão usados por scripts de administração (Jamf, MDM) para popular o System Keychain sem interação do usuário, quando executados como root/via MDM. — [ss64.com: Security Command reference](https://ss64.com/mac/security.html); [Jamf Community: "Pulling Passwords from Keychain with Script"](https://community.jamf.com/t5/jamf-pro/pulling-passwords-from-keychain-with-script/m-p/77624)
- Mesmo nesse fluxo, "to avoid prompts, an ACL naming the runtime binary is needed so reads don't prompt" / usar `-T /usr/bin/security` para conceder acesso confiável a um binário específico no momento da criação do item — ou seja, o "sem prompt" só funciona para o criador original do item (ou quem ele explicitamente autorizar), reforçando que o modelo de ACL por assinatura se aplica igualmente dentro do System Keychain. — [scriptingosx.com: "Get Password from Keychain in Shell Scripts"](https://scriptingosx.com/2021/04/get-password-from-keychain-in-shell-scripts/)
- Sobre certificados de confiança no System Keychain: "In macOS Big Sur 11 and later... Running as the root user alone is no longer sufficient to modify certificate trust" para trust settings — indicando que a Apple vem **restringindo**, não ampliando, privilégios de root sobre o System Keychain em versões modernas. — [derflounder.wordpress.com / discussão relacionada](https://discussions.apple.com/thread/253433465)

### Inferences
- A "vantagem" do System Keychain para root é apenas de nível de arquivo (permissão Unix para abrir o keychain file), não uma isenção da camada de ACL por assinatura de código da Security framework — as duas camadas (acesso ao arquivo do keychain vs. ACL do item individual) são independentes, e a segunda continua vigente no System Keychain.
- Como o item em questão é criado por um CLI de terceiros, mesmo migrando-o fisicamente para o System Keychain, o seu processo (ClaudeS) continuaria sem estar na trusted-application list daquele item específico — o prompt reapareceria, só que agora potencialmente pedindo autenticação de administrador em vez de senha de usuário, dependendo da configuração.

### Gaps
- Não foi encontrada documentação Apple confirmando se o System Keychain, por padrão, ainda dispara o prompt "App X deseja usar a chave..." para itens individuais da mesma forma que o login keychain, ou se o comportamento de prompt para o System Keychain é estritamente desabilitado fora de sessão de UI (os daemons sem sessão geralmente falham com "user interaction not allowed" em vez de prompt). Essa distinção exata (prompt vs. falha silenciosa) não foi confirmada com uma fonte primária única.

---

## "unlock-keychain" e "security -i" (modo interativo) rodando como root mudam alguma coisa?

### Takeaway
Nenhum dos dois contorna o modelo de ACL por assinatura de código. `security unlock-keychain` apenas desbloqueia o keychain (equivalente a inserir a senha de login), o que é um pré-requisito necessário mas **não suficiente** — itens individuais ainda têm suas próprias ACLs por item que exigem prompt se o processo requisitante não estiver na trusted-application list. `security -i` é apenas um modo de execução de comandos (evita expor senha em argv/histórico), sem qualquer efeito sobre avaliação de ACL. Classificação: **INVIÁVEL**.

### Cited Findings
- "This doesn't bypass macOS Keychain security, but rather just prompts you once per SSH session, the same as if you'd unlocked it locally." — sobre `security unlock-keychain` via SSH/scripts. — [MacInCloud Support: "How to Unlock Mac Keychain through the Command Line"](https://support.macincloud.com/support/solutions/articles/8000089857-how-to-unlock-mac-keychain-through-the-command-line)
- `security -i` "puts security into an interactive mode: it reads commands from stdin, one per line, and dispatches them in-process. No fork, no exec, no new process whose argv includes the password" — ou seja, é uma proteção contra exposição de credenciais em `ps`/histórico de shell, não um mecanismo de autorização adicional. — [keith.github.io: security(1) man page](https://keith.github.io/xcode-man-pages/security.1.html)
- Há discussão de uso de `sudo security authorizationdb write com.apple.trust-settings.admin allow` para contornar prompts **de trust settings de certificados** especificamente (não itens genéricos do keychain) — e mesmo esse mecanismo foi restringido pela Apple a partir do Big Sur, exigindo senha de administrador independentemente de rodar como root. — resultado de busca relacionado; ver seção System Keychain acima.

### Inferences
- Desbloquear o keychain (unlock-keychain) resolve apenas o estado "locked/unlocked" do keychain como um todo; a ACL por item (quem pode ler aquela entrada específica sem prompt) é avaliada em uma camada separada e posterior, independentemente de quem desbloqueou o keychain ou com qual UID.

### Gaps
- Nenhuma fonte aborda diretamente "root + `security -i`" como combinação específica; a conclusão é inferida da documentação do comando `-i` em si (que não menciona qualquer interação com UID/root) combinada com o entendimento geral do modelo de ACL por assinatura.

---

## Accessibility/TCC, Automação, Full Disk Access afetam a avaliação de ACL do Keychain? Há overlap, incluindo o caminho "clicar Allow via Accessibility"?

### Takeaway
TCC (Accessibility, Automação/Apple Events, Full Disk Access) é um **sistema de permissão totalmente independente** do modelo de ACL do Keychain Services — não há overlap na decisão de ACL em si. Porém, existe uma via indireta e tecnicamente possível, já documentada por pesquisadores de segurança (Patrick Wardle): usar **Accessibility para gerar cliques sintéticos** que pressionam o botão "Always Allow" do diálogo do SecurityAgent — isto não altera a ACL de forma "oficial", apenas automatiza a resposta humana ao prompt, e historicamente dependeu de falhas (eventos sintéticos não filtrados) que a Apple já mitigou parcialmente. Classificação do overlap formal: **INVIÁVEL**. Classificação do caminho "clique sintético via Accessibility": **PARCIALMENTE VIÁVEL** (tecnicamente possível, mas gambiarra, frágil, dependente de versão do macOS, e eticamente/architeturalmente desaconselhável — não é uma solução elegante nem seu objetivo original).

### Cited Findings
- "Keychain access and Full Disk Access are separate services - granting Full Disk Access does not cover keychain access." — [TCC overview / pesquisa consolidada, confirmado por HackTricks e análises de TCC.db] — [HackTricks: macOS TCC Credential & Data Theft](https://hacktricks.wiki/en/macos-hardening/macos-security-and-privilege-escalation/macos-security-protections/macos-tcc/macos-tcc-credential-and-data-theft.html)
- Listas completas de `kTCCService*` (kTCCServiceAccessibility, kTCCServiceAppleEvents, kTCCServiceSystemPolicyAllFiles para Full Disk Access, etc.) não incluem nenhum serviço equivalente a "Keychain ACL" — confirmando que a decisão de "Permitir Sempre" do Keychain não passa pelo banco TCC.db. — [Rainforest QA: "A deep dive into macOS TCC.db"](https://www.rainforestqa.com/blog/macos-tcc-db-deep-dive)
- Patrick Wardle (pesquisador, ex-NSA, Objective-See) demonstrou que "macOS accessibility features include the ability to make mouse-clicks without actually touching the mouse through software" e que isso pôde ser abusado por malware para clicar automaticamente em prompts de segurança, incluindo diálogos de autorização — "an unpatched flaw can be exploited to virtually click objects and gain access to password protected areas." — [Speaker Deck: "The Mouse is Mightier than the Sword" — Patrick Wardle](https://speakerdeck.com/patrickwardle/the-mouse-is-mightier-than-the-sword); [Tom's Guide: "Hackers Can Hijack Macs with Fake Mouse Clicks"](https://www.tomsguide.com/us/mac-mouse-hack-defcon26,news-27796.html)
- Receita técnica documentada por usuários (fórum Keyboard Maestro) para automatizar o clique no botão do diálogo do Keychain via System Events/Accessibility, direcionando o processo `SecurityAgent`: `tell window 1 of process "SecurityAgent" to click button "Always Allow" of group 1` — confirma que a via é tecnicamente viável hoje via AppleScript + Accessibility, desde que o processo automatizador tenha a permissão de Accessibility concedida pelo usuário. — [Keyboard Maestro Forum: "Pressing the 'Always Allow' button on Keychain permission dialogs"](https://forum.keyboardmaestro.com/t/pressing-the-always-allow-button-on-keychain-permission-dialogs/26903)
- "Apple Events and Accessibility are distinct TCC services and generally require their respective user approvals. Once the user clicks Allow, future requests from the same source to the same target are allowed until the entry is reset." — confirma que mesmo essa via de automação **ainda exige que o usuário aprove manualmente** a permissão de Accessibility/Apple Events uma vez (não é bypass total e silencioso do zero — há um prompt de TCC antes, e depois automatiza prompts subsequentes do Keychain). — [resultado consolidado de pesquisa sobre AppleScript e TCC]

### Inferences
- O caminho "Accessibility clica em Allow" não elimina o prompt do Keychain — ele o substitui por um prompt de TCC (Accessibility) que precisa ser aprovado manualmente uma vez, e depois automatiza a resposta ao prompt do Keychain daí em diante. Ou seja, transforma N prompts manuais de Keychain em 1 prompt manual de Accessibility + cliques automatizados — não é um "bypass" no sentido de eliminar toda a fricção de autorização do usuário, apenas a desloca e a reduz para uma única aprovação.
- Esse caminho é frágil estruturalmente: depende de nomes de janela/processo do SecurityAgent (que a Apple pode alterar entre versões do macOS), exige lidar com timing de diálogo assíncrono, e replica exatamente a técnica usada por pesquisadores de segurança para descrever "ataques" de malware — é uma escolha de risco reputacional e de manutenção alta para um produto legítimo.

### Gaps
- Não foi possível confirmar se, no macOS Sequoia/Sonoma atual (2024-2026), a Apple adicionou proteções adicionais (ex.: exigir atenção humana real / "Pointer events" vs. CGEvent sintético) que invalidariam esse clique automatizado especificamente para diálogos do SecurityAgent — a pesquisa de Wardle é majoritariamente de 2017-2019 (synthetic click bugs que foram parcialmente corrigidos). Recomenda-se validação empírica direta antes de depender dessa técnica em produção.

---

## Rodar um app GUI inteiro como root no macOS moderno é suportado/recomendado pela Apple, ou há restrições técnicas que praticamente impedem isso?

### Takeaway
Não é suportado. A Apple confirma formal e repetidamente (DTS, via fóruns oficiais) que **rodar um app GUI como root nunca foi suportado**, e recomenda isolar apenas as operações privilegiadas em um processo separado (daemon/helper) rodando como root, mantendo a GUI com privilégios normais de usuário. Classificação: **INVIÁVEL** (não suportado oficialmente) para a abordagem de "app GUI inteiro como root"; a abordagem suportada é a separação helper-root / GUI-usuário.

### Cited Findings
- "Running GUI apps as root has never been supported... Apple recommends that you factor the privileged operations out of your GUI app into a separate program and run just that program as root." — atribuído a Quinn "The Eskimo!" (DTS da Apple) em thread do fórum oficial sobre Ventura. — [Apple Developer Forums: "Ventura OS: Cannot run app with admin privilege" (708295)](https://developer.apple.com/forums/thread/708295)
- "There's no supported way to run an app as root, where app is defined as something with a GUI that the user launches from the Finder" — confirmação adicional de engenheiro de DTS da Apple em outra thread. — [Apple Developer Forums (consolidado de busca sobre o tema)](https://developer.apple.com/forums/thread/772674)
- Restrições técnicas adicionais em versões recentes: "After upgrading to macOS Sequoia, LaunchDaemons no longer work for certain operations like screen recording, and only work when using a LaunchAgent instead" — indicando que a Apple está progressivamente restringindo o que processos root/LaunchDaemon podem fazer em relação a sessões de UI/TCC, não ampliando. — [Apple Developer Forums: "Problems with macOS apps launching since Sequoia 15.1 (spawn constraints failure)"](https://developer.apple.com/forums/thread/767509)
- Recomendação arquitetural padrão da Apple referenciada: fatorar lógica privilegiada para um helper tool separado (historicamente via `SMJobBless`, atualmente via `SMAppService`/`SMPrivilegedExecutable`), nunca executar a superfície de UI como root. — [Apple Developer Forums: "Privileged daemon using SMAppService in macOS Sequoia" (756846)](https://developer.apple.com/forums/thread/756846)

### Inferences
- Mesmo que fosse possível tecnicamente (via `sudo open -a AppName` ou truques similares), a recomendação e a tendência de hardening da Apple (TCC cada vez mais estrito por sessão, LaunchServices e LaunchDaemons com cada vez menos poder sobre sessões de UI em Sequoia) tornam essa abordagem cada vez mais instável e sujeita a quebra em futuras atualizações do macOS — não é uma base arquitetural sólida para um produto de longo prazo.
- Essa restrição é coerente com e reforça a conclusão da primeira pergunta: mesmo que você conseguisse rodar a GUI como root, isso não mudaria a avaliação de ACL do Keychain (que é por assinatura de código, não por UID) — então o esforço de rodar como root não traria o benefício desejado mesmo se fosse tecnicamente viável.

### Gaps
- Não foi encontrada uma Technical Note numerada atual (ex. substituto do TN2083) que trate exatamente desse tema para Ventura/Sonoma/Sequoia; as citações disponíveis são respostas de DTS em fóruns, que são autoritativas mas não um documento de referência único e estável.

---

## Conclusão consolidada (síntese entre as seções acima)

Nenhum dos caminhos investigados — rodar como root/sudo, LaunchDaemon privilegiado, migrar para o System Keychain, `unlock-keychain`/`security -i`, ou explorar Accessibility/TCC — elimina de forma legítima e sustentável o prompt nativo "App X deseja acessar a chave...". A causa raiz é arquitetural: o Keychain Services do macOS amarra suas ACLs à **identidade de assinatura de código (Designated Requirement/CDHash) do processo requisitante**, uma camada que é ortogonal ao UID Unix e ao sistema TCC. O único caminho tecnicamente funcional encontrado (clique sintético via Accessibility no diálogo do SecurityAgent) não é um bypass da ACL — é automação da resposta humana ao prompt, exige uma aprovação manual prévia de Accessibility, é frágil entre versões do macOS, e replica uma técnica historicamente associada a malware (Patrick Wardle/Objective-See), o que a torna inadequada como solução de produto.

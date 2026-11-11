# ADR 0002: Arquitetura em camadas, validação no boot, erros enumerados e leitura passiva

- **Status:** Aceito
- **Data:** 2026-11-10

## Contexto

O código herdado concentrava interface `SwiftUI`, estado global, chamadas a processos externos, manipulação de pseudo-terminal, leitura de arquivos do usuário e tratamento de erros por concatenação de texto em arquivos monolíticos na raiz. Isso dificultava testes determinísticos, permitia vazamento de saídas brutas de terminal para a interface e misturava regras de negócio com infraestrutura de sistema operacional.

## Decisão

1. **Organização por funcionalidade e camadas (`Domain` -> `Application` -> `Adapters`):**
   - `BrainPanel/Modules/Quotas/`, `BrainPanel/Modules/Sessions/` e `BrainPanel/Modules/Brain/` são módulos independentes sem importação cruzada entre si e separam:
     - `Domain/`: entidades, cálculos de janela/contexto, avaliadores operacionais do Brain e parsers puros (`ProviderUsage.swift`, `ClaudeUsageParser.swift`, `GeminiQuotaParser.swift`, `ActiveConversation.swift`, `SessionTranscriptParsers.swift`, `BrainSnapshot.swift`, `BrainWaitingEvaluator.swift`, `BrainCIQueueEvaluator.swift`, `BrainHealthAndBackupEvaluator.swift`, `BrainScheduledJobsEvaluator.swift`), importando apenas `Foundation` e módulos puros de `BrainPanel/Shared/` (`Clock`, `Errors`, `TerminalText`, `TerminalScreen`), sem `SwiftUI`, `AppKit`, `Darwin`, `OSLog`, `Observation` ou `SQLite3`.
     - `Application/`: portas e redutores de caso de uso (`UsageCollector.swift`, `ConversationCollecting.swift`, `BrainStateCollecting.swift`), desacoplados de UI e de syscalls.
     - `Adapters/`: coletores concretos de processo/sistema de arquivos (`ClaudeCollector.swift`, `GeminiCollector.swift`, `ActiveConversationCollector.swift`, `BrainStateCollector.swift`, `LaunchctlRunning.swift`) e componentes `SwiftUI` pequenos em `Adapters/Views/`.
   - `BrainPanel/App/` faz exclusivamente a composição raiz (`BrainPanelApp.swift`, `UsageStore.swift`, `MenuBarPresentation.swift`, `MenuTabBar.swift`, `ContentView.swift`), combinando os estados dos três módulos no rótulo inteligente da barra de menus e cancelando a tarefa periódica de atualização quando `UsageStore` é desalocado.
   - As fronteiras e o desacoplamento entre módulos são verificados automaticamente por `BrainPanelTests/Unit/ArchitectureTests.swift` e `scripts/check-docs`.

2. **Fronteiras de ambiente e relógio únicas (`Shared/Config` e `Shared/Clock`):**
   - `BrainPanel/Shared/Config/AppConfig.swift` é o único ponto autorizado a ler `ProcessInfo.processInfo.environment`. Variáveis `BRAIN_PANEL_*` desconhecidas, caminhos relativos, URLs fora de loopback em `BRAIN_PANEL_BRAIN_PAGES_URL` ou intervalos fora dos limites falham fechado no boot antes de abrir a interface.
   - `BrainPanel/Shared/Clock/Clock.swift` é o único ponto autorizado a ler `Date()` / `Date.now`, e `BrainPanel/Shared/Clock/RelativeTimeFormatter.swift` centraliza a formatação pura de tempo relativo compartilhada pelos três módulos. `UsageStore` e os parsers/avaliadores recebem `any Clock`, permitindo testes determinísticos de expiração de cache e janelas sem `sleep`.
   - `scripts/check-swift` bloqueia leituras diretas de ambiente ou relógio fora de `Shared/Config/AppConfig.swift` e `Shared/Clock/Clock.swift`, além de `try!`, force unwrap sem justificativa e blocos `catch` vazios.

3. **Erros enumerados, falha parcial isolada e observabilidade sem vazamento (`Shared/Errors` e `Shared/Logging`):**
   - `BrainPanel/Shared/Errors/AppError.swift` define `AppErrorCode` (códigos estáveis enumerados, incluindo `BRAIN_STATE_READ_FAILED` parametrizado por `KnownBrainSection`) e `ErrorHandler`, convertendo qualquer falha inesperada em `AppError` com mensagem segura ao usuário, sem exibir caminhos privados, tokens ou saídas brutas de terminal.
   - `BrainPanel/Shared/Logging/StructuredLogger.swift` emite linhas JSON estruturadas com `refresh_id` e chaves permitidas por `LogFieldKey`, sanitizando valores livres em `LogSanitizer`. `BrainPanelTests/Unit/SecurityCanaryTests.swift` verifica com canários que entradas sensíveis, corpos de `brain-mail` e campos corporativos (`flexograv`) não vazam em erros nem em logs.

4. **Operação estritamente somente-leitura:**
   - Os coletores de cota inspecionam apenas os comandos locais de status (`/usage` no `claude` e `/quota` no `agy`) em pseudo-terminal controlado (`BrainPanel/Shared/Terminal/PseudoTerminalSession.swift`, com escrita completa em loop tratando escrita parcial/`EINTR` e encerramento garantido escalando `SIGTERM` para `SIGKILL`), sem autenticar contas, sem enviar prompts a modelos e sem gastar tokens.
   - O coletor de sessões verifica existência de processo (`kill(pid, 0)`) para o Claude Code, filtra transcripts recentes do Antigravity pelo `Clock` injetado, lê no máximo os últimos 4 MB de cada `.jsonl` configurado e consulta `conversation_summaries.db` exclusivamente com `SQLITE_OPEN_READONLY` e `immutable=1` (sem criar arquivos `-wal` ou `-shm`).
   - O coletor do ecossistema Brain (`BrainStateCollector`) lê os quatro blocos (`waiting`, `ciQueue`, `healthAndBackup` e `scheduledJobs`) de forma independente com falha parcial isolada (`BrainSectionState`), ignora arquivos `.json`/`.plist` individuais malformados sem derrubar o bloco, omite a decodificação de `text` em `brain-mail`, mascara o escopo corporativo `flexograv` e consulta `launchctl list` por `ProcessLaunchctlRunner` sem shell, em grupo de processos próprio, com timeout estrito (`<= 3 s`) e encerramento `SIGTERM` -> `SIGKILL`.

## Consequências

- Regras de cálculo, avaliação operacional e parsing são testáveis em milissegundos sobre fixtures sanitizadas (`BrainPanelTests/Fixtures/BrainState/`) e cobertas por mutação (`make mutation`) sem abrir processos reais nem tocar arquivos do usuário.
- Cada domínio funcional (`Quotas`, `Sessions` e `Brain`) evolui isoladamente em `BrainPanel/Modules/`, respeitando as mesmas fronteiras e travas automatizadas.

# ADR 0002: Arquitetura em camadas, validação no boot, erros enumerados e leitura passiva

- **Status:** Aceito
- **Data:** 2026-11-10

## Contexto

O código herdado concentrava interface `SwiftUI`, estado global, chamadas a processos externos, manipulação de pseudo-terminal, leitura de arquivos do usuário e tratamento de erros por concatenação de texto em arquivos monolíticos na raiz. Isso dificultava testes determinísticos, permitia vazamento de saídas brutas de terminal para a interface e misturava regras de negócio com infraestrutura de sistema operacional.

## Decisão

1. **Organização por funcionalidade e camadas (`Domain` -> `Application` -> `Adapters`):**
   - `BrainPanel/Modules/Quotas/` e `BrainPanel/Modules/Sessions/` separam:
     - `Domain/`: entidades, cálculos de janela/contexto e parsers puros (`ProviderUsage.swift`, `ClaudeUsageParser.swift`, `GeminiQuotaParser.swift`, `ActiveConversation.swift`), importando apenas `Foundation` e módulos puros de `BrainPanel/Shared/` (`Clock`, `Errors`, `TerminalText`, `TerminalScreen`), sem `SwiftUI`, `AppKit`, `Darwin` ou `Observation`.
     - `Application/`: portas e redutores de caso de uso (`UsageCollector.swift`, `ConversationCollecting.swift`), desacoplados de UI e de syscalls.
     - `Adapters/`: coletores concretos de processo/sistema de arquivos (`ClaudeCollector.swift`, `GeminiCollector.swift`, `ActiveConversationCollector.swift`) e componentes `SwiftUI` pequenos em `Adapters/Views/`.
   - `BrainPanel/App/` faz exclusivamente a composição raiz (`BrainPanelApp.swift`, `UsageStore.swift`, `MenuTabBar.swift`, `ContentView.swift`), cancelando a tarefa periódica de atualização quando `UsageStore` é desalocado.
   - As fronteiras são verificadas automaticamente por `BrainPanelTests/Unit/ArchitectureTests.swift` e `scripts/check-docs`.

2. **Fronteiras de ambiente e relógio únicas (`Shared/Config` e `Shared/Clock`):**
   - `BrainPanel/Shared/Config/AppConfig.swift` é o único ponto autorizado a ler `ProcessInfo.processInfo.environment`. Variáveis `BRAIN_PANEL_*` desconhecidas, caminhos relativos ou intervalos fora dos limites falham fechado no boot antes de abrir a interface.
   - `BrainPanel/Shared/Clock/Clock.swift` é o único ponto autorizado a ler `Date()` / `Date.now`. `UsageStore` e os parsers recebem `any Clock`, permitindo testes determinísticos de expiração de cache e janelas sem `sleep`.
   - `scripts/check-swift` bloqueia leituras diretas de ambiente ou relógio fora desses dois arquivos, além de `try!`, force unwrap sem justificativa e blocos `catch` vazios.

3. **Erros enumerados e observabilidade sem vazamento (`Shared/Errors` e `Shared/Logging`):**
   - `BrainPanel/Shared/Errors/AppError.swift` define `AppErrorCode` (códigos estáveis enumerados) e `ErrorHandler`, convertendo qualquer falha inesperada em `AppError` com mensagem segura ao usuário, sem exibir caminhos privados, tokens ou saídas brutas de terminal.
   - `BrainPanel/Shared/Logging/StructuredLogger.swift` emite linhas JSON estruturadas com `refresh_id` e chaves permitidas por `LogFieldKey`, sanitizando valores livres em `LogSanitizer`. `BrainPanelTests/Unit/SecurityCanaryTests.swift` verifica com canários que entradas sensíveis não vazam em erros nem em logs.

4. **Operação estritamente somente-leitura:**
   - Os coletores de cota inspecionam apenas os comandos locais de status (`/usage` no `claude` e `/quota` no `agy`) em pseudo-terminal controlado (`BrainPanel/Shared/Terminal/PseudoTerminalSession.swift`, com escrita completa em loop tratando escrita parcial e `EINTR`), sem autenticar contas, sem enviar prompts a modelos e sem gastar tokens.
   - O coletor de sessões verifica existência de processo (`kill(pid, 0)`) e lê no máximo o trecho final dos arquivos `.jsonl` configurados em modo somente-leitura.

## Consequências

- Regras de cálculo e parsing são testáveis em milissegundos e cobertas por mutação (`make mutation`) sem abrir processos nem tocar arquivos do usuário.
- Qualquer nova funcionalidade (como a futura aba do ecossistema Brain) entra como módulo próprio em `BrainPanel/Modules/`, respeitando as mesmas fronteiras e travas automatizadas.

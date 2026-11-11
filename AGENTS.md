# Brain Panel — Regras do Projeto

Aplicativo nativo de barra de menus para macOS (`Brain Panel.app`, `com.h3zord.BrainPanel`) para acompanhamento em tempo real das cotas de uso das CLIs locais (`claude` e `agy`) e do contexto das conversas ativas do Claude Code, operando em modo estritamente somente-leitura e sem consumir tokens.

- **Plano do projeto:** [#1 — Brain Panel](https://github.com/h3zord/projeto-painel/issues/1)
- **Metodologia verificada:** `dev-methodology: 8267b37`

## Alvos do Makefile

| Alvo | O que executa |
| --- | --- |
| `make up` / `make down` | Compila em Debug (em `local/tmp/dev-derived-data`) e inicia ou encerra o `Brain Panel.app` de desenvolvimento |
| `make test` | Roda os testes unitários isolados (`BrainPanelUnitTests`) com timeout por teste e zero repetições |
| `make check` | Portão rápido do `scripts/hooks/pre-push`: `make ci-portable`, lint/formato (`xcrun swift-format`) e `make test` |
| `make ci-portable` | Travas portáveis (Linux e macOS): `scripts/check-gates`, `scripts/check-swift`, `scripts/check-docs` e `scripts/run-gitleaks` (com `scripts/gitleaks-gates/test`) |
| `make ci` | Portão completo nativo: `make check`, testes de integração (`BrainPanelIntegrationTests`), build Release e `scripts/smoke-app` |
| `make mutation` | Teste de mutação no domínio crítico via `scripts/run-mutation` sobre cópia isolada em `local/tmp/` |
| `make format` | Formata `BrainPanel/` e `BrainPanelTests/` com `.swift-format` |
| `make hooks` | Configura `core.hooksPath` para `scripts/hooks` e aplica permissões executáveis |
| `make clean` | Limpa artefatos temporários em `local/tmp/` |

## Regras próprias deste repositório

- **Fila obrigatória para portões pesados:** `make ci` e `make mutation` rodam exclusivamente via `~/Brain/bin/brain-ci run -- make ci` e `~/Brain/bin/brain-ci run -- make mutation`.
- **Isolamento total em testes e CI:** `make test`, `make check`, `make ci` e `make mutation` nunca invocam `claude`, `agy` ou `launchctl` reais, nunca leem `~/.claude` ou `~/.local/state` reais e nunca escrevem em `/Applications` ou `~/Library/LaunchAgents`.
- **Artefatos temporários:** todo `DerivedData`, bundle de teste e diretório temporário mora dentro de `local/tmp/`.
- **Repositório público (`h3zord/projeto-painel`):** proibido incluir segredos, e-mails pessoais, caminhos privados reais da máquina ou capturas brutas com dados sensíveis em código, fixtures, logs ou documentação.
- **Adaptação de plataforma e arquitetura:** registradas em `docs/adr/0001-plataforma-macos-e-ci.md` e `docs/adr/0002-arquitetura-camadas-erros-e-fronteiras.md`.
- **Compactação:** ao retomar após compactação automática, preservar papel da sessão (`painel-lead` ou `painel-dev`), issue/PR ativo, commit verificado na fila e próximo passo imediato.

## Invariantes do domínio e testes que as garantem

- **Cotas, menor disponibilidade e janelas de renovação:** `BrainPanelTests/Unit/ProviderUsageTests.swift`
- **Parsing somente-leitura das telas `/usage` e `/quota`:** `BrainPanelTests/Unit/ClaudeUsageParserTests.swift` e `BrainPanelTests/Unit/GeminiQuotaParserTests.swift`
- **Limpeza ANSI/VT100 e tela virtual de terminal:** `BrainPanelTests/Unit/TerminalTextAndScreenTests.swift`
- **Estado de conversas ativas, limiares de contexto e extração de transcript JSONL:** `BrainPanelTests/Unit/ActiveConversationDomainTests.swift` e `BrainPanelTests/Integration/ActiveConversationCollectorIntegrationTests.swift`
- **Cache por relógio injetado, preservação da última leitura válida em erro, concorrência e cancelamento no `deinit`:** `BrainPanelTests/Unit/UsageStoreTests.swift`
- **Configuração validada no boot (fail-closed) e códigos de erro enumerados:** `BrainPanelTests/Unit/AppConfigAndErrorTests.swift`
- **Não vazamento de dados sensíveis em erros ou logs estruturados (canário):** `BrainPanelTests/Unit/SecurityCanaryTests.swift`
- **Escrita integral em pseudo-terminal sob escrita parcial e interrupções:** `BrainPanelTests/Integration/PseudoTerminalSessionIntegrationTests.swift`
- **Fronteiras de camadas (`Domain` -> `Application` -> `Adapters`) e integridade documental:** `BrainPanelTests/Unit/ArchitectureTests.swift` e `BrainPanelTests/Unit/DocumentationIntegrityTests.swift`

## Onde está o quê

- `BrainPanel/Modules/Quotas/` — módulo de cotas (`Domain`, `Application`, `Adapters` e views)
- `BrainPanel/Modules/Sessions/` — módulo de sessões ativas (`Domain`, `Application`, `Adapters` e views)
- `BrainPanel/Shared/` — utilitários transversais (`Config`, `Clock`, `Errors`, `Logging`, `Terminal`)
- `BrainPanel/App/` — composição raiz (`BrainPanelApp.swift`, `UsageStore.swift`, `MenuTabBar.swift`, `ContentView.swift`)
- `BrainPanel.xcodeproj` — projeto Xcode macOS (`BrainPanel`, `BrainPanelUnitTests`, `BrainPanelIntegrationTests`)
- `BrainPanelTests/` — suítes `Unit/` e `Integration/`
- `docs/adr/` — registros de decisão arquitetural
- `scripts/` — verificadores de portões, travas estáticas de Swift com provas, smoke test, mutação e hooks
- `local/` — diretórios locais ignorados pelo git (`tmp/`, `worktrees/`, `data/`, `private/`)

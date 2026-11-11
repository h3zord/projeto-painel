# Brain Panel — Regras do Projeto

Aplicativo nativo de barra de menus para macOS (`Brain Panel.app`, `com.h3zord.BrainPanel`) para acompanhamento em tempo real das cotas de uso das CLIs locais (`claude` e `agy`), do contexto das conversas ativas do Claude Code e do Antigravity e do estado operacional do ecossistema Brain, com alertas nativos discretos do macOS e operação estritamente somente-leitura sem consumir tokens.

- **Plano do projeto:** [#1 — Brain Panel](https://github.com/h3zord/projeto-painel/issues/1)
- **Metodologia verificada:** `dev-methodology: 8267b37`

## Alvos do Makefile

| Alvo | O que executa |
| --- | --- |
| `make up` / `make down` | Compila em Debug (em `local/tmp/dev-derived-data`) e inicia ou encerra o `Brain Panel.app` de desenvolvimento |
| `make install-local` | Compila em Release, valida com `scripts/smoke-app`, instala em `/Applications/Brain Panel.app` via `scripts/install-local` e remove eventual `/Applications/AI Usage Menu.app` provisório |
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
- **Isolamento total em testes e CI:** `make test`, `make check`, `make ci` e `make mutation` nunca invocam `claude`, `agy` ou `launchctl` reais, nunca acionam `UNUserNotificationCenter.current()`, nunca leem `~/.claude`, `~/.cache`, `~/.gemini`, `~/.local/state`, `~/Library/Logs`, `~/Library/LaunchAgents` ou `~/Brain` reais e nunca escrevem em `/Applications` ou `~/Library/LaunchAgents`.
- **Artefatos temporários:** todo `DerivedData`, bundle de teste e diretório temporário mora dentro de `local/tmp/`.
- **Repositório público (`h3zord/projeto-painel`):** proibido incluir segredos, e-mails pessoais, caminhos privados reais da máquina ou capturas brutas com dados sensíveis em código, fixtures, logs ou documentação.
- **Adaptação de plataforma e arquitetura:** registradas em `docs/adr/0001-plataforma-macos-e-ci.md` e `docs/adr/0002-arquitetura-camadas-erros-e-fronteiras.md`.
- **Compactação:** ao retomar após compactação automática, preservar papel da sessão (`painel-lead` ou `painel-dev`), issue/PR ativo, commit verificado na fila e próximo passo imediato.

## Invariantes do domínio e testes que as garantem

- **Cotas, menor disponibilidade, estado defasado (`stale`) e janelas de renovação:** `BrainPanelTests/Unit/ProviderUsageTests.swift`
- **Parsing somente-leitura das telas `/usage` e `/quota` (com grupos dinâmicos):** `BrainPanelTests/Unit/ClaudeUsageParserTests.swift` e `BrainPanelTests/Unit/GeminiQuotaParserTests.swift`
- **Limpeza ANSI/VT100 e tela virtual de terminal:** `BrainPanelTests/Unit/TerminalTextAndScreenTests.swift`
- **Estado de conversas ativas, compactação (`compact_boundary`/`CHECKPOINT`), limiares percentuais de contexto (`70%`/`80%`) e extração de transcript JSONL:** `BrainPanelTests/Unit/ActiveConversationDomainTests.swift` e `BrainPanelTests/Integration/ActiveConversationCollectorIntegrationTests.swift`
- **Estado operacional do Brain (4 blocos, falha parcial isolada, mascaramento `flexograv`, cabeçalhos `brain-mail` sem corpo, resolução segura de destinos `brain-pages` e timeout de `launchctl`):** `BrainPanelTests/Unit/BrainDomainTests.swift` e `BrainPanelTests/Integration/BrainStateCollectorIntegrationTests.swift`
- **Política pura de alertas nativos discretos (`< 15%`, espera do dono com mascaramento `flexograv`, `brain-doctor` e `brain-backup`), cooldown/rearme por incidente e adaptador silencioso `UNUserNotificationCenter`:** `BrainPanelTests/Unit/NotificationPolicyAndAdapterTests.swift`
- **Cache por relógio injetado, rótulo inteligente da barra de menus, transição para leitura defasada (`stale`) ou diagnóstico de sessões em erro, despacho de alertas discretos, concorrência e cancelamento no `deinit`:** `BrainPanelTests/Unit/UsageStoreTests.swift`
- **Configuração validada no boot (fail-closed, incluindo `BRAIN_PANEL_NOTIFICATIONS_ENABLED` e subcaminhos/fragmentos seguros loopback em `BRAIN_PANEL_BRAIN_PAGES_URL`) e códigos de erro enumerados:** `BrainPanelTests/Unit/AppConfigAndErrorTests.swift`
- **Não vazamento de dados sensíveis em erros ou logs estruturados (canário):** `BrainPanelTests/Unit/SecurityCanaryTests.swift`
- **Escrita integral e encerramento garantido (`SIGTERM` -> `SIGKILL`) em pseudo-terminal:** `BrainPanelTests/Integration/PseudoTerminalSessionIntegrationTests.swift`
- **Instalação local segura, remoção seletiva de legado e preservação de apps vizinhos (`scripts/install-local`):** `BrainPanelTests/Integration/InstallLocalScriptIntegrationTests.swift`
- **Fronteiras de camadas (`Domain` -> `Application` -> `Adapters`), isolamento entre módulos e integridade documental:** `BrainPanelTests/Unit/ArchitectureTests.swift` e `BrainPanelTests/Unit/DocumentationIntegrityTests.swift`

## Onde está o quê

- `BrainPanel/Modules/Quotas/` — módulo de cotas (`Domain`, `Application`, `Adapters` e views)
- `BrainPanel/Modules/Sessions/` — módulo de sessões ativas (`Domain`, `Application`, `Adapters` e views)
- `BrainPanel/Modules/Brain/` — módulo nativo do ecossistema Brain (`Domain`, `Application`, `Adapters` somente-leitura e views da aba `Brain`)
- `BrainPanel/Modules/Notifications/` — módulo de alertas nativos discretos do macOS (`Domain`, `Application` e `Adapters` com `UNUserNotificationCenter`)
- `BrainPanel/Shared/` — utilitários transversais (`Config`, `Clock`, `Errors`, `Logging`, `Terminal`)
- `BrainPanel/App/` — composição raiz (`BrainPanelApp.swift`, `UsageStore.swift`, `NotificationSnapshotBridge.swift`, `MenuBarPresentation.swift`, `MenuTabBar.swift`, `ContentView.swift`)
- `BrainPanel.xcodeproj` — projeto Xcode macOS (`BrainPanel`, `BrainPanelUnitTests`, `BrainPanelIntegrationTests`)
- `BrainPanelTests/` — suítes `Unit/`, `Integration/` e contratos sanitizados em `BrainPanelTests/Fixtures/BrainState/`
- `docs/adr/` — registros de decisão arquitetural
- `scripts/` — verificadores de portões, travas estáticas de Swift com provas, smoke test, mutação e hooks
- `local/` — diretórios locais ignorados pelo git (`tmp/`, `worktrees/`, `data/`, `private/`)

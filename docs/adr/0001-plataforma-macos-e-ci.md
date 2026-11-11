# ADR 0001: Plataforma macOS nativa e divisão entre CI completo e portável

- **Status:** Aceito
- **Data:** 2026-11-10

## Contexto

O `Brain Panel` é um aplicativo nativo de barra de menus para macOS construído com `Swift 6`, `SwiftUI` (`MenuBarExtra`) e `AppKit`, empacotado pelo projeto `BrainPanel.xcodeproj` (`com.h3zord.BrainPanel`).

A metodologia padrão prevê a execução integral do `make ci` dentro de containers Linux e a repetição do mesmo comando no GitHub Actions em `ubuntu-latest`. No entanto, o SDK macOS (`SwiftUI`, `AppKit`, `XCTest` para bundles `.app` e `xcrun swift-format` do toolchain Apple) não está disponível em containers Linux. Ao mesmo tempo, runners `macos-latest` no GitHub Actions consomem multiplicador elevado de minutos da conta.

## Decisão

1. **Portão completo nativo na fila local (`make ci`):**
   - `make ci` é o portão único de aprovação de código e roda nativamente em macOS exclusivamente pela fila serializada (`~/Brain/bin/brain-ci run -- make ci`), garantindo registro auditável por commit (`brain-ci green <sha> -- make ci`) antes do push e do merge.
   - `make ci` começa por `make check` (que inclui `make ci-portable`, verificação estrita de `xcrun swift-format` e `make test` com `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`), executa os testes de integração (`BrainPanelIntegrationTests`), compila o bundle `Release` sem tocar em `/Applications` e valida o artefato final via `scripts/smoke-app` em modo `self_check`.
   - O teste de mutação do domínio crítico (`make mutation`, via `scripts/run-mutation`) também roda pela fila (`~/Brain/bin/brain-ci run -- make mutation`) sobre uma cópia temporária em `local/tmp/`, preservando a árvore rastreada intacta.

2. **Subalvo portável em Linux e Docker (`make ci-portable`):**
   - As verificações independentes do SDK macOS são concentradas em `make ci-portable`:
     - `scripts/check-gates` e sua prova `scripts/gates/test`;
     - `scripts/check-swift` e sua prova `scripts/swift-gates/test`;
     - `scripts/check-docs` (integridade de caminhos/alvos em `AGENTS.md`, `README.md` e `docs/adr/`, fronteiras de imports de `Domain`/`Application` e ausência de referências legadas);
     - varredura de segredos no histórico e na árvore de trabalho via `scripts/run-gitleaks` (`zricethezav/gitleaks:v8.30.1` em Docker, com prova em `scripts/gitleaks-gates/test`, compatível com `git worktree` e clones rasos).
   - `.github/workflows/ci.yml` executa `make ci-portable` em `ubuntu-latest` (com `actions/checkout` fixado por SHA de 40 caracteres, `permissions: contents: read` e disparo apenas fora de draft e no push da `main`).

3. **Isolamento de diretórios temporários:**
   - Todos os artefatos de compilação, `DerivedData`, cópias de formatação e diretórios de teste residem sob `local/tmp/` e são removidos em `trap` de `EXIT`, `INT` (`130`) e `TERM` (`143`) preservando o código de saída original.

## Consequências

- Nenhum merge ocorre sem `make ci` completo verde no commit exato registrado na fila local, mantendo compilação `Swift 6`, testes unitários, integração e smoke test obrigatórios.
- O GitHub Actions valida gratuitamente em `ubuntu-latest` os portões estáticos, documentais, arquiteturais e de segredos (`make ci-portable`) sem esgotar a cota de minutos com runners macOS.

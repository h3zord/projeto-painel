# Brain Panel

Aplicativo nativo de barra de menus para macOS (`Brain Panel.app`, `com.h3zord.BrainPanel`) que exibe em tempo real as cotas de uso do **Claude** (`claude`) e do **Gemini / Antigravity** (`agy`), além do contexto das **conversas ativas** do Claude Code.

O aplicativo reutiliza as sessões já autenticadas nas ferramentas de linha de comando locais e inspeciona arquivos locais em modo estritamente somente-leitura — **sem pedir chaves de API, sem enviar prompts e sem gastar tokens**.

> [!IMPORTANT]
> Projeto independente sem afiliação com Anthropic ou Google. Mudanças no formato de saída das CLIs locais podem exigir ajustes nos parsers.

---

## O que o aplicativo mostra

- **Aba Cotas**
  - Disponibilidade da janela de 5 horas e semanal para **Claude** e **Gemini**, com detalhamento por grupo de modelos e tempo restante até a renovação.
  - Menor porcentagem restante visível diretamente no ícone da barra de menus.
  - Resumo rápido das conversas ativas do Claude Code.
- **Aba Sessões**
  - Lista de conversas do Claude Code com processo vivo (`kill -0`), lendo os últimos 3 MB do transcript `.jsonl` correspondente para estimar o tamanho atual do contexto e sinalizar limiares de atenção (300 mil tokens) e compactação (500 mil tokens).

---

## Requisitos

- **macOS 14** ou superior
- **Xcode 26+** (`Swift 6`) para compilar a partir do código-fonte
- **Docker** com a imagem `zricethezav/gitleaks:v8.30.1` para a varredura local de segredos nos portões de qualidade
- Pelo menos uma das CLIs suportadas instalada e autenticada para leitura ao vivo:
  - `claude` (Claude Code)
  - `agy` (Antigravity / Gemini)

Quando `BRAIN_PANEL_CLI_SEARCH_PATHS` não é definida, o app procura os executáveis em `~/.local/bin`, `~/.npm-global/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin` e `/bin`.

---

## Como compilar, rodar e testar

Configure os hooks do repositório após clonar:

```bash
make hooks
```

Comandos principais do `Makefile`:

```bash
make up           # Compila em Debug (local/tmp/dev-derived-data) e abre o Brain Panel.app
make down         # Encerra a instância de desenvolvimento aberta pelo make up
make test         # Roda os testes unitários isolados (BrainPanelUnitTests)
make check        # Portão rápido: travas estáticas, docs, gitleaks, swift-format e testes unitários
make ci-portable  # Subconjunto portável (travas, docs, arquitetura e gitleaks) usado também no GitHub Actions
make format       # Formata o código Swift com xcrun swift-format (.swift-format)
make clean        # Remove artefatos temporários em local/tmp/
```

Para gerar um bundle `Release` isolado em `local/tmp/` pelo terminal (sem modificar `/Applications` automaticamente):

```bash
xcodebuild build \
  -project BrainPanel.xcodeproj \
  -scheme BrainPanel \
  -configuration Release \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath local/tmp/release-build \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
```

O aplicativo compilado ficará em `local/tmp/release-build/Build/Products/Release/Brain Panel.app`. Caso deseje instalá-lo manualmente para uso diário, copie o bundle para `/Applications` e adicione-o em **Ajustes do Sistema → Geral → Itens de Início e Extensões**.

---

## Configuração (`.env.example`)

Toda variável `BRAIN_PANEL_*` é validada de forma estrita na inicialização por `BrainPanel/Shared/Config/AppConfig.swift` (variáveis desconhecidas ou valores fora dos limites encerram o processo com erro explícito). Consulte `.env.example` para a lista completa:

- `BRAIN_PANEL_MODE`: `live` (padrão), `isolated`, `self_check` ou `testing`.
- `BRAIN_PANEL_REFRESH_INTERVAL_SECONDS`: intervalo periódico de atualização de cotas (`10` a `3600`, padrão `300`).
- `BRAIN_PANEL_CACHE_TTL_SECONDS`: tempo máximo de cache ao abrir o painel (`1` a `600`, padrão `60`).
- `BRAIN_PANEL_CLAUDE_SESSIONS_DIR`, `BRAIN_PANEL_CLAUDE_PROJECTS_DIR`, `BRAIN_PANEL_APP_SUPPORT_DIR`, `BRAIN_PANEL_CLI_SEARCH_PATHS`: caminhos absolutos opcionais usados para isolamento ou customização.

---

## Fontes de dados (somente-leitura)

| Fonte | Comando / Arquivo local | Operação |
| --- | --- | --- |
| **Claude (Cota)** | `claude` | Inspeciona `/usage` em pseudo-terminal local e encerra a sessão |
| **Gemini (Cota)** | `agy` | Inspeciona `/quota` em pseudo-terminal local e encerra a sessão |
| **Sessões Ativas** | `~/.claude/sessions/*.json` e `~/.claude/projects/**/*.jsonl` | Confere `pid` ativo e lê o final do `.jsonl` em modo somente-leitura |

---

## Documentação e governança

- Regras e invariantes do repositório: `AGENTS.md`
- Decisões de arquitetura (ADRs):
  - `docs/adr/0001-plataforma-macos-e-ci.md`
  - `docs/adr/0002-arquitetura-camadas-erros-e-fronteiras.md`
- Licença: distribuído sob a [MIT License](LICENSE).

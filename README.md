# Brain Panel

Aplicativo nativo de barra de menus para macOS (`Brain Panel.app`, `com.h3zord.BrainPanel`) que acompanha em tempo real as cotas de uso do **Claude** (`claude`) e do **Gemini / Antigravity** (`agy`), o contexto das **conversas ativas** do Claude Code e do Antigravity e o estado operacional local do ecossistema **Brain** (pendências do dono, fila `brain-ci`, saúde/backup e jobs agendados).

O aplicativo reutiliza as sessões já autenticadas nas ferramentas de linha de comando locais e inspeciona arquivos locais em modo estritamente somente-leitura — **sem pedir chaves de API, sem enviar prompts e sem gastar tokens**.

> [!IMPORTANT]
> Projeto independente sem afiliação com Anthropic ou Google. Mudanças no formato de saída das CLIs locais podem exigir ajustes nos parsers.

---

## O que o aplicativo mostra

- **Aba Cotas**
  - Disponibilidade da janela de 5 horas e semanal para **Claude** e **Gemini**, com detalhamento por grupo de modelos, tempo restante até a renovação e diferenciação visual entre carregamento inicial, leitura defasada (`stale`) e indisponibilidade pós-coleta.
  - Rótulo inteligente na barra de menus combinando a menor cota restante (`42%` ou `—`) com alerta de falha crítica (`· !`) ou contagem de pendências do Brain (`· N`), além de banner compacto de atenção clicável quando o ecossistema requer ação do dono.
  - Resumo rápido das conversas ativas do Claude Code e do Antigravity.
- **Aba Sessões**
  - Lista de conversas do Claude Code (processo vivo via `kill -0`, janela real em `~/.cache/claude-context/<id>.json` ou janela presumida de `1.0M`) e do Antigravity (`agy`, janela `1_048_576` e nomes do `brain-sessions`), lendo até os últimos 4 MB de cada transcript `.jsonl` para calcular a ocupação percentual do contexto, detectar compactações automáticas (`compact_boundary` / `CHECKPOINT`), sinalizar os limiares do Brain em **70%** (atenção) e **80%** (compactar no próximo ponto natural) e preservar a última lista válida com aviso de diagnóstico caso uma leitura falhe.
- **Aba Brain (ecossistema nativo com falha parcial isolada e atalho `brain-pages`)**
  - Quatro cartões nativos em `BrainPanel/Modules/Brain/Adapters/Views/` alimentados por coleta local em `BrainPanel/Modules/Brain/` (`Esperando Você & Correio`, `Fila da Máquina (brain-ci)`, `Saúde & Backup` e `Jobs Agendados`), suprimindo dados corporativos (`flexograv`), sem decodificar corpos de mensagens entre sessões (`brain-mail`), isolando falhas por seção e oferecendo atalho de 1 clique validado em loopback para o `brain-pages`.

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
- `BRAIN_PANEL_BRAIN_PAGES_URL`: URL loopback opcional do painel web local `brain-pages` (`http://127.0.0.1` ou `http://localhost` com porta opcional, padrão `http://127.0.0.1:4780/`).
- `BRAIN_PANEL_CLAUDE_SESSIONS_DIR`, `BRAIN_PANEL_CLAUDE_PROJECTS_DIR`, `BRAIN_PANEL_CLAUDE_CONTEXT_CACHE_DIR`, `BRAIN_PANEL_ANTIGRAVITY_DIR`, `BRAIN_PANEL_BRAIN_STATE_DIR`, `BRAIN_PANEL_BRAIN_SESSIONS_STATE_DIR`, `BRAIN_PANEL_LOGS_DIR`, `BRAIN_PANEL_LAUNCH_AGENTS_DIR`, `BRAIN_PANEL_BACKUP_PROGRESS_FILE`, `BRAIN_PANEL_APP_SUPPORT_DIR`, `BRAIN_PANEL_CLI_SEARCH_PATHS`: caminhos absolutos opcionais usados para isolamento ou customização.

---

## Fontes de dados (somente-leitura)

| Fonte | Comando / Arquivo local | Operação |
| --- | --- | --- |
| **Claude (Cota)** | `claude` | Inspeciona `/usage` em pseudo-terminal local e encerra a sessão |
| **Gemini (Cota)** | `agy` | Inspeciona `/quota` em pseudo-terminal local e encerra a sessão |
| **Sessões Ativas (Claude)** | `~/.claude/sessions/*.json`, `~/.claude/projects/**/*.jsonl` e `~/.cache/claude-context/*.json` | Confere `pid` ativo, janela de contexto registrada e últimos 4 MB do `.jsonl` em modo somente-leitura |
| **Sessões Ativas (Antigravity)** | `~/.gemini/antigravity-cli/brain/*/.system_generated/logs/transcript*.jsonl`, `~/.local/state/brain-sessions/antigravity-names.json` e `conversation_summaries.db` | Filtra transcripts recentes pelo `Clock`, lê últimos 4 MB do `.jsonl` e consulta nomes em modo somente-leitura (`immutable=1`) |
| **Brain — Esperando Você** | `~/.local/state/brain-pending/*.json`, `~/.local/state/brain-mail/*/new/*.json`, `~/.local/state/brain-sessions/*.json` e `~/.claude/sessions/*.json` | Agrupa perguntas ativas ao dono e detecta caixas de correio paradas ou de sessões fechadas (apenas cabeçalhos `from` e `at`) |
| **Brain — Fila da Máquina** | `~/.local/state/brain-ci/{version.json,paused,mode,vm-now.json}`, `queue/*.json`, `runs.jsonl` (tail 512 KB) e `alerts.jsonl` (tail 128 KB) | Lê estado vivo da fila `brain-ci`, resumo diário e alertas das últimas 24 h |
| **Brain — Saúde & Backup** | `~/Library/Logs/brain-{doctor,test,sync,backup}.state` e `~/Brain/local/pages/backup-drive.json` | Verifica achados do `brain-doctor`, suíte `brain-test`, sincronização e progresso/atraso de backup |
| **Brain — Jobs Agendados** | `~/Library/LaunchAgents/com.lucas.*.plist`, `/bin/launchctl list` (timeout `<= 3 s`), `~/.local/state/brain-weekly/{state,faxina}.json` e `~/Library/Logs/brain-rehearse.state` | Cruza agendamentos `launchd` com último resultado e próxima execução calculada |

---

## Documentação e governança

- Regras e invariantes do repositório: `AGENTS.md`
- Decisões de arquitetura (ADRs):
  - `docs/adr/0001-plataforma-macos-e-ci.md`
  - `docs/adr/0002-arquitetura-camadas-erros-e-fronteiras.md`
- Licença: distribuído sob a [MIT License](LICENSE).

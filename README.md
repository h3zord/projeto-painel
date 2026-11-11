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
- **Aba Brain (ecossistema nativo com falha parcial isolada e atalhos `brain-pages`)**
  - Quatro cartões nativos em `BrainPanel/Modules/Brain/Adapters/Views/` alimentados por coleta local em `BrainPanel/Modules/Brain/` (`Esperando Você & Correio`, `Fila da Máquina (brain-ci)`, `Saúde & Backup` e `Jobs Agendados`), suprimindo dados corporativos (`flexograv`), sem decodificar corpos de mensagens entre sessões (`brain-mail`), isolando falhas por seção e oferecendo navegação de 1 clique validada em loopback para páginas explícitas de pendências (`/<escopo>/<pagina>` e `/<escopo>/_arquivo/<pagina>`), projetos (`/#projetos`), espera (`/#esperando`), fila (`/fila`), backup (`/brain/backup-drive`), saúde (`/#saude`) e jobs agendados (`/#agendados`) no `brain-pages`.
- **Alertas nativos discretos do macOS (`BrainPanel/Modules/Notifications/`)**
  - Notificações silenciosas na Central de Notificações (`UNUserNotificationCenter`, autorização apenas `.alert`, sem som nem badge no Dock) com cooldown de 1 hora por incidente e rearme automático após resolução para cota utilizável crítica (`< 15%`), sessão ou correio aguardando o dono (com omissão/mascaramento de escopo corporativo `flexograv`) e falhas em `brain-doctor` (`FAIL`) ou `brain-backup` (atrasado, falho ou com progresso ao vivo estagnado).

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
make up             # Compila em Debug (local/tmp/dev-derived-data) e abre o Brain Panel.app
make down           # Encerra a instância de desenvolvimento aberta pelo make up
make install-local  # Compila Release, valida smoke-app, instala em /Applications/Brain Panel.app e remove AI Usage Menu.app
make test           # Roda os testes unitários isolados (BrainPanelUnitTests)
make check          # Portão rápido: travas estáticas, docs, gitleaks, swift-format e testes unitários
make ci-portable    # Subconjunto portável (travas, docs, arquitetura e gitleaks) usado também no GitHub Actions
make format         # Formata o código Swift com xcrun swift-format (.swift-format)
make clean          # Remove artefatos temporários em local/tmp/
```

### Instalação local (`make install-local`)

Para instalar ou atualizar o aplicativo de uso diário no Mac:

```bash
make install-local
```

O alvo compila `Brain Panel.app` em configuração `Release` num diretório temporário isolado (`local/tmp/install-$$`), executa `scripts/smoke-app` sobre o bundle recém-gerado antes de tocar no destino e só então aciona `scripts/install-local` para:

1. Encerrar de forma limpa eventual instância anterior em `/Applications/Brain Panel.app` ou do utilitário provisório `/Applications/AI Usage Menu.app`.
2. Copiar o novo bundle via `ditto` em área de staging e substituir `/Applications/Brain Panel.app` preservando atributos nativos do macOS (e qualquer outro `.app` vizinho em `/Applications`).
3. Remover `/Applications/AI Usage Menu.app` caso ainda esteja presente e abrir o `Brain Panel.app` atualizado.

### Inicialização automática via `LaunchAgent` (`com.lucas.brain-panel`)

Além da opção manual em **Ajustes do Sistema → Geral → Itens de Início e Extensões**, você pode registrar um `LaunchAgent` reproduzível em `~/Library/LaunchAgents/com.lucas.brain-panel.plist` (ajustando `/Users/exemplo` para o diretório da sua conta):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.lucas.brain-panel</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Applications/Brain Panel.app/Contents/MacOS/Brain Panel</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/Users/exemplo/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>/Users/exemplo/Library/Logs/brain-panel.out.log</string>
  <key>StandardErrorPath</key>
  <string>/Users/exemplo/Library/Logs/brain-panel.err.log</string>
</dict>
</plist>
```

> [!NOTE]
> Manter `KeepAlive` como `false` permite iniciar o `Brain Panel.app` automaticamente no login sem relançá-lo em loop quando você clicar em **Encerrar** no rodapé do menu.

Para carregar ou descarregar o agente na sessão gráfica atual:

```bash
# Carregar e iniciar imediatamente
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.lucas.brain-panel.plist

# Encerrar e descarregar
launchctl bootout gui/$(id -u)/com.lucas.brain-panel
```

---

## Configuração (`.env.example`)

Toda variável `BRAIN_PANEL_*` é validada de forma estrita na inicialização por `BrainPanel/Shared/Config/AppConfig.swift` (variáveis desconhecidas ou valores fora dos limites encerram o processo com erro explícito). Consulte `.env.example` para a lista completa:

- `BRAIN_PANEL_MODE`: `live` (padrão), `isolated`, `self_check` ou `testing`.
- `BRAIN_PANEL_REFRESH_INTERVAL_SECONDS`: intervalo periódico de atualização de cotas (`10` a `3600`, padrão `300`).
- `BRAIN_PANEL_CACHE_TTL_SECONDS`: tempo máximo de cache ao abrir o painel (`1` a `600`, padrão `60`).
- `BRAIN_PANEL_BRAIN_PAGES_URL`: URL loopback opcional do painel web local `brain-pages` (`http://127.0.0.1` ou `http://localhost` com porta opcional, padrão `http://127.0.0.1:4780/`).
- `BRAIN_PANEL_NOTIFICATIONS_ENABLED`: `true` ou `false` (case-sensitive estrito; padrão `true` em `live` e `false` nos demais modos) para habilitar ou desativar os alertas nativos discretos do macOS.
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

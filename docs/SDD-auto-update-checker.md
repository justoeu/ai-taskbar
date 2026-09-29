# SDD — Checagem Automática Diária de Versões e Banner de Atualização

**Kind:** feature  
**Date:** 2026-09-24  
**Branch:** `feature/auto-update-checker`  
**Status:** CONFIRMED (Aprovado pelo Usuário)

---

## 1. Goal

Permitir que o AI Taskbar verifique periodicamente (1 vez por dia do calendário local, ver UPDATE-SCHED-001) a existência de novas versões publicadas no GitHub Releases de forma não intrusiva em background. Quando uma nova versão for detectada, exibir um banner destacado e elegante no topo do popover informando a disponibilidade da nova versão (`Nova versão vX.Y.Z disponível`) com um botão de ação rápida (`Atualizar`). Ao clicar, o app realiza o download seguro do `.dmg`, valida o checksum SHA-256 e disponibiliza o instalador para o usuário atualizar a aplicação.

---

## 2. Actors

- **Usuário do AI Taskbar:** Visualiza o banner quando há nova versão disponível e clica em "Atualizar" para baixar o instalador ou dispensa o banner.
- **RefreshScheduler / UpdateChecker:** Orquestra a verificação automática uma vez por dia do calendário local (UPDATE-SCHED-001) e persiste o timestamp da última checagem no `UserDefaults`.
- **GitHub Releases API:** Endpoint `GET https://api.github.com/repos/justoeu/ai-taskbar/releases/latest` consultado para checar a tag mais recente e obter os assets (`.dmg` e `checksums-*.txt`).

---

## 3. In Scope

### 3.1 Agendamento e Persistência da Cadência (1 vez por dia do calendário)
> **Atualizado por UPDATE-SCHED-001** (deep-audit 2026-09-29). A regra original
> ("intervalo mínimo de 24 h") foi substituída: um sleep fixo de 24 h após uma
> checagem pulada no launch chegou a atrasar a próxima para ~48 h. Não restaure
> o piso de 24 h.

1. **Controle de Frequência:**
   - Uma checagem por **dia do calendário local**: no launch, se ainda não checou hoje, e no início de cada novo dia enquanto o app roda.
   - Timestamp da última verificação persistido no `UserDefaults` sob a chave `ai_taskbar_last_update_check_at`, gravado no **início** de cada tentativa (inclusive quando `owner_repo` é inválido, para não reabrir a checagem a cada minuto — BUG-MAE-012).
   - `UpdateChecker.isCheckDue(lastCheck:now:calendar:)` (puro, `Calendar` + relógio injetados): devida quando nunca verificou (`nil`), quando a última foi em um dia local **anterior**, ou após `≥ 24 h`. Última checagem no futuro (relógio adiantado) não é devida.
   - `UpdateChecker.delayUntilNextCheck(lastCheck:now:calendar:)`: 0 quando devida; senão o tempo até a próxima meia-noite local ou +24 h, o que vier primeiro, limitado a `60 s...24 h`. A versão de instância aplica o piso de 60 s também ao caso "devida" (`minimumRetryDelay`), para uma checagem em andamento não girar.
   - Método `checkIfNeeded(force: Bool = false)`: com `force == false` só dispara se `isCheckDue`; `force == true` (botão "Verificar agora") sempre dispara.
2. **Integração no Ciclo de Vida:**
   - Disparo inicial na inicialização do aplicativo (`start()` do `RefreshScheduler` ou inicialização do `UpdateChecker`).
   - Loop em background no `RefreshScheduler`: dorme `delayUntilNextCheck()` e o recalcula a partir da data gravada após cada rodada, então uma checagem manual pela tela *Sobre* também move a próxima.
   - Respeito à flag de configuração `config.updates.enabled`: se desabilitado em `config.toml`, nenhuma checagem automática é realizada.

### 3.2 Banner de Notificação no Popover (`PopoverContentView`)
1. **Apresentação Visual:**
   - Banner posicionado no topo de `PopoverContentView` (logo abaixo do `headerBar` / `configChangedBanner`).
   - Estilizado com cores de destaque (`accentColor` / azul de sistema ou verde conforme estado), cantos arredondados, ícone ilustrativo (`arrow.down.circle.fill`).
   - Mensagem clara com a versão encontrada (ex: *"Nova versão v0.22.0 disponível"*).
2. **Estados do Banner:**
   - **Disponível:** Botão *"Atualizar"* (inicia o download) + botão sutil de fechar/dispensar (`xmark`) para o usuário ocultar o banner da versão atual se não quiser atualizar no momento.
   - **Baixando:** Indicador de progresso (`ProgressView`) e texto *"Baixando atualização…"*.
   - **Baixado / Pronto:** Mensagem *"Instalador baixado"* e botão *"Abrir no Finder"* (revelando o arquivo `.dmg` na pasta Downloads).
   - **Falha:** Mensagem sutil de erro se o download falhar, com opção de tentar novamente.
3. **Persistência de Notificação Dispensada:**
   - Se o usuário clica no `xmark`, a tag da versão dispensada é gravada em memória / `UserDefaults` (`dismissed_update_tag`) para não incomodar a cada abertura do popover até que uma versão ainda mais nova seja lançada.

### 3.3 Download Seguro e Instalação
1. **Aproveitamento do Mecanismo Existente:**
   - Utilização do pipeline seguro em `UpdateChecker`:
     - Allowlist estrita de hosts GitHub CDN (`SEC-SEN-002`).
     - Validação de tamanho (`dmgSize`) e hash SHA-256 (`checksums-*.txt`).
     - Armazenamento em `~/Downloads/ai-taskbar-<tag>.dmg`.
     - Revelação no Finder com `NSWorkspace.shared.activateFileViewerSelecting([dest])` e abertura assistida do arquivo `.dmg` para Gatekeeper e substituição rápida no `/Applications`.

### 3.4 Internacionalização (L10n)
- Strings localizadas em `Localizable.strings` (`en`, `pt-BR`, etc.):
  - `update_available_banner = "Nova versão %@ disponível"`
  - `update_button_download = "Atualizar"`
  - `update_downloading = "Baixando atualização…"`
  - `update_downloaded_ready = "Instalador pronto na pasta Downloads"`
  - `update_open_dmg = "Abrir"`
  - `update_dismiss = "Dispensar"`

---

## 4. Out of Scope

- Atualização in-place sem intervenção do usuário (estilo Sparkle com privilégios de root para sobrescrever o bundle em execução em `/Applications` sem consentimento).
- Reinicialização forçada da aplicação em segundo plano.
- Checagem automática caso `config.updates.enabled` esteja explicitamente definido como `false`.

---

## 5. Contracts & Signatures

### 5.1 `UpdateChecker`
```swift
extension UpdateChecker {
    public static let cadenceInterval: TimeInterval = 86_400 // 24 hours (teto do sleep)
    public static let minimumRetryDelay: TimeInterval = 60
    public static let lastCheckKey: String = "ai_taskbar_last_update_check_at"
    public static let dismissedTagKey: String = "ai_taskbar_dismissed_update_tag"

    public var isUpdateBannerVisible: Bool { get }
    public func checkIfNeeded(force: Bool = false)
    public func delayUntilNextCheck() -> TimeInterval
    public func dismissCurrentUpdate()

    public static func isCheckDue(lastCheck: Date?, now: Date, calendar: Calendar) -> Bool
    public static func delayUntilNextCheck(lastCheck: Date?, now: Date,
                                           calendar: Calendar) -> TimeInterval
}
```

### 5.2 `RefreshScheduler`
```swift
// Novo loop opcional ou acoplado ao scheduler existente:
private var updateCheckLoop: Task<Void, Never>?
private func startUpdateCheckLoop()
```

---

## 6. Invariants

1. **Sem Spam de Rede:** No máximo uma checagem automática por dia do calendário local (UPDATE-SCHED-001). Duas checagens podem ficar a menos de 24 h uma da outra quando atravessam a meia-noite (ex.: 23:34 e 10:00 do dia seguinte); isso é intencional. O loop nunca acorda com intervalo inferior a 60 s. O botão manual "Verificar agora" na tela *Sobre* ignora a regra.
2. **Segurança de Downloads (SEC-SEN-002):** Bloqueio inegociável de URLs fora dos hosts confiáveis do GitHub; validação obrigatória de integridade SHA-256 antes de qualquer ativação de arquivo.
3. **Concorrência e MainActor:** Todas as propriedades de UI de `UpdateChecker` são `@MainActor`. As tarefas em segundo plano rodam assincronamente sem bloquear a renderização da interface.
4. **Respeito à Baseline e Cobertura:** Cobertura de código mantida $\ge 90\%$ e zero warnings de compilação.

---

## 7. Done When

1. [x] SDD confirmado e versionado em `docs/SDD-auto-update-checker.md`.
2. [ ] Suíte de testes unitários para `checkIfNeeded` (regra do dia do calendário de UPDATE-SCHED-001, mock de tempo, `UserDefaults`), persistência e dismiss do banner.
3. [ ] Banner implementado em `PopoverContentView.swift` com os estados *Disponível*, *Baixando*, *Concluído* e botão de dispensar.
4. [ ] Ciclo de vida integrado com checagem automática diária.
5. [ ] Todos os testes passando (`make test`), `make validate` verde com cobertura $\ge 90\%$.
6. [ ] Revisão em 3 eixos (Standards, Spec, Correctness) aprovada 3/3 e score 10.

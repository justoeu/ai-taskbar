# SDD — integração Meta (Muse Code)

**Status:** confirmado pelo utilizador em 2026-10-12 (Etapa Zero, make-me-happy).
Pack: `docs/impl/make-me-happy/2026-10-12-feature-meta-muse/` ·
loop `full` · 3 worktrees · cobertura ≥ 90%
**Data:** 2026-10-12
**Branch prevista:** `feature/meta-muse`
**Base:** `main` em `cab15cebe48a`
**Plataforma:** macOS 13+, Swift 6, SwiftUI `MenuBarExtra(.window)`

## 1. Resumo

O ai-taskbar passará a ter um cartão para a **Meta**, fornecedora dos modelos
**Muse** (`muse-wonder-*`, `muse-spark-*`) servidos pelo CLI **Muse Code**
(`muse`). O cartão mostra duas coisas reais, de duas fontes independentes:

1. **Quota da assinatura** — janelas de 5 horas e semanal com percentual e
   `resets_at`, obtidas de `POST https://api.meta.ai/muse-code/key` com o
   token de device-code (`dca:`) que o `muse login` guarda. É a mesma leitura
   que o CLI faz para cunhar a sua chave de inferência; o ai-taskbar decodifica
   **só** os campos de assinatura e descarta a chave cunhada e qualquer dado de
   pagamento, sem os gravar em lado nenhum.
2. **Histórico local de tokens** — hoje e últimos 7 dias por modelo, lido dos
   `session.jsonl` que o CLI persiste em `~/.local/share/muse/sessions/`,
   pelo mesmo padrão dos scanners Claude/Codex/opencode já existentes.

**Não há preço público** (o catálogo local traz `cost: null` para todos os
modelos e os logs não trazem valores de cobrança), por isso o cartão mostra
tokens e percentuais de janela, **nunca dólares**. Contas pay-as-you-go sem
assinatura ativa mostram o estado real ("sem assinatura"), nunca uma barra
0% inventada — mesma regra "no denominator, no bar" dos créditos do Codex e
do cartão TypeSafe.

A decisão CLI vs API vs web, verificada nesta máquina e na referência pública
do CodexBar (Apêndice B): **não existe** subcomando `muse usage` nem API
pública de uso por chave (`META_API_KEY` e chaves de dashboard recebem 401 no
endpoint de quota). A via suportada na prática é a combinação acima: API de
assinatura com a credencial do CLI (read-only, sem prompts) + scanner local.
A quota de time via web (`dev.meta.ai`) fica desenhada como fase 2 (§17).

## 2. Fatos verificados

### 2.1 Medidos nesta máquina (2026-10-12, Muse Code 1.4.6)

| Fato | Valor | Como |
|---|---|---|
| CLI | `~/.local/bin/muse`, `Muse Code 1.4.6 (1.4.6-R6000.1)` | `muse --version` |
| Subcomandos | `resume exec config export trace model-profile skills voice plugins sandbox schema serve session-message mcp auth login logout init` — **nenhum** de uso/quota | `muse --help` |
| Login | `muse login` = aprovar código no browser (conta Meta); `META_API_KEY` no ambiente tem prioridade sobre o login | `muse login --help` |
| Chave de API | `muse auth set --provider meta --api-key-stdin` (só via stdin) | `muse auth set --help` |
| Raiz das sessões | `~/.local/share/muse/sessions/YYYY/MM/DD/<uuid>/session.jsonl` | filesystem |
| Índice | `~/.local/share/muse/session-index.db` (SQLite; tem `model_id`, mas **não** tokens) | `sqlite3 .schema` |
| Eventos com uso | `payload.event {kind, model, duration_ms, finish_reason, usage:{input_tokens, output_tokens, cached_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens}}` nos kinds `model_completed` (14) e `automated_review_completed` (7) da sessão amostrada | parse da sessão corrente |
| Rollups a ignorar | `resource_usage_sampled` (5, telemetria CPU), `goal_usage_attribution` (46), `record.quantity` — somá-los duplicaria | idem |
| Timestamp | `recorded_at` = Int64 em **microssegundos** (ex.: `1791829029337253`) | idem |
| Modelo no evento | `event.model = "muse-wonder-full-1.0"` na mesma linha do `usage` | idem |
| Semântica (amostra) | passo 2: `input 52304, cached 48116, cache_read 48116` → `input` **inclui** cache read; `reasoning` é subconjunto de `output` (total = input + output) | série dos 18 eventos |
| Catálogo local | `~/.local/share/muse/model-catalog/*.json`: 9 modelos (`muse-wonder-1.0` default, `wonder-full`, `spark-1.3/1.2` + variantes `-contributor`, `muse-image-1.0`), contexto 1 007 997, saída 128 000, **`cost: null` em todos** | filesystem |
| `~/.config/muse/auth.json` | **ausente** nesta máquina → login vive só no Keychain | filesystem (sem ler segredo) |
| `META_API_KEY`, `MUSE_SESSIONS_DIR`, `XDG_DATA_HOME` | não definidos nesta máquina | ambiente |

### 2.2 Da referência pública (CodexBar, `docs/muse.md` + plugin `muse.ts`)

Estudados como referência de abordagem, sem copiar código (Apêndice B):

| Fato | Valor |
|---|---|
| Item do Keychain do CLI | serviço `ai.meta.dev.credentials`, conta `meta`; payload JSON com o access token |
| Token válido | prefixo `dca:` (device-code). Chaves `LLM_` (dashboard) e `LLM\|` (cunhadas) → **401** no endpoint de quota |
| Precedência | `providers.meta.access_token` inline em `~/.config/muse/auth.json` vence o Keychain; `mechanism: "oauth"` sem token inline = login existe, token vem do Keychain; override `MUSE_AUTH_PATH` |
| Endpoint de quota | `POST https://api.meta.ai/muse-code/key`, corpo `{}`, headers `Authorization: Bearer <dca>`, `x-api-version: 1.0.0`; 401/403 = login rejeitado, 429 = rate limit, 5xx = indisponível |
| Resposta (subset) | `is_subs_active`, `require_payment`, `subs_tier_name`, `subs_usage { window {used_percent, resets_at, window_duration_mins}, weekly {used_percent, resets_at} }`; `resets_at` em **segundos** Unix |
| `subs_usage` ausente/`null` | acontece com assinatura ativa quando a janela de 5h está idle — **não** é erro; plano continua válido |
| Pay-as-you-go | sem `is_subs_active` → "sem assinatura", nunca 0% falso; `require_payment` → cobrança incompleta |
| Chave cunhada / pagamento | a resposta inclui chave de inferência e `payment_method` (brand/last4): **descartar**, nunca gravar/mostrar |
| Scanner deles | `$MUSE_SESSIONS_DIR` ?? `$XDG_DATA_HOME/muse/sessions` ?? default; bucket pelo timestamp registado no calendário local (não pela data da pasta); só `model_completed` + `automated_review_completed`; total = input+output (cached/reasoning subconjuntos); scans limitados (30 s / 2 GiB) com cache por identidade de ficheiro; dia indisponível ≠ zero medido |
| Dashboard | `https://dev.meta.ai`; sem página de status (`statusPageURL: nil`) |

## 3. Objetivos e não objetivos

### 3.1 Objetivos

1. Novo fornecedor `VendorId.meta`, exibido como **"Muse (Meta)"**.
2. Janelas de assinatura (sessão + semanal) com percentual sanitizado e
   contagem regressiva de reset, quando a conta tem assinatura ativa.
3. Histórico local de tokens hoje/7 dias por modelo via scanner, somando na
   `CostWindow` única e entrando no Analytics como tokens (sem USD).
4. Autenticação **read-only partilhada com o CLI**: ler o token `dca:` do
   `auth.json` inline ou do Keychain, sem prompts, sem refresh, sem write-back
   (a regra dos providers Anthropic/OpenAI aplica-se por analogia direta).
5. Configuração `[meta]` desativada por padrão, sem campos de chave de API.
6. Golden tests da wire type do mint e das linhas do scanner (política de
   imutabilidade do repo).
7. `make validate` verde e cobertura Core+Providers ≥ 90%.

### 3.2 Não objetivos

- **Executar o CLI** (`muse exec`, `muse login/logout/auth`) a partir do app.
  Nada de inferência para "sondar" a conta: custaria tokens ao utilizador.
- Guardar, loggar ou mostrar o token `dca:`, a chave cunhada pela resposta,
  email ou `payment_method`. A resposta é decodificada por allow-list (§8).
- Inventar quota: PAYG sem assinatura, `subs_usage` ausente ou Keychain
  bloqueado mostram estado honesto, nunca percentuais fabricados.
- Prompt interativo de Keychain (nem o fluxo Authorize do Anthropic) nesta
  fase: leitura prompt-free apenas; bloqueado → cartão degrada para o scanner
  com nota (§7.3).
- Cookies de browser / quota de time `dev.meta.ai` (fase 2, §17).
- Preço em dólares ou entrada na `PricingTable` enquanto a Meta não publicar
  preços (modelos entram como *unpriced*, §10).
- Feed de status: não foi encontrada página oficial; não inventar URL.

## 4. Decisões de produto

### 4.1 O que o cartão mostra

| Linha | Origem | Exemplo |
|---|---|---|
| Plano | `subs_tier_name` | "Muse Code Power Usage" |
| Janela de sessão | `subs_usage.window` | barra % + "reinicia em 2h 10m" |
| Janela semanal | `subs_usage.weekly` | barra % + reset |
| Sem assinatura | `is_subs_active != true` | "Sem assinatura (pay-as-you-go)" sem barras |
| Cobrança pendente | `require_payment == true` | aviso localizado + link `dev.meta.ai` |
| Assinatura idle | ativa, `subs_usage == nil` | plano, sem barras, nota "quota não incluída nesta resposta" |
| Tokens locais | scanner (§9) | "Hoje: 1,2M tokens · 7 dias: 8,4M" por modelo |
| Sem login | nenhuma credencial | "Execute `muse login` e atualize" |

As duas fontes são independentes: falha de quota não esconde os tokens
locais e vice-versa (precedente TypeSafe: falha da consola nunca falha o cartão).

### 4.2 Barra de menus

- `VendorId.meta.reportsUtilization = true`: com janelas presentes, participa
  no `maxUtilization` (só com o cartão expandido, regra geral) e pode ser
  fixado, com selo da pior janela como os restantes.
- Sem janelas (PAYG/idle/bloqueado), `maxUtilization = 0` e o selo fixado não
  mostra percentual (nunca "0%" enganoso); requisito coberto por teste.
- `shortLabel` do modo rotativo: `"MUSE"`; o rotativo já salta snapshots sem
  utilização — comportamento a confirmar por teste na task de UI.

### 4.3 Estado desligado e primeira execução

Regra da casa (§4.3 do SDD TypeSafe): **fornecedor novo nasce desativado**.

- Snippet `[meta] enabled = false`; `MetaConfig.enabled = false` por estrutura.
- Ajustes → Meta mostra o estado detetado sem ler segredos (login presente?
  sessões presentes?) para o utilizador decidir ligar o toggle. O app **não**
  se auto-ativa por encontrar login ou sessões.
- Desligado: sem cartão, sem leituras de Keychain/`auth.json`, sem scan.

### 4.4 Link do cabeçalho

`dashboardURL` → `https://dev.meta.ai`.

## 5. Modelo de domínio

```swift
// AiTaskbarCore/Models/VendorId.swift — case meta
//   displayName "Muse (Meta)" · systemImage "m.square"
//   dashboardURL https://dev.meta.ai · reportsUtilization true
//   loginCommand "muse login" (seguir o padrão dos casos CLI existentes)

// AiTaskbarCore/Models/UsageSnapshot.swift
public struct MetaSnapshot: Sendable, Equatable, Codable {
    public let planLabel: String?          // subs_tier_name, verbatim
    public let subscription: MetaSubscriptionState
    public let session: UsageWindow?      // janela subs_usage.window
    public let weekly: UsageWindow?       // janela subs_usage.weekly
}

public enum MetaSubscriptionState: String, Sendable, Equatable, Codable {
    case active              // is_subs_active == true
    case payAsYouGo          // sem assinatura ativa
    case billingIncomplete   // require_payment == true
}
```

- `VendorSnapshot` ganha `case meta(MetaSnapshot)` + discriminador Codable;
  caches antigos sem o case continuam válidos (case novo, nada muda nos outros).
- `windows` = as janelas presentes; `maxUtilization` segue o padrão dos
  fornecedores com sessão/semanal (pior das duas). Percentuais entram por
  `UtilizationPercent.sanitized`, como em todo o lado.
- A duração da janela de sessão **não** é assumida como 5h no código: vem de
  `window_duration_mins` da wire (o rótulo da UI deriva dela).

## 6. Configuração

```toml
[meta]
# Meta Muse. Off until enabled in Settings. Usage comes from the Muse CLI
# login (run `muse login`) — API keys cannot read subscription quota.
enabled = false
# sessions_dir = "~/.local/share/muse/sessions"  # overrides MUSE_SESSIONS_DIR
# auth_path = "~/.config/muse/auth.json"          # overrides MUSE_AUTH_PATH
```

```swift
public struct MetaConfig: Codable, Sendable, Equatable {
    public var enabled: Bool = false      // nasce desativado (4.3)
    public var sessionsDir: String?       // nil → env MUSE_SESSIONS_DIR → XDG → default
    public var authPath: String?          // nil → env MUSE_AUTH_PATH → ~/.config/muse/auth.json
}
```

- **Sem** `api_key`/`api_key_env`: chaves de API não leem a quota (401) e
  aceitá-las sugeriria um caminho que não funciona. Sem `base_url`: host
  fixo `api.meta.ai` (§8) — menor superfície, sem allow-list para manter.
- Nenhum campo novo em `ConfigLoader.secretFields` (não há segredo nosso).
- Entrada em `ConfigLoader.defaultSnippets` + `config.example.toml`.

## 7. Autenticação (credencial partilhada com o CLI, read-only)

Novo seam em `AiTaskbarCore/Credentials/`: `MetaCredentialReader`
(protocolo `MetaCredentialReading` para testes), ao lado do
`KeychainCredentialReader` existente, reutilizando
`KeychainPromptSuppressor`. **Não** generalizar o fallback `/usr/bin/security`
para aqui: esse truque só funciona porque o Claude Code CLI grava o item com
essa ferramenta; o item da Meta é gravado pelo binário `muse`.

### 7.1 Ordem de resolução do token

1. `auth.json` (`authPath` config → `MUSE_AUTH_PATH` → `~/.config/muse/auth.json`):
   `providers.meta.access_token` não-vazio com prefixo `dca:` → usar esse.
   Token inline sem o prefixo → **ignorar** (não é device-code; daria 401) e
   registar diagnóstico sem o valor.
2. Sem token inline (incl. `mechanism: "oauth"` ou ficheiro ausente):
   Keychain, serviço `ai.meta.dev.credentials`, conta `meta`; o payload é
   JSON — extrair só o access token e validar o prefixo `dca:`.
3. Nada encontrado → estado "sem login" (§4.1), sem erro ruidoso.

`META_API_KEY` **nunca** é lida para quota (401 garantido e semântica errada).

### 7.2 Regras de Keychain (as da casa, sem exceção nova)

- Leitura dentro de `KeychainPromptSuppressor.withPromptsSuppressed` **e**
  `kSecUseAuthenticationUI = kSecUseAuthenticationUIFail`.
- `-25308`/`-25293` = ACL-blocked (`isACLBlockedStatus`): degrada (§7.3),
  nunca prompt. Outros OSStatus propagam como erro.
- **Sem escritas**: sem `writeBack`, sem refresh, sem rotação. O CLI é o dono
  do ciclo de vida; token expirado → 401 → mensagem "execute `muse login`".
- Detetar "login existe?" (para Ajustes, §4.3) nunca pede o segredo: basta
  `auth.json` parseável nos termos acima ou presença do item por atributos.

### 7.3 Degradação

Keychain bloqueado/ausente ou mint indisponível **não** falha o cartão: o
snapshot de quota fica stale (cache) ou ausente com nota localizada, e os
tokens do scanner continuam visíveis. Se também não houver sessões, o cartão
mostra o estado "sem login / sem sessões" com a ação `muse login`.

## 8. Provider de quota (`MetaProvider` + `MetaWireTypes`)

`AiTaskbarProviders/MetaProvider.swift` sobre `CachedFetch` (sem boilerplate
novo) e `HTTPClient` partilhado (`env.http`, para `pin_hosts` o alcançar).

**O único pedido que este provider pode construir:**

```
POST https://api.meta.ai/muse-code/key
Authorization: Bearer <dca token>
x-api-version: 1.0.0
Content-Type: application/json
{}
```

- Host fixo, HTTPS, sem redirects (resposta 3xx = indisponível). User-Agent
  é o do app — nunca disfarce de browser/CLI.
- Cancelamento: `try Task.checkCancellation()` à entrada, depois da rede e
  antes de escrever a cache (regra da casa).
- A cache guarda o `MetaSnapshot` interpretado, nunca token nem corpo bruto.

**Decode por allow-list** (`MetaWireTypes.swift`). Só estes campos existem
para nós; a chave cunhada, `payment_method`, email e tudo o resto **não são
decodificados**:

```swift
struct MetaMintResponse: Decodable {
    let isSubsActive: Bool?        // is_subs_active
    let requirePayment: Bool?      // require_payment
    let subsTierName: String?      // subs_tier_name
    let subsUsage: SubsUsage?      // subs_usage (ausente/null = idle, §2.2)
    struct SubsUsage: Decodable {
        let window: Window         // used_percent, resets_at, window_duration_mins
        let weekly: Window         // used_percent, resets_at
    }
}
```

- `used_percent`: Double externo → `UtilizationPercent.sanitized`, clamp
  0–100; NaN/infinito nunca chega à UI.
- `resets_at`: segundos Unix; fora de `(0, 64092211200]` → data omitida,
  percentual mantido (nunca descartar a janela por causa da data).
- `window_duration_mins`: via `Int(checkedTruncating:)`; inválido/≤0 com
  janela presente = drift de formato → indisponível com stale, sem crash.
- Mapeamento de estado: `require_payment == true` → `.billingIncomplete`;
  senão `is_subs_active == true` → `.active`; resto → `.payAsYouGo`.

**Erros → `AppError`** (casos exatos a fixar na task, seguindo os vizinhos):
401/403 = login expirado (mensagem com `muse login`); 429 = rate-limited
(alimenta o backoff do `RefreshScheduler`); 5xx/transporte/drift =
indisponível servindo stale; sem credencial = estado vazio (§7.3), não erro.

## 9. Scanner local de tokens (`MuseSessionScanner`)

`AiTaskbarCore/Cost/MuseSessionScanner.swift`, gémeo estrutural de
`ClaudeSessionScanner`/`CodexSessionScanner`: enum stateless + `ScanMemo`
partilhado, ficheiros memory-mapped, pré-filtro por bytes antes do decode.

- **Raiz:** `sessionsDir` config → `MUSE_SESSIONS_DIR` →
  `$XDG_DATA_HOME/muse/sessions` → `~/.local/share/muse/sessions`.
  Passeio `YYYY/MM/DD/*/session.jsonl` com pré-filtro por `mtime`, mas o
  **bucket é pelo `recorded_at`** (µs → Date) no calendário local: uma sessão
  pode escrever turnos depois da data da pasta. Janelas da `CostWindow` única
  (hoje = meia-noite local; 7 dias = hoje + 6 dias anteriores). **Proibido**
  cutoff próprio em segundos (regra AGENTS.md).
- **Linhas que contam:** envelope `{recorded_at, payload:{event:{kind, model,
  usage}}}` com `kind ∈ {model_completed, automated_review_completed}`.
  Pré-filtro por bytes nesses dois literais. Ignorar: linha-cabeçalho do
  frame, `resource_usage_sampled`, `goal_usage_attribution`,
  `record.quantity` e qualquer outro kind — são rollups/telemetria e
  duplicariam (medido §2.1). Linhas com `usage` malformado são saltadas e
  contadas como drift parcial (nota no `CostEstimate`), nunca fatal.
- **Semântica dos tokens — não generalizar de outro scanner** (tabela nova
  para o AGENTS.md):

  | | `input` inclui cached? | reasoning |
  |---|---|---|
  | `MuseSessionScanner` | **sim** — subtrai-se o cache read | subconjunto de output, **não** se soma |

  Mapeamento para `ModelUsage` (saturating, nunca negativo):
  `cacheReadTokens = cache_read_tokens ?? cached_tokens`;
  `inputTokens = max(0, input_tokens − cacheReadTokens)`;
  `cacheCreateTokens = cache_write_tokens`;
  `outputTokens = output_tokens` (reasoning já dentro).
  Fixado por teste dourado com a série medida (§2.1): se um dia o CLI passar
  a reportar input sem cache, o teste falha em vez de inflacionar em silêncio.
- **Atribuição por modelo:** `event.model` da própria linha (nunca um modelo
  "da sessão" — lição do opencode). Linha sem modelo → bucket `"unknown"`,
  tokens mantidos.
- **Deduplicação:** não foi observado replay da mesma resposta (ao contrário
  do Claude Code). Sem dedup especulativo: cada `model_completed` conta uma
  vez; se surgir evidência de reemissão, trata-se como bug novo com fixture.
- **Limites:** os do padrão da casa (memo por ficheiro, saltar ficheiros
  fora da janela por `mtime`); scan parcial/corrompido devolve subtotais
  válidos + `note`. Dia sem leitura possível ≠ zero medido.
- `Paths` ganha o resolvedor da raiz Muse; `session-index.db` **não** é
  lido (não tem tokens; ler SQLite de outro app é superfície sem benefício).

## 10. Custo e Analytics

- `CostEstimate` do scanner: tokens reais, `usdToday/usdLast7Days = 0`,
  todos os modelos em `unpricedModels*`. `PricingTable` **sem** entrada Meta:
  chave ausente é exatamente o sinal "preço desconhecido ≠ $0 conhecido".
- `CostEstimator` regista o novo scanner para `.meta`; o Analytics mostra
  tokens/participação por modelo e esconde dólares para modelos unpriced
  (comportamento já existente — cobrir com teste).
- Cor da marca: entrada `.meta` em `vendorColorIndices` +
  `AnalyticsFormatters.vendorColor` (azul Meta), via `VendorBrandIcon` como
  todos os cartões. Menu-bar continua monocromático.

## 11. UI e wiring

- `AppEnvironment.makeProviders()`: `MetaProvider` quando `config.meta.enabled`,
  com `env.http` e TTL como os restantes; falha de init desliga só este
  fornecedor (padrão TypeSafe). `enabledVendorIds` inclui `.meta`.
- Cartão: reutiliza `VendorSectionView` (plano, janelas com reset, rodapé de
  custo do scanner). Linhas Meta-específicas: estados PAYG/cobrança/idle e a
  nota de quota indisponível — estrutura localizada na view, **nunca**
  frases montadas na wire type (regra da casa, lição dos créditos Codex).
- `MenuBarLabelView.shortLabel(.meta) = "MUSE"`.
- Ajustes → Meta: toggle `enabled`, texto de estado detetado (login
  presente/ausente; sessões presentes/ausentes; Keychain bloqueado), campos
  opcionais `sessions_dir`/`auth_path`. Sem campo de chave. Sem `.alert`
  nativo (gate `NoNativeDialogsTests`).
- Pin: permitido (§4.2); geometria/medidas seguem `PinnedStatusItemManager`
  sem alterações.

## 12. Localização

Chaves novas em en + pt-BR + es, especificadores `%ld` (gate de ratchets):
plano/rótulos de janela (derivados da duração, sem "5h" hardcoded quando a
wire disser outra coisa), "sem assinatura (pay-as-you-go)", "cobrança
pendente — conclua em dev.meta.ai", "quota não incluída nesta resposta de
login", "execute `muse login`", "acesso ao Keychain indisponível — mostrando
só o histórico local", "sem sessões do Muse encontradas". Textos exatos na
task de UI; o conjunto de chaves tem de ser idêntico nas três línguas.

## 13. Segurança e privacidade

| Risco | Mitigação neste SDD |
|---|---|
| Exfiltração do token `dca:` | só sai para `api.meta.ai` em HTTPS; nunca escrito em config/cache/log; sem `base_url` configurável |
| Chave cunhada reutilizada | nunca decodificada/guardada; o app não faz inferência |
| Prompt de Keychain invisível (app `LSUIElement`) | suppressor + UIFail; ACL-blocked degrada sem UI |
| Rotação a invalidar o CLI | read-only estrutural: sem refresh/write-back (§7.2) |
| PII na resposta (email, pagamento) | decode por allow-list (§8); teste afirma que campos extra são ignorados |
| Logs de sessão contêm prompts/código | scanner decodifica só envelope+`usage` numéricos; conteúdo nunca é copiado para cache/logs; ficheiros só são lidos |
| JSON hostil (`1e300`, NaN) | `Int(checkedTruncating:)`/`saturating`, `UtilizationPercent.sanitized` (gates existentes) |

Sem nova superfície de escrita em disco além da cache de snapshot já
existente (`DiskCache.defaultFor(.meta, …)`, permissões da casa).

## 14. Testes (política do repo + MMH)

- **Golden do mint** (`MetaWireTypes`): fixture canónica em
  `AiTaskbarTesting/Fixtures.swift` construída do contrato §2.2 (marcada
  como sintética — capturar uma resposta real exige gastar o login do
  utilizador num mint; se esse dia chegar, a fixture é substituída por uma
  verbatim redigida, com o utilizador presente). Casos: ativa com janelas;
  ativa sem `subs_usage`; PAYG; `require_payment`; `resets_at` inválido;
  `used_percent` não-finito; campos extra (chave/pagamento) ignorados.
- **Golden do scanner**: linhas `session.jsonl` com a forma medida (§2.1),
  incluindo kinds a ignorar na mesma fixture; asserta totais hoje/7d por
  modelo, mapeamento §9 (input−cacheRead, reasoning dentro de output),
  bucket por `recorded_at` atravessando a data da pasta e DST via
  `CostWindow`.
- **Provider**: `StubURLProtocol` (suite `.serialized`): único URL é o mint;
  401/403/429/5xx; stale em falha; token nunca em cache. Credencial: ordem
  §7.1 (auth.json inline > oauth→Keychain > ausente), prefixo `dca:`
  obrigatório, ACL-blocked → degradado (reader falso + keychain isolado
  onde aplicável, seguindo os testes de Keychain existentes).
- Asserts booleanos sobre opcionais via `expectTrue/expectFalse` (ratchet).
- Secção `meta` em `AiTaskbarValidate/main.swift` (decode rápido + scanner).
- Gate final: `make validate` (build, validate suite, testes com cobertura
  ≥ 90% em Core+Providers, app, smoke, auditoria de permissões).

## 15. Plano de tarefas (input para o Planner do make-me-happy)

Slices propostas (3 worktrees, loop `full`); o Planner emite o
`TASKS.json` canónico a partir daqui, cada task red→green:

| Slice | Conteúdo |
|---|---|
| WT-1 Core | `VendorId.meta`, `MetaSnapshot`, `MetaConfig` + snippets/`config.example.toml`, `MuseSessionScanner` + `Paths`, registos em `CostEstimator`/`vendorColorIndices`, fixtures + goldens do scanner |
| WT-2 Providers | `MetaCredentialReader`, `MetaWireTypes` + golden do mint, `MetaProvider` + testes §14, secção validate |
| WT-3 App | `AppEnvironment`, cartão/Settings/`shortLabel`/cor, `Localizable` ×3, smoke visual, README + adendo AGENTS.md (linha da tabela de scanners §9) |

Ordem: WT-1 e WT-2 em paralelo após a task de tipos de WT-1 fechar o
contrato `MetaSnapshot`; WT-3 depois dos merges. Baseline `make test` verde
antes de abrir slices (regra MMH).

## 16. Riscos e questões abertas

| Risco | Nota |
|---|---|
| Endpoint não documentado muda | decode por allow-list + stale; drift lê-se como indisponível, não como 0% |
| `session.jsonl` muda de schema (`frame_schema_version`) | kinds desconhecidos ignorados; golden falha alto |
| Build ad-hoc sem ACL no item do Keychain | degrada para scanner-only nesta fase; fluxo Authorize fica decisão futura com evidência de procura real |
| `automated_review_completed` sem `usage` em algumas linhas | observado (8 kinds, 7 com usage): linha sem usage simplesmente não conta |
| Relógio/µs fora de gama | datas fora da `CostWindow` são ignoradas; futuro leve segue a tolerância existente de `dayOffset` |

Questões que **não** bloqueiam: nome do SF Symbol (default `m.square` pode
mudar na task de UI sem mexer no contrato).

## 17. Fase 2 (desenhada, não implementada)

- **Quota de time via browser** (`dev.meta.ai`): quando o mint omite
  `subs_usage`, ler `subscription-quota` do time **escolhido pelo
  utilizador** (nunca auto-selecionado), email da sessão tem de casar com o
  login, `tier` tem de casar com `subs_tier_name`; leitura marcada como
  estimada; cookies off por padrão, login em `WKWebView` não-persistente
  como no TypeSafe, nunca copiar cookies à mão. Token `dca:` nunca vai para
  `dev.meta.ai`.
- **Pricing**: se a Meta publicar preços (ou o catálogo passar a trazer
  `cost`), `PricingTable.meta` + USD no cartão; até lá, unpriced.
- **Status**: se surgir página/feed oficial, ligar ao painel de status com
  descriptor próprio e testes como os restantes vendors RSS/Statuspage.

## Apêndice A — evidência local (2026-10-12)

Comandos corridos (só leitura; nenhum segredo impresso): `muse --help/
--version/auth set --help/login --help/logout --help/model-profile show`,
parse por chaves/contagens de
`~/.local/share/muse/sessions/2026/10/12/<sessão-corrente>/session.jsonl`
(381 linhas; usage em `model_completed`×14, `automated_review_completed`×7,
`resource_usage_sampled`×5), `.schema` de `session-index.db`, leitura do
catálogo de modelos, verificação de existência de
`~/.config/muse/auth.json` (ausente) e das variáveis `META_API_KEY`/
`MUSE_SESSIONS_DIR`/`XDG_DATA_HOME` (ausentes).

## Apêndice B — referência CodexBar

[CodexBar](https://github.com/steipete/CodexBar) (MIT) já integra o Muse
Code. Foram lidos `docs/muse.md`, o plugin `muse.ts` (nomes de campos do
mint e da quota web) e os descritores Swift do provider **só para aprender
a abordagem**: de onde vêm a credencial e as janelas, que kinds contam no
scanner, e as regras de honestidade (PAYG sem 0% falso, dia indisponível ≠
zero). Nenhum código foi copiado — a implementação segue os padrões da casa
(`CachedFetch`, `CostWindow`, `ScanMemo`, decode por allow-list, goldens próprios).




## 18. Adendo de campo (2026-10-12, primeiro teste local)

Duas decisões revistas com evidência da máquina real, sem mudar o contrato:

1. **Authorize interativo (revoga "sem prompt nesta fase" de §3.2/§7.3).**
   O item `ai.meta.dev.credentials` recusa esta assinatura por ACL, por
   isso sem autorização a quota nunca lê. `MetaProvider` passa a expor
   `authorizeCredentialsInteractively()` sobre
   `KeychainAccessAuthorizer.authorize` (mesmo caminho do Anthropic: só a
   partir do botão Authorize, leitura silenciosa exigida depois, dados
   descartados). O erro bloqueado usa a forma `AppError.credentials` com
   o nome do OSStatus para a affordance existente renderizar. Leituras
   agendadas continuam prompt-free e read-only.
2. **Página de status (revoga §3.2 "sem página conhecida").** Existe
   página oficial: `https://metastatus.com` ("Status and outages of Meta
   business products"). Sem feed machine-readable verificado, entra como
   link-only (`statusPageURL` + cobertura `.linkOnly`), como Gemini/Z.AI.
3. **Preços publicados (revoga §3.2/§10 "sem USD").** A Meta Model API
   publica tarifas: Wonder $4,00/$0,20/$20,00 e Spark 1.3
   $1,25/$0,15/$4,25 por 1M (in/cached/out), confirmadas por várias fontes
   do lançamento de 2026-10-12. `PricingTable.meta` precifica o scanner
   como estimativa de valor de API (assinatura é flat-fee). Wonder Full
   não tem tarifa pública (só assinatura): estimado à tarifa Wonder,
   precedente `codex-auto-review`; `muse-image-1.0` fica unpriced.
4. **Fallback `/usr/bin/security` (revoga §7 "não generalizar").**
   Medido nesta máquina: a ferramenta lê o item da Meta silenciosamente,
   por isso o padrão do Claude aplica-se tal e qual — leitura direta
   bloqueada por ACL → mesmo item via a ferramenta (keychain desbloqueada
   exigida, argumentos exactos, cooldowns), sem prompt nenhum. O
   Authorize do ponto 1 fica como último recurso.
   **Revogado em 2026-10-15 — volta a valer §7 "não generalizar".** O CLI
   regravou o item em 2026-10-14 22:28 (`mdat` mudou, `cdat` de 2026-10-12
   ficou): logo a seguir a ferramenta abriu "security wants to access key
   ai.meta.dev.credentials" com campo de senha, e o app também. A leitura
   silenciosa medida antes dependia de uma autorização que a regravação do
   `muse` (binário assinado pela Meta, time V9WTTPBFK9, grava pela API do
   Keychain, nunca pela ferramenta) não preserva. A ferramenta corre como
   outro processo, fora do `KeychainPromptSuppressor`, então era o único
   caminho capaz de abrir um diálogo sozinho. Removida: leitura bloqueada →
   banner Authorize, nunca um prompt.

## 19. Adendo (2026-10-15): cópia cifrada do token — revoga §7 "nunca guardado"

O banner Authorize voltou no mesmo dia, depois de o `muse` se atualizar
sozinho (1.4.8 → 1.4.9; o launcher verifica atualizações a cada hora). Cada
regravação do item `ai.meta.dev.credentials` apaga as autorizações de
terceiros. O CodexBar documenta a mesma perda ("a fresh `muse login` can
recreate the Keychain item without the grant") e também pede de novo. Só uma
autorização no ACL significaria, então, uma senha a cada atualização do Muse,
o que é inaceitável num app público.

Decisão: `MetaTokenStore` guarda a cópia do próprio app do token `dca:`.

- Formato: `SecretBox` `enc:v2`, amarrado ao Mac, campo `meta.token_copy`.
- Arquivo: `credentials/meta-token`, 0600 na escrita, verificado pelo
  `validate.sh`. Link simbólico é ignorado; valor que não começa com `dca:`
  não é gravado.
- Gravada a cada leitura silenciosa bem-sucedida, que roda logo depois do
  Authorize. O autorizador continua sem guardar os bytes que lê.
- Usada quando a leitura direta é bloqueada ou falha.
- Servida como `.storedToken`, distinto de `.token` (leitura ao vivo).
- Num 401, qualquer cópia do token enviado é descartada. Só quando a cópia era
  o que foi enviado volta o banner Authorize. Um 401 num token lido ao vivo do
  Keychain é login morto e aparece como 401 (refazer `muse login`), nunca
  como banner. Um 403 mantém a cópia. (Achado das 3 revisões do #51.)
- Sem UUID de hardware nenhuma cópia é gravada (nunca `enc:v1`).
- Alcance honesto: protege o arquivo copiado para fora do Mac, não contra
  processos do mesmo usuário (o UUID é público). É um passo abaixo do ACL do
  Keychain, aceito em troca de não pedir senha a cada atualização do Muse.
- Apagada quando o item some (`muse logout`).
- As Configurações mostram "detectado" quando a cópia existe.
- Continua read-only quanto ao CLI: nada é escrito no item nem no `auth.json`,
  e o token nunca é renovado pelo app.

## 20. Adendo (2026-10-25): janela semanal mantida com a sessão ociosa — revoga §4.1 "sem barras"

O mint omite `subs_usage` **inteiro** quando a janela de 5 h está ociosa, e a
semanal some junto. É justamente o que uma semanal esgotada provoca: sem
quota, a sessão fica ociosa. O cartão mostrava "quota não incluída" e 0%,
com a semana em 100% (medido em `history/meta.jsonl`: semanal 66→100% em três
dias, de volta a 0 a cada resposta ociosa) — falsa sensação de tokens livres.

Decisão:

- `MetaProvider` grava cada janela semanal **ao vivo** em
  `LastSeenWindowStore` (`quota/meta.json`: percentual, reset e hora da
  leitura; não é segredo). Nunca grava uma janela vinda do cache ou mantida.
- Na leitura (`decodeSnapshot`, cache e stale incluídos),
  `MetaSnapshot.carryingWeekly` devolve a última semanal a um snapshot
  `.active` sem semanal própria, com `weeklyLastSeenAt`. O cache continua
  guardando só o que a Meta enviou.
- Só no formato ocioso (`acceptsCarriedWeekly`: `.active`, sem janela de
  sessão E sem semanal) e só antes do `resets_at` da própria janela; sem
  `resets_at`, com leitura datada no futuro, ou em PAYG/cobrança pendente,
  não há transporte.
- "A semanal só cresce" vale dentro de um plano de um login: a leitura é
  gravada com o `subs_tier_name` e só é transportada sob o mesmo plano; login
  ausente (`muse logout`) apaga a leitura (a conta seguinte tem a sua semana).
- É um limite inferior (a semanal só cresce até o reset), por isso entra no
  `maxUtilization` e no selo fixado. O cartão diz "Semanal: última leitura
  …" com a hora, nunca a apresenta como leitura atual.

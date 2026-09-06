# SDD — painel de status operacional dos provedores

**Status:** implementado e validado automaticamente
**Data:** 2026-09-03  
**Branch:** `feat/service-status-pages`  
**Plataforma:** macOS 13+, Swift 6, SwiftUI `MenuBarExtra(.window)`

## 1. Resumo

O ai-taskbar passará a mostrar, no cabeçalho do popover, um botão de status
operacional. O botão resume a pior condição conhecida entre os provedores
habilitados e abre um painel interno com o estado atual, incidentes e
manutenções que intersectaram as últimas seis horas.

A feature é deliberadamente separada da coleta autenticada de uso. Uma falha
de credencial, quota, schema ou rede local não significa que o serviço do
fornecedor está indisponível. Da mesma forma, uma status page pública não diz
se a conta específica do usuário está saudável.

Apenas provedores habilitados com uma página oficial verificável aparecem no
painel. Quando existe uma página oficial, mas não um feed público estável, a
cobertura é representada como `unknown`; ela nunca é convertida implicitamente
em `operational`. Provedores sem página oficial, como Z.AI, são omitidos.

## 2. Objetivos e não objetivos

### 2.1 Objetivos

1. Adicionar um botão “Status dos serviços” no lado direito do cabeçalho
   quando ao menos um vendor habilitado possuir página oficial.
2. Abrir a experiência dentro do próprio `MenuBarExtra`, sem `sheet`, janela
   ou popover aninhado.
3. Exibir os vendors habilitados no config que possuam página oficial, mesmo
   quando a instanciação do provider autenticado de usage falhar.
4. Mostrar status atual, cobertura da fonte, freshness e incidentes que
   intersectem `[agora - 6h, agora]`.
5. Distinguir operacional, manutenção, degradação, indisponibilidade parcial,
   indisponibilidade ampla e desconhecido.
6. Consultar apenas fontes públicas oficiais, sem reutilizar credenciais dos
   providers de uso.
7. Reusar o lifecycle compartilhado de cache, cancelamento, stale fallback e
   sanitização de erros.
8. Ser completamente testável fora de um host XCTest UI, exceto a composição
   visual final, coberta pelo smoke launch e checklist manual.

### 2.2 Não objetivos

- Medir SLA/SLO ou calcular percentuais históricos de uptime.
- Sondar endpoints autenticados para inferir saúde global.
- Raspar HTML, executar JavaScript de status pages ou consumir APIs internas
  com chaves extraídas do frontend.
- Enviar notificações de incidente nesta primeira versão.
- Adicionar configuração TOML ou permitir `status_base_url` arbitrária.
- Misturar status operacional com `VendorSnapshot`, `UsageHistoryStore`,
  `maxUtilization` ou backoff de quota HTTP 429.
- Persistir um segundo histórico local. A janela de seis horas é reconstruída
  a partir dos timestamps oficiais contidos no payload em cache.

## 3. Decisões de produto

### 3.1 Significado de “vendor ativo”

A fonte da verdade são os flags `enabled` do `AppConfig`. O pipeline de status
recebe `AppEnvironment.enabledVendorIds()`, na ordem canônica do app. Assim, a
status page pública continua visível quando uma credencial ou a construção do
provider autenticado de usage falha.

Um vendor habilitado com página oficial, mas sem feed público utilizável,
continua tendo uma linha `unknown`. Vendors sem página oficial verificável são
filtrados pelo `ServiceStatusStore`; isso remove Z.AI do painel sem alterar seu
provider de usage.

### 3.2 Cobertura da fonte

Cada source declara um nível de cobertura:

| Cobertura | Contrato | Sem incidentes ativos |
|---|---|---|
| `full` | estado atual explícito + histórico/incidentes | pode mostrar `operational` |
| `incidentsOnly` | feed oficial de incidentes, sem estado global explícito | permanece `unknown`; após leitura válida, a UI destaca “sem incidentes ativos” |
| `linkOnly` | página oficial sem feed público estável | `unknown` |

Uma fonte `incidentsOnly` pode elevar o nível para degradação/outage quando há
um incidente ativo, mas a ausência de item não prova operação normal.

### 3.3 Janela temporal

A janela é fechada e móvel: `[now - 21_600 s, now]`.

Um incidente entra na janela quando:

```text
startedAt <= now && (resolvedAt ?? now) >= now - 6h
```

Assim, um incidente iniciado há dez horas e resolvido há duas horas aparece;
um evento futuro ou totalmente resolvido antes do cutoff não aparece. A barra
visual recorta o começo/fim nos limites da janela, sem alterar os timestamps
originais do incidente.

Resultados são ordenados por `updatedAt` descendente e, em empate, por `id`.
Itens duplicados de RSS são deduplicados por identificador estável ou pelo par
normalizado `(título, startedAt)`.

### 3.4 Agregação do ícone global

Precedência conhecida:

```text
majorOutage > partialOutage > degradedPerformance > maintenance > operational
```

- Uma condição conhecida não operacional vence `unknown`.
- `unknown` impede verde quando não há nenhuma condição conhecida pior.
- O agregado só é `operational` quando todos os vendors exibidos de cobertura
  `full` retornaram explicitamente operational e não existe linha sem
  observação útil.
- Durante refresh, o último agregado permanece visível e recebe freshness
  `loading`; cold start usa `unknown`.

## 4. Fontes oficiais e adapters

Pesquisa validada em 2026-09-04. Todos os endpoints são constantes compiladas
e HTTPS.

| Vendor | Página oficial | Adapter | Cobertura | Observações |
|---|---|---|---|---|
| Anthropic | `https://status.claude.com` | Statuspage v2 | `full` | `summary.json`, `incidents.json`, `scheduled-maintenances.json`; componentes Claude API `k8w3r06qmzrp` e Claude Code `yyzkbfz2thpt` |
| OpenAI | `https://status.openai.com` | Statuspage v2 | `full` | componentes Codex Web, Desktop, API, CLI e VS Code; incidentes atuais podem não declarar component IDs, portanto o incidente da página é preservado |
| Kimi | `https://status.moonshot.cn` | Statuspage v2 | `full` | componente Open API `8psr5dfdld0s` |
| DeepSeek | `https://status.deepseek.com` | FlashDuty JSON | `full` experimental | usa os endpoints públicos da própria página; contrato não documentado e isolado em wire types/fixtures |
| OpenRouter | `https://status.openrouter.ai/` | RSS | `incidentsOnly` | `incidents.rss`; `/api/v2/summary.json` retorna 404 |
| xAI | `https://status.x.ai` | RSS | `incidentsOnly` | `feed.xml` contém incidentes declarados e histórico; os estados live dos componentes exibidos na página não têm contrato público estável para consumo pelo app |
| Gemini | `https://aistudio.google.com/status` | link | `linkOnly` | RPC protobuf interno não é contrato público; Google Cloud/Workspace status não corresponde à Gemini API usada pelo app |

Z.AI é deliberadamente omitido desta tabela e do painel: nenhuma página de
status oficial verificável está disponível. O monitoramento autenticado de uso
do Z.AI permanece inalterado.

### 4.1 Statuspage v2

`StatuspageSource` faz até três requests públicos em paralelo:

- `/api/v2/summary.json`: indicador global, componentes, incidentes ativos e
  manutenções ativas;
- `/api/v2/incidents.json`: incidentes recentes/resolvidos;
- `/api/v2/scheduled-maintenances.json`: manutenções que possam intersectar a
  janela.

O payload combinado é codificado antes de entrar no cache. Campos adicionais
são ignorados; tokens desconhecidos viram `.unknown`, sem falhar o documento
inteiro. Component IDs são usados para componente/legenda, mas um incidente
sem relação explícita não é descartado.

Mapeamento padrão do indicador:

| Upstream | Domínio |
|---|---|
| `none` | `operational` |
| `maintenance` | `maintenance` |
| `minor` | `degradedPerformance` |
| `major` | `partialOutage` |
| `critical` | `majorOutage` |
| outro | `unknown` |

### 4.2 FlashDuty JSON

`DeepSeekStatusSource` usa somente endpoints sob `status.deepseek.com`:

- `/api/status-page/6410630422455/summary/active`;
- `/api/status-page/6410630422455/summary/structure` com limites epoch;
- `/api/status-page/6410630422455/change/list` com limites epoch.

O adapter traduz o estado explícito e as mudanças da janela. Como o contrato
não é documentado, falha de schema produz stale fallback; em cold failure, a
linha fica `unknown`. Não há fallback por scraping. O RSS oficial da mesma
página pode ser usado apenas como incidents-only caso o JSON deixe de
funcionar em uma versão futura, sem alterar o domínio.

### 4.3 RSS

`RSSStatusSource` aceita um descriptor fixo por vendor e usa `XMLParser` com
limites de payload e texto. O parser exige uma estrutura RSS/channel e o fetch
confirma a identidade do canal antes de aceitar o documento. HTML de
título/descrição é convertido em texto simples; URLs são validadas antes de
entrar no snapshot. Links XML namespaced, como o `<atom:link>` autocontido do
feed xAI, não substituem o `<link>` textual que identifica o canal. Categorias
estruturadas do item têm precedência sobre palavras encontradas no texto livre
ao determinar a fase atual.

Os feeds do OpenRouter e da xAI são `incidentsOnly`: uma leitura válida sem
incidente ativo mantém o domínio em `unknown`, pois ausência de item não prova
operação normal. Para distinguir esse caso de falha/cold start, a apresentação
exibe “Sem incidentes ativos” como estado observado. Qualquer incidente ativo
eleva o nível normalmente.

### 4.4 Link-only

Não há request automático. O snapshot sintético é `unknown`, coverage
`linkOnly` e contém a página oficial. Vendors sem página oficial são removidos
antes da criação das linhas e nunca recebem uma URL inventada.

## 5. Modelo de domínio

Novo arquivo Core: `Models/ServiceStatus.swift`.

```swift
public enum ServiceStatusLevel: String, Codable, Sendable, Equatable {
    case operational
    case maintenance
    case degradedPerformance
    case partialOutage
    case majorOutage
    case unknown
}

public enum ServiceStatusCoverage: String, Codable, Sendable, Equatable {
    case full
    case incidentsOnly
    case linkOnly
}

public enum ServiceIncidentPhase: String, Codable, Sendable, Equatable {
    case investigating
    case identified
    case monitoring
    case resolved
    case scheduled
    case inProgress
    case completed
    case unknown
}

public struct ServiceIncident: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let level: ServiceStatusLevel
    public let phase: ServiceIncidentPhase
    public let startedAt: Date
    public let updatedAt: Date
    public let resolvedAt: Date?
    public let affectedComponents: [String]
    public let message: String?
    public let sourceURL: URL?
}

public struct VendorServiceStatus: Codable, Sendable, Equatable {
    public let vendorId: VendorId
    public let level: ServiceStatusLevel
    public let coverage: ServiceStatusCoverage
    public let summary: String
    public let sourceURL: URL?
    public let sourceUpdatedAt: Date?
    public let incidents: [ServiceIncident]
}
```

`ServiceStatusWindow` concentra as funções puras de interseção, recorte,
ordenação e pior nível. `VendorId.statusPageURL` expõe apenas URLs oficiais
fixas e opcionais.

## 6. Cache e networking

### 6.1 Outcome genérico

`FetchOutcome` será generalizado sem quebra de source:

```swift
public struct CachedOutcome<Snapshot: Sendable & Equatable>: Sendable, Equatable
public typealias FetchOutcome = CachedOutcome<VendorSnapshot>
public typealias ServiceStatusOutcome = CachedOutcome<VendorServiceStatus>
```

`CachedFetch.run` também será genérico. A ordem obrigatória permanece:

```text
Task.checkCancellation
  -> cache fresh
  -> fetch
  -> Task.checkCancellation
  -> decode
  -> Task.checkCancellation
  -> write atômico 0600
  -> em erro: scrub + markFailed + stale fallback ou throw
```

Nenhum adapter implementa seu próprio lifecycle de cache.

### 6.2 Namespace

`DiskCache.defaultFor(_:scope:)` recebe `CacheScope` com default `.usage`.

- usage mantém o caminho legado `<Caches>/ai-taskbar/<vendor>/usage.json`;
- status usa `<Caches>/ai-taskbar/status/<vendor>/usage.json`.

Isso evita migração e colisão. TTL de status é
`max(15, refresh_interval_seconds - 5)`; `maxStale` é seis horas. O cache stale
é sempre rotulado na UI e não vira estado atual silencioso.

### 6.3 Segurança e privacidade

- `URLSession` ephemeral compartilhada, sem cookies, credential storage,
  referer ou headers de autenticação.
- Somente HTTPS e trust store do sistema; pinning existente continua sendo
  respeitado quando configurado para o host.
- Allowlist exata: `status.claude.com`, `status.openai.com`,
  `status.moonshot.cn`, `status.deepseek.com`, `status.openrouter.ai`,
  `status.x.ai`, `aistudio.google.com`.
- Redirect para host fora da allowlist não é seguido como fonte nem aberto.
- Links de incidentes recebidos da rede passam por validação de scheme/host.
- Payload limitado a 2 MiB por resposta e strings de diagnóstico/incidente
  são truncadas/sanitizadas; nenhum HTML arbitrário chega ao SwiftUI.
- Nenhum arquivo novo contém segredo; caches continuam atômicos e `0600`.

## 7. Providers

Contrato público em `AiTaskbarProviders`:

```swift
public protocol ServiceStatusProvider: Sendable {
    var vendorId: VendorId { get }
    func fetchStatus(forceRefresh: Bool, now: Date) async throws
        -> ServiceStatusOutcome
}
```

Uma extensão oferece `fetchStatus(forceRefresh:)` usando `.now` para a app.
`now` explícito mantém os testes determinísticos.

Implementações:

- `CachedServiceStatusProvider<Source>` aplica `CachedFetch` genérico;
- `StatuspageSource` atende Anthropic, OpenAI e Kimi por descriptors;
- `DeepSeekStatusSource` atende o contrato FlashDuty;
- `RSSStatusSource` atende OpenRouter e xAI;
- `ServiceStatusProviderFactory` retorna providers apenas para IDs recebidos.

IDs link-only com página oficial não ganham provider de rede; o App store cria
suas linhas sintéticas `unknown`. IDs sem página oficial não criam linha.

Cada source chama `Task.checkCancellation()` na entrada, após requests
agrupados e antes de devolver o payload. O cache compartilhado checa antes do
write. 429 e 5xx viram erro/fallback stale e nunca são interpretados como
indisponibilidade do vendor. O polling automático é ancorado no fim da rodada
e nunca ocorre em intervalo menor que 300 s. Interpretar `Retry-After` fica
fora desta primeira versão.

## 8. Estado da aplicação e concorrência

Novo `ServiceStatusStore`, `@MainActor`, irmão de `UsageStore`:

```text
Row.State
  idle
  loading(previous: ServiceStatusOutcome?)
  ok(ServiceStatusOutcome)
  failed(error: AppError, fallback: ServiceStatusOutcome?)
  unavailable(VendorServiceStatus) // link-only
```

Propriedades publicadas:

- `rows`, preservando a ordem dos vendors exibidos;
- `overallLevel`;
- `isLoading`;
- `lastCompletedRefreshAt`.

Uma rodada usa `withTaskGroup` para consultar os vendors em paralelo e publica
um resultado coerente ao final. Falha de um source não cancela os outros. Um
`epoch` e um único `Task` cancelam/ignoram rodadas superadas. O valor anterior
permanece visível durante loading; cancelamento não vira erro.

`RefreshScheduler` continua sendo o único dono de timer longo. Ele recebe um
`ServiceStatusStore?` e mantém um loop independente: dispara a rodada inicial,
aguarda sua conclusão e só então conta o próximo intervalo (mínimo de 300 s).
Isso evita sobreposição e polling adiantado sem misturar loading/429 com quota.
Refresh manual de status não dispara refresh de uso e vice-versa.

Fluxo:

```text
AppConfig enabled flags
  -> AppEnvironment.enabledVendorIds()
  -> ServiceStatusProviderFactory
  -> RefreshScheduler (timer existente)
  -> ServiceStatusStore @MainActor
  -> providers em paralelo
  -> CachedFetch<T> / cache status / HTTPClient
  -> wire adapter
  -> VendorServiceStatus (janela de 6h)
  -> StatusPanelView
```

## 9. UX e acessibilidade

### 9.1 Botão do cabeçalho

Ordem: countdown, status, About, Refresh All. O botão de status usa
`waveform.path.ecg` como ícone estável de monitoramento e sobrepõe um pequeno
badge com o símbolo semântico do agregado. Assim, forma, cor, label e value
acessível comunicam o estado. Dentro do painel, os símbolos semânticos são:

| Estado | SF Symbol | Cor semântica |
|---|---|---|
| operational | `checkmark.circle.fill` | verde |
| maintenance | `wrench.and.screwdriver.fill` | azul/roxo |
| degraded | `exclamationmark.triangle.fill` | laranja |
| partial/major outage | `xmark.octagon.fill` | vermelho |
| unknown | `circle.dashed` | secundária |

Cor nunca é a única informação. O botão recebe `accessibilityLabel`,
`accessibilityValue` com contagens/cobertura e `accessibilityHint`.

### 9.2 Modal interno

`PopoverContentView` mantém um estado único de overlay e renderiza
`StatusPanelView` no mesmo `ZStack` usado por About/Settings. Não usa `.sheet`
porque esse padrão não é confiável dentro de `MenuBarExtra(.window)`.

Estrutura no frame existente de 420×540:

1. header fixo: agregado, “Status dos serviços”, “Últimas 6 horas”, freshness,
   refresh e fechar;
2. `ScrollView`: uma linha/card por vendor na mesma ordem de `sortedVendors`;
3. footer fixo: legenda e nota de escopo.

Cada row mostra nome, símbolo + texto atual, coverage/freshness, uma faixa
temporal de seis horas e controles explícitos para expandir. Intervalos
sobrepostos são normalizados em segmentos não sobrepostos, sempre pintados
com a pior condição naquele instante. Rows com condição não operacional
iniciam expandidas. Detalhes mostram título, fase, duração, componentes, última
mensagem, link do incidente e status page quando seguros.

Background da faixa:

- coverage `full`: operational, com incidentes/manutenção sobrepostos;
- `incidentsOnly`: unknown, com incidentes sobrepostos;
- `linkOnly`: inteiramente unknown.

Estados vazios/erro são honestos:

- full sem incidente: “Nenhum incidente reportado nas últimas 6h”;
- incidents-only observado sem incidente: estado destacado “Sem incidentes
  ativos” e detalhe “Nenhum incidente ativo reportado; o feed não confirma o
  estado global”;
- link-only: “Status automático indisponível”;
- stale: “Não foi possível atualizar; mostrando dados de HH:mm”;
- cold error: unknown + Retry; nunca down.

O painel fecha por botão, `cancelAction`/Escape e clique no scrim. O scrim é
escondido da árvore AX; conteúdo de fundo desabilita hit testing e AX enquanto
o overlay está aberto. O foco de teclado entra no botão fechar e retorna ao
botão de status ao encerrar. Reduce Motion remove a transição de escala. A
faixa é um único elemento AX com resumo textual de duração por estado.

## 10. Localização

Toda string entra simultaneamente em `en`, `pt-BR` e `es`. Chaves incluem:

- nome/help/AX do botão e painel;
- seis níveis de estado e três níveis de cobertura;
- título “últimas 6 horas”, `-6h` e “agora”;
- freshness/loading/stale/retry;
- empty states por cobertura;
- ações de fechar, atualizar, abrir incidente e abrir status page;
- legenda e nota de que status oficial agregado pode variar por conta/região.

Testes verificam completude das chaves sem depender da UI.

## 11. Estratégia RED → Green

Cada ciclo lógico segue: escrever teste, executar o menor teste para comprovar
o RED esperado, implementar, executar o teste alvo e então `make validate`.
Nenhum commit é criado no RED. Todo commit exige o gate completo verde.

### Ciclo A — domínio/cache genérico

RED:

- interseção nos limites, incidente longo, evento futuro, ordenação e pior
  nível;
- `unknown` não vira verde;
- Codable round-trip;
- aliases `CachedOutcome`/`FetchOutcome`;
- cache de usage e status não colide e maxStale de 6h expira.

GREEN:

- `ServiceStatus.swift`, `CachedOutcome<T>`, `CachedFetch.run<T>` e
  `CacheScope` mínimos;
- asserts equivalentes no validate runner;
- `make validate` verde.

### Ciclo B — Statuspage v2

RED:

- fixtures canônicas operational, degraded, outage, manutenção e incidente
  resolvido dentro/fora da janela;
- golden field-by-field;
- URL/método, component mapping, schema desconhecido, cache fresh,
  force-refresh, 503 stale/cold e cancelamento.

GREEN:

- wire types, source, provider genérico e descriptors Anthropic/OpenAI/Kimi;
- validate runner com fixture da família;
- `make validate` verde.

### Ciclo C — FlashDuty e RSS

RED:

- golden DeepSeek para snapshot/change list;
- goldens RSS com HTML, update/resolução, item fora de 6h e URL hostil;
- cobertura full vs incidentsOnly e deduplicação;
- payload excessivo/schema inválido/cancelamento/stale.

GREEN:

- `DeepSeekStatusSource` e `RSSStatusSource`;
- descriptors OpenRouter/xAI e fallback link-only seguro;
- validate runner por wire family;
- `make validate` verde.

### Ciclo D — registry e store

RED:

- factory preserva exatamente o conjunto/ordem de IDs recebidos;
- link-only não faz request;
- uma row por vendor habilitado com página oficial;
- resultados paralelos preservam ordem;
- sucesso parcial, stale, cancelamento e epoch supersedido;
- agregado e presentation model.

GREEN:

- factory, `ServiceStatusStore`, wiring em `AppEnvironment`,
  `RefreshScheduler` e `AiTaskbarApp`;
- `make validate` verde.

### Ciclo E — UI e localização

RED:

- presentation model puro: símbolos, labels, cobertura, ordem, empty states,
  resumo AX e links permitidos;
- completude das chaves em três idiomas.

GREEN:

- botão, overlay, rows, timeline e incident details;
- `make validate` verde;
- smoke launch automatizado; inspeção manual em light/dark, Reduce Motion,
  teclado/Escape, títulos longos, sete vendors e VoiceOver básico permanece
  uma verificação de release, pois não é observável no runner CLI.

## 12. Critérios de aceite

1. Quando existe vendor habilitado com página oficial, o botão aparece no
   trailing do cabeçalho e abre/fecha sem demitir o popover; sem linhas
   elegíveis, o botão é omitido para não abrir um painel vazio.
2. Somente vendors habilitados com página oficial aparecem; cada um aparece
   exatamente uma vez.
3. Falha de usage/credencial nunca altera o status público.
4. Todas as condições usam símbolo, texto, cor e descrição acessível.
5. O período é exatamente seis horas e inclui incidentes longos por
   interseção, não só por data de início.
6. `unknown` e stale não aparecem como operacional.
7. Vendors com página oficial, mas sem feed confiável, permanecem visíveis e
   honestamente unknown; vendors sem página oficial, como Z.AI, são omitidos.
8. Refresh é paralelo, cancelável, single-flight e preserva o último valor.
9. Nenhum segredo é lido/enviado; redirects e links externos são allowlisted.
10. Novos wire types têm fixtures + golden tests; novos arquivos Core/Providers
    têm happy path coberto.
11. Cobertura Core+Providers permanece >= 90%, zero novos warnings, bundle,
    smoke launch e permission audit passam.
12. Pelo menos três revisões independentes (corretude, segurança/concorrência e
    UI/performance) são resolvidas antes do merge final.

## 13. Riscos e mitigação

| Risco | Mitigação |
|---|---|
| schema público muda | wire adapter isolado, unknown tokens, golden fixtures, stale fallback |
| feed RSS sugere falso verde | OpenRouter e xAI permanecem `incidentsOnly`; ausência de incidente nunca cria baseline operational |
| status global não corresponde ao produto | component descriptors e rótulo de cobertura; incidentes globais preservados quando o upstream omite componentes |
| excesso de requests | timer existente, cache/conditional fetch, paralelo limitado por HTTPClient e refresh manual independente |
| payload/link malicioso | limite de tamanho, sanitização, HTTPS e allowlist exata |
| SwiftUI modal fecha o MenuBarExtra | overlay interno, padrão já usado por About/Settings |
| nova superfície reduz cobertura | RED→Green por slice e `make validate` após cada mudança |

## 14. Plano de integração em worktrees

1. Worktree Core: ciclo A e infraestrutura compartilhada.
2. Merge no branch da feature após gate verde.
3. Worktree adapters: ciclos B/C, baseado no Core integrado.
4. Worktree App/UI: ciclos D/E, baseado em Core+adapters integrados.
5. Gate completo no branch integrado.
6. Três reviews em paralelo; correções RED→Green no worktree responsável.
7. Gate final, merge dos branches remanescentes e remoção de todos os
   worktrees/terminais temporários.

Esse encadeamento evita branches paralelos que dependem de tipos ainda não
existentes e mantém cada commit compilável e validado.

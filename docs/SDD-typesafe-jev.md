# SDD — integração TypeSafe AI (Jev)

**Status:** fase 1 e fase 2 implementadas (2026-09-30). Fase 2: `TypeSafeLoginController`, `TypeSafeConsoleClient`, `TypeSafeConsoleWireTypes`, `TypeSafeConsoleSession`/`TypeSafeSessionStore`. 429 é tratado como indisponível sem nova tentativa imediata (o próximo ciclo tenta de novo), no lugar do `Retry-After` de até 10 s de §16.5
**Data:** 2026-09-29
**Branch prevista:** `feat/typesafe-jev`
**Base:** `main` depois do merge da PR do deep-audit (os pontos de integração
abaixo foram lidos em `audit/deep-audit-2026-09-29`, commit `cc96efd`)
**Plataforma:** macOS 13+, Swift 6, SwiftUI `MenuBarExtra(.window)`

## 1. Resumo

O ai-taskbar passará a ter um cartão para a **TypeSafe AI**, fornecedora do
**Jev**. O cartão é autenticado por chave de API (`TYPESAFE_API_KEY` ou chave
inline no `config.toml`), confirma que a chave é válida, lista os modelos que
ela enxerga, mostra a saúde operacional a partir da página de status oficial e
leva ao console da TypeSafe.

O Jev **não é um LLM de chat**. É um modelo "System One": recebe um `state` e
perguntas tipadas (Choice, Score, Noul) e devolve decisões tipadas com
probabilidade e confiança. Todos os modelos são servidos por um único endpoint,
`POST /v1/systemone`.

**A limitação que define este SDD:** a TypeSafe **não publica nenhuma API de
uso, cobrança, saldo, créditos ou cotas da conta**. O uso existe apenas por
requisição (`usage.input_tokens` / `usage.output_tokens` na resposta de cada
chamada ao `systemone`), e o app não enxerga as chamadas que o código do usuário
faz. Por isso, **nesta versão o cartão não mostra consumo, tokens nem gasto** —
mostra conectividade, modelos e status. A seção 13 define como e quando o
consumo pode entrar, sem adivinhar números.

## 2. Fatos verificados (fontes oficiais, 2026-09-29)

Fontes de terceiros divergem das oficiais (um site de guia cita US$ 0,42/MTok,
dez vezes o preço oficial; há domínios `jevtypesafe.org` e `jevtypesafeai.com`
sem vínculo aparente com a empresa). **Só vale o que está em `typesafe.ai`.**

| Fato | Valor | Fonte |
|---|---|---|
| Base URL | `https://api.typesafe.ai` | SDK Python, `DEFAULT_BASE_URL` |
| Autenticação | `Authorization: Bearer <key>` | docs.typesafe.ai/api |
| Variáveis de ambiente do SDK | `TYPESAFE_API_KEY`, `TYPESAFE_BASE_URL`, `TYPESAFE_DEFAULT_MODEL` | SDK Python, constants |
| Endpoint de avaliação | `POST /v1/systemone` (único documentado na referência HTTP) | docs.typesafe.ai/api |
| Listagem de modelos | `GET /v1/models` → `{"models":[{"name","description","release_date"}]}`; **com chave real lista só `jev-latest` e `jev-preview`**, sem a versão (`jev-1.13.0`) | SDK Python + medido com chave, 2026-09-29 (Apêndice A) |
| `GET /v1/models` sem chave | **403** `{"detail":{"error_type":"authentication_error","message":"Must supply an API key! …"}}` | medido, 2026-09-29 |
| `GET /v1/models` com chave inválida | **401** `{"detail":{"error_type":"authentication_error","message":"Cannot authenticate with the server. …"}}` | medido, 2026-09-29 |
| `release_date` | ISO 8601 com **microssegundos** e offset (`2026-09-10T18:38:01.391457+00:00`) | medido, 2026-09-29 |
| Erros documentados | 401 chave ausente/inválida · 422 validação · 429 limite · 529 sobrecarga | docs.typesafe.ai/api |
| Retentativas do SDK | 408, 429, 5xx; respeita `Retry-After` | SDK Python, `RetryPolicy` |
| Uso por resposta | `usage: {input_tokens: int?, output_tokens: int?}` | SDK Python, schema `Usage` |
| API de uso/cobrança da conta | **nenhuma documentada** | docs.typesafe.ai/api, llms.txt |
| Modelos | `jev-1.13.0`; `jev-latest` e `jev-preview` → `jev-1.13.0` | docs.typesafe.ai/models |
| Preço `jev-1.13.0` | US$ 0,042 / MTok de entrada; saída grátis | docs.typesafe.ai/models |
| Limites | 250k tokens/s, 1.200 req/min, "ajustados dinamicamente" | docs.typesafe.ai/models |
| Console | `https://console.typesafe.ai` | typesafe.ai |
| Status | `https://status.typesafe.ai`, feed RSS em `/feed.rss` (incidentes e manutenções) | medido, 2026-09-29 |
| Cabeçalhos observados | `x-typesafe-request-id`, `x-envoy-upstream-service-time`, `cf-ray`; **nenhum** `x-ratelimit-*`, nem com chave válida | medido, 2026-09-29 |
| Uso no console (`console.typesafe.ai/api/usage?granularity=hour`) | **bloqueado pelo WAF do Cloudflare** para clientes fora do navegador, mesmo com a chave de API | medido, 2026-09-29 |

## 3. Objetivos e não objetivos

### 3.1 Objetivos

1. Novo fornecedor `VendorId.typesafe`, exibido como **"Jev (TypeSafe)"**.
2. Configuração `[typesafe]` com `enabled`, `api_key_env`, `api_key` inline
   (cifrada em repouso como as demais) e `base_url` com allow-list de host.
3. Heartbeat autenticado e **gratuito** via `GET /v1/models`: chave válida,
   número de modelos e os nomes que a chave enxerga (`jev-latest`, `jev-preview`).
4. Status operacional pelo feed RSS oficial, com cobertura `incidentsOnly`,
   no painel de status existente.
5. **Desativado por padrão.** O fornecedor só é ativado quando o usuário salva
   uma chave em Ajustes (ver 4.3). Sem chave, nenhuma requisição é feita.
6. Mapeamento de erros HTTP para `AppError` com mensagens localizadas (en,
   pt-BR, es), incluindo 403 como chave inválida e 529 como sobrecarga.
7. Golden test da wire type com fixture **verbatim** (ver 13.1).

### 3.2 Não objetivos

- **Fazer chamadas de avaliação do Jev (`POST /v1/systemone`) para checar a
  conta.** Isto não tem relação com a página de status: a saúde do serviço vem
  de `status.typesafe.ai` (seção 8), que é pública e gratuita. O ponto aqui é
  outro — cada chamada ao `systemone` é uma "pergunta" ao modelo, cobra tokens
  e apareceria no consumo do próprio usuário. Para validar a chave o app usa só
  `GET /v1/models`, que não cobra nada.
- Inventar consumo: nada de estimar tokens ou dólares sem dado real da conta.
- Na fase 1, qualquer acesso ao console. O gasto e o saldo pela sessão do
  console são a **fase 2** (seção 16), opcional e desativada por padrão.
- Em qualquer fase: disfarçar o app de navegador (User-Agent falso,
  reaproveitar `cf_clearance`, resolver desafio) para passar pelo WAF do
  Cloudflare. O app sempre se identifica como ele mesmo.
- Entrar na tabela `PricingTable`: ela só existe para scanners locais de logs
  de CLI, e não há log local de chamadas ao Jev (ver cabeçalho de
  `PricingTable.swift`).
- Participar do percentual da barra de menus (não há utilização a medir).

## 4. Decisões de produto

### 4.1 O que o cartão mostra

| Linha | Origem | Exemplo |
|---|---|---|
| Plano / título | fixo | "Jev (TypeSafe) · chave de API" |
| Conectividade | resultado do `GET /v1/models` | "Chave válida · 1 modelo" |
| Modelos disponíveis | `models[]` na ordem da API | "jev-latest · jev-preview" |
| Atualização | `release_date` mais recente da lista | "atualizado em 10/09/2026" |
| Aviso de consumo | texto localizado fixo | "A TypeSafe não oferece API de uso da conta. Veja o consumo no console." + botão |
| Status | `ServiceStatusStore` (RSS) | badge do painel de status |

Sem barra de progresso e sem valores em dinheiro. Um cartão sem número real é
preferível a uma barra com número inventado (mesma regra de "no denominator,
no bar" dos créditos do Codex).

### 4.2 Barra de menus

- `maxUtilization` do snapshot é **0** e o fornecedor é **excluído** do
  agregado (não soma nem puxa o percentual global para baixo).
- **Fixar na barra fica desabilitado** para este fornecedor, com a ajuda
  "Este provedor não informa uso para exibir na barra". Um selo "0%"
  permanente seria enganoso. Implementação: `VendorId.reportsUtilization`
  (novo, `false` para `.typesafe`), consultado pelo toggle de fixar e por
  `UsageStore.togglePinned` (defesa em profundidade).
- `shortLabel` do modo rotativo: `"JEV"`, e o modo rotativo pula fornecedores
  sem utilização.

### 4.3 Estado desligado e primeira execução

Regra de produto: **todo fornecedor novo nasce desativado** e só é ativado
quando o usuário salva uma chave.

- Seção padrão acrescentada por `ensureAllVendorSections`: `enabled = false`.
  O `TypeSafeConfig.enabled` também tem padrão `false` (seguro por estrutura,
  não só pelo snippet), e um `[typesafe]` sem `enabled` decodifica como `false`.
- Cartão desativado: não aparece na lista principal (mesmo tratamento dos
  demais desativados) e não entra no painel de status.
- **Ajustes → TypeSafe:** ao salvar uma chave não vazia, o `SettingsViewModel`
  grava `api_key` (cifrada) **e** `enabled = true` na mesma edição do TOML.
  Apagar a chave não desativa sozinho (o usuário pode estar usando a variável
  de ambiente); desativar é o toggle.
- Quem usa `TYPESAFE_API_KEY` no ambiente ativa pelo toggle em Ajustes (ou
  `enabled = true` no arquivo); o app não se auto-ativa por encontrar a
  variável.
- Os fornecedores existentes que hoje nascem com `enabled = true` (Gemini,
  DeepSeek, xAI) não mudam nesta entrega; alinhar todos à regra é uma
  mudança separada, porque desligaria cartões que usuários atuais já veem.

### 4.4 Link do cabeçalho

`dashboardURL` → `https://console.typesafe.ai`.

## 5. Modelo de domínio

```swift
// AiTaskbarCore/Models/UsageSnapshot.swift
public struct TypeSafeSnapshot: Sendable, Equatable, Codable {
    public let planLabel: String?           // nil → a view usa o rótulo localizado
    public let models: [TypeSafeModel]      // na ordem da resposta
    public var modelCount: Int { models.count }
    public var lastUpdated: Date? { models.compactMap(\.releaseDate).max() }
    // Sem janelas: `windows` devolve [] e `maxUtilization` devolve 0.
}

public struct TypeSafeModel: Sendable, Equatable, Codable {
    public let name: String
    public let description: String?
    public let releaseDate: Date?           // "release_date" tolerante (ISO 8601 data ou data-hora)
}
```

- `VendorSnapshot` ganha `case typesafe(TypeSafeSnapshot)` e o discriminador
  Codable correspondente. Como o cache em disco guarda snapshots, o decode de
  um cache antigo **sem** esse case continua válido (o case é novo; nada muda
  nos existentes).
- **Sem resolução de versão.** A resposta real lista apenas `jev-latest` e
  `jev-preview`; nenhum campo diz para qual versão cada um aponta, e
  `jev-1.13.0` não aparece. O cartão mostra os nomes como a API os entrega e
  **não** exibe um mapeamento "alias → versão" (só a página de modelos da
  documentação traz isso, e texto de documentação não é fonte para a UI).
- `release_date` é a data da **entrada** (2026-09-10 para os dois aliases),
  não a do lançamento público do Jev (15/09); o cartão a rotula como
  "atualizado em", nunca como "lançado em".

## 6. Configuração

```toml
[typesafe]
enabled = false                         # vira true ao salvar a chave em Ajustes
api_key_env = "TYPESAFE_API_KEY"
# api_key = "ts-..."                    # alternativa inline; cifrada em repouso
# base_url = "https://api.typesafe.ai"  # só hosts oficiais são aceitos
```

```swift
public struct TypeSafeConfig: Codable, Sendable, Equatable {
    public var enabled: Bool = false    // nasce desativado (4.3)
    public var apiKeyEnv: String = "TYPESAFE_API_KEY"
    public var apiKey: String?
    public var baseURL: String = "https://api.typesafe.ai"
    public static let allowedHosts: Set<String> = ["api.typesafe.ai"]
    public static let defaultBaseURL = "https://api.typesafe.ai"
}
```

- `base_url` segue exatamente o padrão de `DeepSeekConfig.validate`: somente
  `https://`, somente host da allow-list, sem subdomínio automático, sem
  userinfo, sem porta fora de 443; inválido → log de aviso e volta ao padrão.
  URL controlada pelo usuário é vetor de exfiltração da chave (regra dura).
- `api_key` inline entra no `seal`/`unseal` do `ConfigLoader` (SecretBox),
  como `deepseek.api_key`, inclusive o caminho "cifrada mas indecifrável →
  limpa e avisa".
- `TYPESAFE_BASE_URL` do SDK **não** é lido: o app lê só `config.toml`, e uma
  variável de ambiente não passa pela validação de host de forma visível.
- `api_key_env` aceita apenas nomes `[A-Z_][A-Z0-9_]*`, como os demais.
- `pin_hosts` de exemplo e a allow-list de TLS pinning ganham `api.typesafe.ai`.
- Tolerância TOML: não há campos `Double` nesta seção; se surgirem, usar
  `flexibleDouble` (regra dura).

## 7. Provider e wire types

### 7.1 `TypeSafeProvider`

- `UsageProvider`, `vendorId = .typesafe`, lifecycle **exclusivamente** via
  `CachedFetch` (cache → fetch → write → decode → stale fallback). Proibido
  duplicar o ciclo.
- Credenciais via `EnvOrConfigCredentialReader(envVarName:inlineKey:vendorName:)`.
- `Task.checkCancellation()` na entrada do fetch, depois da rede e antes de
  gravar o cache (regra dura).
- Requisição: `GET {base_url}/v1/models`, `Authorization: Bearer`,
  `Accept: application/json`, `timeoutInterval = 10` (igual ao
  `DEFAULT_TIMEOUT` do SDK), corpo de resposta limitado pelo teto já aplicado
  pelo `HTTPClient` depois do audit.
- A chave **nunca** aparece em log, erro, cache ou snapshot. O `DiskCache`
  guarda só a resposta de `/v1/models`, em arquivo `0600` (regra dura).

### 7.2 Mapeamento de erros

| HTTP | Significado | `AppError` | Cartão |
|---|---|---|---|
| 200 | chave válida | — | conectividade OK |
| 401, 403 | chave ausente/inválida/sem permissão | credencial inválida | "Chave recusada pela TypeSafe" + link para o console |
| 422 | não esperado num GET | schema | erro genérico, com request-id |
| 429 | limite de taxa | `isRateLimited` | usa cache antigo; entra no back-off de 60 s do scheduler |
| 529, 5xx | sobrecarga/indisponível | rede/servidor | usa cache antigo; sugere o painel de status |

- Corpo de erro `{"detail":{"error_type","message"}}` decodificado de forma
  tolerante (`detail` pode ser string em FastAPI); `message` só entra em log
  depois de truncada, e nunca como texto de UI sem localização.
- `x-typesafe-request-id` é guardado no erro para diagnóstico (não é segredo).
- `Retry-After`, se presente, é respeitado pelo back-off existente.

### 7.3 `TypeSafeWireTypes.swift`

`TypeSafeModelsResponse { models: [TypeSafeModelEntry] }`, com
`name` obrigatório, `description`/`release_date` tolerantes a ausência e a
tipos inesperados. `release_date` passa pelo `ISO8601Parsing.parse` já
existente, que tenta com fração e depois sem: um `ISO8601DateFormatter` sem
`.withFractionalSeconds` devolve `nil` para os seis dígitos de fração que a API
envia (verificado no macOS 26), e o helper cobre esse caso. Data inválida vira
`nil`, nunca erro de decode. O golden test fixa a data exata da fixture (um campo novo ou estranho não derruba o cartão), e
`toSnapshot()` puro. Nenhuma frase de UI é montada aqui (regra já documentada
para os créditos do Codex).

## 8. Status operacional

- Novo `RSSStatusDescriptor.typeSafe`:
  `statusPageURL = https://status.typesafe.ai`,
  `feedURL = https://status.typesafe.ai/feed.rss`.
- `ServiceStatusProviderFactory.rssDescriptor(for: .typesafe)` → `.typeSafe`;
  `statuspageDescriptor` → `nil`.
- Cobertura `incidentsOnly`: feed vazio ou só com incidentes resolvidos continua
  `unknown`, nunca `operational` (regra do SDD de status).
- O feed usa `<category>Incident</category>` e manutenções; o parser RSS
  existente já trata título, link, `pubDate`, `guid` e categoria. Fixture
  verbatim do feed real entra em `Fixtures.swift` (itens de 21–28/09/2026).
- `statusPageURL` do fornecedor em `ServiceStatus.swift` → a mesma página.

## 9. Pontos de alteração no código

Checklist do CLAUDE.md, mais o que o código atual exige:

| # | Arquivo | Mudança |
|---|---|---|
| 1 | `Core/Models/VendorId.swift` | `case typesafe`; `displayName`, `symbolName` (`t.square`), `dashboardURL`, `isPrepaidOnly = true`, `reloginCommand = nil`, **novo** `reportsUtilization` |
| 2 | `Core/Models/UsageSnapshot.swift` | `TypeSafeSnapshot`, `TypeSafeModel`, case + discriminador, `windows`/`maxUtilization`/`menuBarDisplayPercentages` |
| 3 | `Core/Config/AppConfig.swift` | `TypeSafeConfig` + seção `[typesafe]` no `AppConfig` |
| 4 | `Core/Config/ConfigLoader.swift` | `defaultSnippets`, `seal`/`unseal` da chave inline, `pin_hosts` de exemplo |
| 5 | `Core/Models/ServiceStatus.swift` | `statusPageURL` |
| 6 | `Providers/TypeSafeProvider.swift` | novo, via `CachedFetch` |
| 7 | `Providers/TypeSafeWireTypes.swift` | novo |
| 8 | `Providers/RSSStatusSource.swift` + `ServiceStatusProviderFactory.swift` | descritor e registro |
| 9 | `App/AppEnvironment.swift` | `makeProviders()` e ids de status habilitados |
| 10 | `App/Views/MenuBarLabelView.swift` | `shortLabel` e pular no modo rotativo |
| 11 | `App/Views/VendorIconView.swift` | ícone |
| 12 | `App/Views/VendorSectionView.swift` | conteúdo do cartão (4.1) e toggle de fixar desabilitado |
| 13 | `App/Views/AnalyticsFormatters.swift` | case novo (fornecedor sem custo/uso: aparece como "sem dados de consumo") |
| 14 | `App/ViewModels/UsageStore.swift` | `togglePinned` recusa `reportsUtilization == false` |
| 15 | `App/Views/SettingsView.swift` + `SettingsViewModel.swift` | seção TypeSafe (ativar, chave, variável) |
| 16 | `Resources/*.lproj/Localizable.strings` | chaves novas nos três idiomas |
| 17 | `Testing/Fixtures.swift` | fixtures verbatim de `/v1/models`, erro 403 e feed RSS |
| 18 | `Validate/main.swift` | `section()` com fixture, decode, snapshot e erros |
| 19 | `scripts/validate.sh` | só se houver superfície nova de segredo em arquivo (não previsto: a chave inline já é coberta pela checagem do `config.toml` 0600) |
| 20 | `config.example.toml`, `README.md`, `CLAUDE.md` ≡ `AGENTS.md`, `CHANGELOG` | documentação em lockstep |

`PricingTable`: **sem alteração** (3.2).

## 10. UX e localização

Chaves novas (en / pt-BR / es), por exemplo:

- `typesafe_plan_label` — "Jev (TypeSafe) · API key"
- `typesafe_key_ok_fmt` — "Key valid · %d model(s)"
- `typesafe_latest_model_fmt` — "%@ (released %@)"
- `typesafe_alias_fmt` — "%@ → %@"
- `typesafe_no_usage_api` — "TypeSafe has no account usage API. See usage in the console."
- `typesafe_open_console` — "Open console"
- `typesafe_key_rejected` — "TypeSafe rejected the API key"
- `typesafe_locked_hint` — "Create a key at console.typesafe.ai and set TYPESAFE_API_KEY or api_key in [typesafe]."
- `pin_unavailable_no_usage` — "This provider reports no usage to show in the menu bar"

Datas formatadas com `L10n.effectiveLocale` (o override `ui.language` precisa
valer — defeito já corrigido uma vez no cartão de créditos).

## 11. Estratégia RED → GREEN

Cada ciclo começa com teste falhando e termina com `make validate` verde.

### Ciclo A — domínio e configuração
1. `VendorId.typesafe` com todas as propriedades; `reportsUtilization`.
2. `TypeSafeConfig`: padrão, decode TOML, `base_url` inválido (http, outro
   host, subdomínio, userinfo, porta) volta ao padrão; `api_key_env` inválido.
3. `ConfigLoader`: seção acrescentada a um arquivo sem ela, preservando edições;
   chave inline cifrada e decifrada; cifrada indecifrável → limpa.

### Ciclo B — wire type e golden test
1. Fixture verbatim de `/v1/models` (bloqueante, ver 13.1).
2. Golden test campo a campo do `TypeSafeSnapshot`.
3. Tolerância: `release_date` ausente, formato data-hora, `description` nula,
   campo extra, lista vazia, alias presente e ausente.

### Ciclo C — provider
1. `StubURLProtocol` (suite `.serialized`): 200, 401, 403 com o corpo real,
   429 com `Retry-After`, 529, 500, corpo acima do teto, timeout.
2. Cache: fresco, expirado com fallback em erro, cancelamento nos pontos
   exigidos.
3. A chave não aparece em nenhum `AppError`, log capturado ou arquivo de cache.

### Ciclo D — status
1. Fixture verbatim do feed; incidentes nas últimas 6 h; feed vazio → `unknown`.
2. Registro na factory e presença no painel quando habilitado.

### Ciclo E — app
1. `UsageStore.togglePinned(.typesafe)` recusado; `maxUtilization` global
   inalterado com o cartão aberto.
2. Modo rotativo pula o fornecedor.
3. Smoke launch com e sem chave; verificação visual do cartão (documentada na PR).

## 12. Critérios de aceite

- Com chave válida: cartão mostra "Chave válida · 2 modelos", os nomes
  `jev-latest` e `jev-preview` e a data de atualização; status aparece no painel.
- Instalação nova ou `config.toml` existente: `[typesafe]` aparece com
  `enabled = false`; cartão e status ausentes; nenhuma requisição.
- Salvar uma chave em Ajustes ativa o fornecedor e o cartão aparece no próximo
  refresh, sem reiniciar o app.
- Chave inválida: mensagem "chave recusada" localizada; nenhuma repetição em
  laço; nenhuma parte da chave em log (`log show` conferido na PR).
- Nenhuma chamada a `/v1/systemone` em nenhum caminho (teste que falha se o
  provider montar uma URL fora de `/v1/models`).
- Fixar na barra indisponível, com explicação; percentual global inalterado.
- `make validate` verde: cobertura ≥ 90% em Core+Providers, zero warnings,
  golden test presente, `CLAUDE.md` ≡ `AGENTS.md`.

## 13. Consumo e tokens — o que falta e como destravar

### 13.1 Fixture real de `/v1/models` — resolvido

Capturada em 2026-09-29 com a chave do mantenedor, por um script que lê a
chave de um arquivo `0600` e nunca a imprime (Apêndice A). Entra verbatim em
`Fixtures.swift` junto com os corpos de 401 e 403. Respondeu as duas perguntas
em aberto: a lista traz **só os aliases**, e **não há** cabeçalhos
`x-ratelimit-*`.

### 13.2 Consumo da conta — a página `console.typesafe.ai/usage`

O console mostra uso, mas isso não significa que haja uma API para o app.
Medido em 2026-09-29, sem chave:

| URL | Resposta | Leitura |
|---|---|---|
| `api.typesafe.ai/v1/models` | 403 JSON "Must supply an API key" | rota existe, exige chave |
| `api.typesafe.ai/v1/this-does-not-exist` | 404 JSON | a API responde 404 **antes** de checar a chave |
| `api.typesafe.ai/v1/usage`, `/v1/billing`, `/v1/credits`, `/v1/organization/usage` | 404 JSON | **não existem** na API pública |
| `console.typesafe.ai/usage`, `/api/usage` | 403 HTML (desafio do Cloudflare) | app web com login |

**Resultado com a chave (2026-09-29):** `GET
console.typesafe.ai/api/usage?granularity=hour` (e `=day`) com
`Authorization: Bearer <chave>` recebe **403 "Sorry, you have been blocked"**
do WAF do Cloudflare. O console barra clientes fora do navegador antes de olhar
a credencial; o app, que usa `URLSession`, receberia o mesmo bloqueio. Burlar
essa proteção (imitar navegador, resolver desafio, reaproveitar cookies
`__cf_bm`/`cf_clearance`) está fora de questão.

**Decisão:** na fase 1 o cartão mostra "Uso disponível no console" com o botão
para `console.typesafe.ai/usage`. Gasto e saldo entram pela sessão do console
na fase 2 (seção 16), que exige uma decisão explícita do mantenedor, porque
abre exceção à regra do projeto contra reutilizar sessão de navegador.

Regra de decisão, alinhada ao que o projeto já faz com o Gemini:

- **Aceito:** um endpoint que responda à **chave de API** (`Authorization:
  Bearer`), documentado ou pelo menos estável e servido em host oficial. Entra
  como fase 2 com fixture verbatim, golden test e host na allow-list.
- **Rota que exija a sessão do console** (cookie do login): não entra na
  fase 1. Por decisão do mantenedor, entra como **fase 2 opcional** (seção 16),
  com exceção explícita à regra do projeto, modo manual e o spike 16.6.
- Em qualquer caso, vale pedir à TypeSafe uma API de uso autenticada pela
  chave, que tornaria a fase 2 desnecessária.

### 13.3 Roteiro de descoberta com a chave do mantenedor

Rodado no terminal do mantenedor; a chave nunca passa pela conversa. A saída
não contém segredo (lista de modelos, cabeçalhos, códigos HTTP).

1. **Fixture de `/v1/models` e cabeçalhos** — ver 13.1.
2. **Rotas de uso com a chave** — confirma que o 404 não muda com
   autenticação (algumas APIs só roteiam depois de autenticar).
3. **Página de uso do console** — DevTools → Network → Fetch/XHR em
   `console.typesafe.ai/usage`: anotar URL, método, se o cabeçalho é
   `Authorization: Bearer <chave>` ou `Cookie`, e o formato do JSON (valores
   podem ser trocados por zeros antes de colar).

Outros caminhos, se 13.2 não fechar:

1. **API oficial de uso/cobrança** que a TypeSafe venha a publicar.
2. **Cabeçalhos de limite de taxa** em `/v1/models` (13.3 item 1): dá para
   exibir "limite de requisições/min" real, ainda sem consumo.
3. **Registro local opcional** (fora de escopo): se o usuário usar o Jev por
   um cliente que grava `usage` em disco, um scanner local somaria tokens e
   entraria na `PricingTable` a US$ 0,042/MTok — só com formato de log real.

Rejeitados: chamar `/v1/systemone` para medir, estimar consumo, contornar o
WAF do console. A sessão do console deixa de ser rejeitada e passa à fase 2.

**Ação recomendada:** pedir à TypeSafe um endpoint de uso na API pública
(`api.typesafe.ai`, autenticado pela chave). A rota `granularity=hour|day` do
console mostra que os dados já existem; se ela for exposta na API, a fase 2 é
direta.

## 14. Riscos e mitigação

| Risco | Mitigação |
|---|---|
| Produto de duas semanas; API muda | decoders tolerantes; golden test acusa mudança de schema; cache antigo continua servindo |
| Usuário espera ver consumo | aviso explícito no cartão + link para o console; README explica o porquê |
| Instabilidade da TypeSafe (5 incidentes entre 21 e 28/09) | stale fallback, back-off em 429, status no painel |
| Preço divergente em sites de terceiros | README cita só a fonte oficial, com data de verificação |
| Vazamento da chave por `base_url` | allow-list de host + validação no init e no decode |
| 401 vs 403 para chave ruim | ambos mapeados para credencial inválida |

## 15. Fora do escopo desta entrega

Chamadas de avaliação do Jev, consumo estimado, qualquer disfarce do cliente
para passar pelo WAF, importação automática de cookies do Chrome, integração
com SDKs da TypeSafe (o app fala HTTP direto, sem dependência nova) e qualquer
mudança no cálculo de custo dos outros fornecedores. A sessão manual do console
é a fase 2 (seção 16), condicionada ao spike.

## 16. Fase 2 — gasto e saldo pela sessão do console (opcional)

### 16.1 Motivação e precedente

A API pública não expõe uso, e a chave de API não autentica o console
(confirmado pela medição da seção 13 e pela documentação do CodexBar: "An
inference API key does not replace a console session"). O CodexBar mostra, para
a TypeSafe, o gasto do ciclo e o saldo de créditos lendo a página
`console.typesafe.ai/settings/billing` com a sessão do usuário. Esta fase faz o
mesmo, de forma independente (sem copiar código de terceiros).

**Exceção à regra do projeto.** O CLAUDE.md proíbe reutilizar sessão de
navegador (caso Gemini/Antigravity). Esta fase só entra com a exceção escrita
no CLAUDE.md ≡ AGENTS.md, limitada à TypeSafe e às condições abaixo.

### 16.2 O que mostra

- Uso em tokens por hora e por dia (`/api/usage`, 16.6c).
- Saldo (`balance`), gasto do ciclo (`spent`) e créditos comprados
  (`purchased`), como **dinheiro** (a página de
  cobrança mostra dólares, ao contrário dos créditos do Codex, que são
  quantidade), com o rótulo do plano quando houver.
- Créditos não zerados com mês/dia de expiração, em lista limitada.
- **Sem percentual, cota ou reset inventados.** Expiração de crédito e
  `resetsInDays` do ciclo não são reset de cota. A barra de menus continua sem
  percentual (4.2).

### 16.3 Autenticação — login dentro do app

Nenhuma credencial vem embutida: cada usuário conecta a **própria** conta. O
usuário nunca abre terminal, DevTools nem copia cookie.

**Fluxo (validado em 2026-09-29, spike 16.6b):**

1. Ajustes → TypeSafe → **"Entrar na TypeSafe"** abre uma janela do app com
   `https://console.typesafe.ai/login` num `WKWebView` com
   `WKWebsiteDataStore.nonPersistent()` (isolado de Safari/Chrome, apagado ao
   fechar).
2. O usuário passa pelo desafio do Cloudflare (é um navegador de verdade, com
   uma pessoa na frente) e entra com o provedor que usa. O login da TypeSafe é
   feito pelo **Stytch** (`api.stytch.com`), com Google; o Google **não**
   bloqueou o login na janela embutida.
3. O app observa a janela (polling de URL e do `httpCookieStore` a cada 1 s —
   o console troca de tela no cliente, sem `didFinish`). Quando os cookies
   `session`, `session_id` e `organization_id` existirem em
   `console.typesafe.ai`, o app copia **só esses três** do armazenamento da
   própria janela, fecha a janela e testa uma leitura de cobrança.
4. Sucesso → grava os três cookies cifrados (16.4) e ativa a fase 2 no cartão.

**Transparência, na própria janela e no README:** a página de login roda dentro
do app. O app não injeta script, não lê campos nem teclado e não guarda a
senha; só lê, no fim, os três cookies de sessão do armazenamento isolado da
janela. `cf_clearance`, `__cf_bm`, `_cfuvid`, `state`, `oauth_state` e os
cookies de analytics nunca são copiados.

**Duração:** os três cookies expiram **14 dias** após o login
(`expires` medido: login em 29/09, expiração em 13/10). O app guarda essa data:

- a 2 dias do fim, o cartão mostra "Sessão da TypeSafe expira em N dias" com o
  botão "Entrar de novo";
- expirada (data passada, 401/403, redirect ou tela de login), o cartão mostra
  "Sessão expirada — entrar de novo" e para de consultar o console até o novo
  login. Nada de repetir em laço.

**Por que não `WKWebsiteDataStore(forIdentifier:)`:** manteria a sessão no
WebKit entre execuções, mas só existe no macOS 14+, e o app suporta macOS 13.
Copiar os três cookies para o armazenamento cifrado do app funciona em todas as
versões e mantém uma única regra de guarda de segredo.

**Alternativa futura (fora desta fase):** "Usar a sessão do Chrome", no estilo
do CodexBar, que importa os cookies do navegador onde o usuário já está logado.
Exige decifrá-los com a chave "Chrome Safe Storage" do Keychain (pedido de
senha na primeira vez) e código de leitura do formato de cookies do Chromium.
Só entra se a janela de login deixar de funcionar ou houver demanda.

**Descartados:** colar o cabeçalho `Cookie` (UX inaceitável para o app),
User-Agent falso na janela e `ASWebAuthenticationSession` (a sessão ficaria no
Safari, inacessível ao app).

### 16.4 Guarda e uso do cookie

- É uma credencial de login completa, mais forte que a chave de API. Guardado
  cifrado no `config.toml` (SecretBox, como `api_key`), arquivo `0600`, nunca
  em log, erro, cache ou snapshot; o `DiskCache` guarda só os números já
  interpretados.
- Enviado **somente** para `https://console.typesafe.ai`, na allow-list;
  sessão `URLSession` efêmera e isolada (sem cookies do sistema), redireciona
  **nada** (um redirect é tratado como sessão expirada, mesmo no mesmo host).
- User-Agent honesto do app. Se o Cloudflare barrar a requisição com a sessão
  válida, o modo é declarado inviável — não há plano B que disfarce o cliente.
- Somente leitura: a chamada é a mesma que a página faz para exibir a cobrança;
  nada que altere a conta.

### 16.5 Protocolo — confirmado pelo código do CodexBar

Analisado em `steipete/CodexBar@25bba9b` (2026-09-28, licença MIT):
`Sources/CodexBarCore/Resources/Plugins/typesafe.ts`, `TypeSafeCookieImporter.swift`
e a camada HTTP de plugins. Reimplementamos de forma independente; nada de
código copiado.

**Cliente honesto funciona.** A camada HTTP de plugins do CodexBar não define
`User-Agent`: o `URLSession` envia o padrão do sistema
(`CodexBar/<build> CFNetwork/… Darwin/…`). Ou seja, o Cloudflare deixa passar
um cliente que se identifica como app quando a sessão é válida. O bloqueio
medido na seção 13.2 foi do `curl` levando só a chave de API, sem sessão. O
ai-taskbar usa o mesmo tipo de cliente (`URLSession`, User-Agent do app).

**Fluxo:**

1. `GET https://console.typesafe.ai/settings/billing` com `Cookie` e
   `Accept: text/html`, timeout 6 s.
2. Das tags `<script src>` da página (no máximo 60, só as do próprio host e
   terminadas em `.js`), baixar os chunks um a um (timeout 2 s) até achar o ID
   da ação: um hex de 40+ caracteres seguido, a até 150 caracteres, de
   `"getBillingOverviewResult"`. O ID fica em cache por 12 h.
3. `POST https://console.typesafe.ai/settings/billing` com `Cookie`,
   `Origin: https://console.typesafe.ai`, `Next-Action: <id>`,
   `Accept: text/x-component`, `Content-Type: application/json`, corpo `[]`,
   timeout 6 s. É a mesma leitura que a página faz para se exibir.
4. Se a resposta for **404 com `x-nextjs-action-not-found: 1`**, o ID ficou
   velho: invalida o cache, redescobre **uma** vez e repete.
5. A resposta `text/x-component` tem uma linha por registro no formato
   `<id>:<json>`. O resultado é o primeiro objeto JSON que tenha a chave `ok`.

**Forma do resultado** (a confirmar com a resposta verbatim do spike):

```json
{"ok": true, "data": {"billing": {
  "spent": 0.0, "balance": 0.0,
  "cycleLabel": "…", "plan": "free_plan",
  "credits": [{"amount": 0.0, "remaining": 0.0, "expiresAt": "…"}]
}}}
```

- `spent` e `balance` são obrigatórios e numéricos finitos; faltando ou
  malformados → falha de interpretação (nunca zero).
- `plan` vira rótulo legível (`free_plan` → "Free"; `a_b` → "A B").
- `credits`: só entram os com `remaining > 0` e `expiresAt` válido; lista
  limitada, com a contagem do excedente.
- `ok != true` → falha da API.

**Sessão expirada**, tratada como erro de credencial: 401/403, qualquer 3xx,
ou uma página 200 que seja a tela de login (o RSC traz o segmento
`"(auth)"` com `"login"`). **Indisponível**: 408, 429 (com `Retry-After`,
limitado a 10 s) e 5xx.

**Modo automático no CodexBar** usa a dependência `SweetCookieKit` e decifra os
cookies do Chrome com a chave "Chrome Safe Storage" do Keychain; o CodexBar
precisou de uma camada própria (`BrowserCookieAccessGate`) só para evitar os
pedidos de senha. Confirma a decisão de começar pelo modo manual e não trazer
dependência nova.

### 16.6 Spike — executado em 2026-09-29: viável com cliente honesto

Programa Swift com `URLSession` efêmera, sem armazenamento de cookies, sem
redirects e User-Agent `ai-taskbar/0.23.6 (macOS; +https://github.com/justoeu/ai-taskbar)`.
Enviou **apenas** os cookies de login `session`, `session_id` e
`organization_id`; ficaram de fora `cf_clearance`, `__cf_bm`, `_cfuvid` (passes
do Cloudflare emitidos ao navegador) e os de analytics (Google, PostHog, Stripe).

| Passo | Resultado |
|---|---|
| `GET /settings/billing` | 200, 140 KB, `x-powered-by: Next.js` — o Cloudflare deixou passar |
| Descoberta do ID | 31 chunks do mesmo host; ID de 42 caracteres no 17º |
| `POST` server action | 200, `text/x-component`, 61 KB, 73 linhas; resultado na linha `1:` |
| Resultado | `ok: true` |

Forma real de `data` (fixture anonimizada, 830 bytes):

- `data`: `billing`, `credits` (referência RSC `"$@…"` para `billing.credits`,
  não é dado próprio), `payments` (lista; vazia nesta conta), `hasMore`.
- `data.billing`: `spent`, `balance`, `purchased`, `freeCreditsRemaining`
  (números), `plan` (`pay_as_you_go` nesta conta), `cycleLabel`
  ("September 2026"), `resetsInDays`, `credits[]`, `autoPay` e, **dados
  pessoais**, `invoiceEmail`, `billingAddress`, `billingAddressValid`,
  `paymentMethod` (bandeira, final e validade do cartão).
- `billing.credits[]`: `id`, `amount`, `remaining` (inteiros nesta conta),
  `createdAt`, `expiresAt` (`AAAA-MM-DDTHH:MM:SSZ`), `reason`
  (`purchased_credits`), `payment` (objeto).

### 16.6b Spike — login dentro do app (2026-09-29)

Janela `WKWebView` não persistente em `console.typesafe.ai/login`, login do
mantenedor com Google, sem User-Agent customizado na janela.

| Etapa | Resultado |
|---|---|
| Desafio Cloudflare | resolvido na própria janela |
| Login | `console.typesafe.ai/login` → `api.stytch.com/v1/public/oauth/google/start` → Google → `console.typesafe.ai/auth/callback` |
| Cookies de sessão | `session`, `session_id`, `organization_id` em `console.typesafe.ai`, `httpOnly`, `secure`, expiração em 14 dias |
| Leitura de cobrança | `URLSession` com User-Agent do app e só os três cookies: página 200, ação 200, `ok: true` |

### 16.6c Uso por hora/dia pela mesma sessão (2026-09-29)

`GET https://console.typesafe.ai/api/usage?granularity=hour` (ou `=day`), com
os três cookies de sessão, `URLSession` e User-Agent do app: **HTTP 200,
`application/json`**. O console leva alguns minutos para agregar: 2 min depois
das chamadas a lista ainda vinha vazia (`{"buckets":[]}`); ~1 h depois, com
dados. Forma real (fixture anonimizada):

```json
{"buckets":[{"day":"2026-09-29T22:00:00+00:00","apiKeyId":"key_…","apiKeyName":"example-key",
             "userId":null,"userEmail":"","requests":4,"inputTokens":1521,"outputTokens":163}]}
```

- Um item por **chave de API × período**. `day` é data-hora com offset em
  `granularity=hour` e só data (`AAAA-MM-DD`) em `granularity=day`.
- `inputTokens`, `outputTokens`, `requests`: inteiros.
- **Dados pessoais:** `userEmail`, `userId` — nunca decodificados.
  `apiKeyId` não é exibido; `apiKeyName` (nome dado pelo usuário à chave) pode
  aparecer só se houver quebra por chave, e não entra em log.

O cartão soma os itens: tokens de entrada, de saída e requisições de **hoje**
(buckets por hora do dia local) e dos **últimos 7 dias** (buckets por dia), e
a série por hora alimenta a sparkline. O dinheiro continua vindo só de
`billing.spent`; o app não multiplica tokens por preço (US$ 0,042/MTok daria
cerca de US$ 0,00006 para os 1.521 tokens medidos, que o console arredonda para
US$ 0).

**Regra de dados pessoais (obrigatória):** o decoder declara **apenas**
`spent`, `balance`, `purchased`, `freeCreditsRemaining`, `plan`, `cycleLabel`,
`resetsInDays` e, de cada crédito, `amount`, `remaining`, `expiresAt`, `reason`.
`invoiceEmail`, `billingAddress`, `paymentMethod`, `payment`, `payments`, `id` e
o restante da árvore RSC nunca são decodificados, guardados em cache, logados
ou exibidos. O `DiskCache` guarda o snapshot já interpretado, não a resposta
bruta. A fixture do golden test é a versão anonimizada, e há um teste que
falha se algum desses campos aparecer no snapshot ou no cache.

**Guarda mínima:** o app extrai e guarda só `session`, `session_id` e
`organization_id`. Menos credencial guardada, e nenhum passe do Cloudflare
reaproveitado.

`resetsInDays` é o fim do ciclo de cobrança, não reset de cota: pode aparecer
como "ciclo fecha em N dias", nunca como barra ou percentual.

### 16.7 Riscos específicos

| Risco | Mitigação |
|---|---|
| Server action muda a cada deploy | redescoberta automática; falha vira "formato mudou", com cache antigo |
| Cookie vazado dá acesso total à conta | cifrado, `0600`, só para o host do console, sem log, sem redirect |
| Sessão expira a cada 14 dias | aviso 2 dias antes e botão "Entrar de novo"; parar de consultar quando expirada |
| Termos de uso da TypeSafe | somente leitura, cadência do refresh normal (5 min), User-Agent honesto |
| Google passar a bloquear login embutido | alternativa "Usar a sessão do Chrome" (16.3); o cartão da fase 1 continua funcionando |
| Stytch ou o console mudarem o fluxo | a detecção depende só dos três cookies de sessão, não de URLs intermediárias |

## Apêndice A — respostas reais (2026-09-29)

`GET https://api.typesafe.ai/v1/models` com chave válida — HTTP 200:

```json
{"models":[{"name":"jev-latest","description":"The latest iteration of TypeSafe's System One Model: Jev","release_date":"2026-09-10T18:38:01.391457+00:00"},{"name":"jev-preview","description":"A preview version of `jev-latest`: should be better in most ways","release_date":"2026-09-10T18:39:06.057655+00:00"}]}
```

Sem chave — HTTP 403:

```json
{"detail":{"error_type":"authentication_error","message":"Must supply an API key! Check your request and try again."}}
```

Chave inválida — HTTP 401:

```json
{"detail":{"error_type":"authentication_error","message":"Cannot authenticate with the server. Please check your API key and try again."}}
```

Rota inexistente — HTTP 404 (roteamento antes da autenticação):

```json
{"detail":"Not Found"}
```

Cabeçalhos da resposta 200: `content-type: application/json`, `server:
cloudflare`, `x-typesafe-request-id`, `x-envoy-upstream-service-time`,
`cf-cache-status`, `cf-ray`. Nenhum cabeçalho de limite de taxa.


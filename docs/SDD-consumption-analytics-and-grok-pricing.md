# SDD — Visão Geral de Consumo (Analytics), Pricing do Grok 4.7 e Melhorias de UI

**Status:** Proposto / Especificação para Implementação  
**Data:** 2026-09-21  
**Branch Alvo:** `feature/consumption-analytics`  
**Plataforma:** macOS 13+, Swift 6, SwiftUI `MenuBarExtra(.window)`  
**Autor:** Antigravity & Pair Programming  

---

## 1. Resumo Executivo

Este documento especifica a implementação de quatro grandes frentes evolutivas no **AI Taskbar**:

1. **Visão Geral de Consumo (Analytics Dashboard):** Nova tela interna no popover dedicada a métricas e gráficos de consumo e custo entre todos os LLMs configurados:
   - Gráfico de donut/pizza de **distribuição de uso (%)** à esquerda.
   - Gráfico de donut de **custo total ($)** à direita com valor consolidado no centro e legenda detalhada por LLM com valores absolutos (idêntico à referência visual do usuário).
   - Filtros temporais: **Diário** (Hoje vs Ontem), **Semanal** (Semana atual vs Semana anterior) e **Mensal** (Mês atual vs Mês anterior).
   - Detalhamento por LLM com destaque para o **dia de maior uso com ícone de fogo (`🔥`)**, quantidade de sessões abertas e quebra de custo por modelo específico.
2. **Pricing do Grok 4.7 e Expansão xAI:**
   - Incorporação da nova família **Grok 4.7** no `PricingTable` ($2.00/MTok input, $0.50/MTok cache read, $6.00/MTok output) e cobertura das variantes xAI nos scanners de custo locais.
3. **Análise de Custos e Consumo do Gemini:**
   - Tratamento das peculiaridades do Gemini (Google AI Studio vs Antigravity), viabilizando leitura de volume de tokens e estimativa financeira via tabela de preços dedicada e scanners compatíveis (como Opencode).
4. **Reestruturação e Ergonomia da UI:**
   - Reordenação da barra de ferramentas superior do popover:
     `[Refresh]` → `[Status de Serviço]` → `[Gráficos/Analytics]` → `[About]`.
   - Remoção do botão de saída ("Power/Sair") do rodapé do popover.
   - Adição de uma seção dedicada de encerramento dentro da tela de **About**, com modal de confirmação obrigatório antes de fechar o app.

---

## 2. Objetivos e Não-Objetivos

### 2.1 Objetivos

1. Criar a tela `AnalyticsView` integrada ao sistema de overlays existente (`Overlay.analytics`), mantendo a experiência nativa dentro do `MenuBarExtra`, sem janelas flutuantes desconectadas.
2. Implementar componentes visuais de gráfico de donut (`DonutChartView`) puramente em SwiftUI, compatíveis com macOS 13+ (sem depender de APIs exclusivas do macOS 14 como `SectorMark`).
3. Suportar três granularidades temporais de análise: **Diário**, **Semanal** e **Mensal**, permitindo comparação entre períodos (semana vs semana, mês vs mês).
4. Expandir o `UsageHistoryStore` para reter até 90 dias de histórico (em vez de 7 dias), permitindo análises mensais robustas.
5. Identificar e destacar visualmente o **pico de consumo (maior dia)** de cada LLM com indicador de fogo (`🔥` / `flame.fill`).
6. Quantificar o número de sessões ativas/abertas e a quebra de custo por modelo (ex: Sonnet vs Opus, Sol vs Terra, Grok 4.7).
7. Incorporar o modelo `grok-4.7` e família no `PricingTable` e scanners.
8. Prover estimativas financeiras para modelos Gemini (`gemini-2.5-flash`, `gemini-2.5-pro`, `gemini-1.5-pro`, `gemini-1.5-flash`).
9. Reordenar a barra superior e mover o encerramento do app para dentro de `AboutView` com confirmação (`confirmationDialog`/`alert`).
10. Manter a política mandatória de **cobertura de linhas ≥ 90%** em `AiTaskbarCore` + `AiTaskbarProviders` e **zero compiler warnings**.

### 2.2 Não-Objetivos

- Não criar daemons em background externos ao app.
- Não transmitir métricas de uso ou telemetria para servidores externos; todo o cálculo é 100% local e on-device.
- Não introduzir dependências pesadas de terceiros para gráficos; usar desenho nativo vetorial em SwiftUI (`Shape`, `Path`, `StrokeStyle`).
- Não modificar o contrato estável das wire types já congeladas dos vendors.

---

## 3. Arquitetura e Engenharia de Dados

### 3.1 Modelo de Dados Unificado de Analytics

Criaremos no módulo `AiTaskbarCore` os seguintes modelos formais:

```swift
// Em Sources/AiTaskbarCore/Models/AnalyticsModels.swift

public enum AnalyticsTimeframe: String, CaseIterable, Identifiable, Sendable {
    case daily
    case weekly
    case monthly

    public var id: String { rawValue }
}

public struct VendorAnalyticsSummary: Sendable, Equatable, Identifiable {
    public var id: VendorId { vendor }
    public let vendor: VendorId
    public let planLabel: String?
    public let totalCostUSD: Double
    public let totalUsagePercent: Double
    public let sessionCount: Int
    public let peakDay: PeakDayRecord?
    public let costByModel: [String: Double]
    public let usageHistory: [UsageHistoryStore.Sample]
    public let deltaPreviousPeriodPercent: Double?
}

public struct PeakDayRecord: Sendable, Equatable {
    public let date: Date
    public let costUSD: Double
    public let utilizationPercent: Double
    public let isHistoricalPeak: Bool
}

public struct GlobalAnalyticsSnapshot: Sendable, Equatable {
    public let timeframe: AnalyticsTimeframe
    public let compareWithPrevious: Bool
    public let totalCostUSD: Double
    public let vendorShares: [VendorShare]
    public let vendorSummaries: [VendorAnalyticsSummary]
    public let computedAt: Date
}

public struct VendorShare: Sendable, Equatable, Identifiable {
    public var id: VendorId { vendor }
    public let vendor: VendorId
    public let percentage: Double
    public let costUSD: Double
    public let colorIndex: Int
}
```

### 3.2 Expansão do `UsageHistoryStore`

O `UsageHistoryStore` atualmente opera com `retention: TimeInterval = 7 * 86_400`.  
Para acomodar as visões semanais e mensais com comparativo (mês atual vs mês anterior), a retenção padrão será elevada para:

```swift
public static let defaultRetention: TimeInterval = 90 * 86_400 // 90 dias
```

As operações de `append` e `compact` continuam otimizadas com I/O atômico e mutex `OSAllocatedUnfairLock`.

### 3.3 Agregação Multi-Fonte (`AnalyticsAggregator`)

Criaremos o `AnalyticsAggregator` (em `AiTaskbarCore/Cost/` ou `AiTaskbarApp/ViewModels/`) que sintetiza três fontes de dados:

1. **`UsageHistoryStore`**: Séries temporais de percentual de quota (`maxUtilization`) por vendor.
2. **`CostEstimator`** (`ClaudeSessionScanner` e `CodexSessionScanner`):
   - Sessões locais parseadas em `~/.claude/projects/` e `~/.codex/sessions/`.
   - Extração do número de sessões (`sessionCount`), timestamps e turns para determinação do dia de pico (`peakDay`).
   - Custo agregado por modelo (`costByModel`).
3. **`OpencodeScanner`**:
   - Mensagens da base SQLite (`opencode.db`) filtradas pelos timestamps da janela (`daily`, `weekly`, `monthly`).
   - Sessões distintas (`COUNT(DISTINCT session_id)`).
   - Agregação por provedor (`openai`, `anthropic`, `xai`, `gemini`, `zai`).
4. **`VendorSnapshot`** direto (para provedores puramente de quota ou pré-pago sem scanner local, como OpenRouter e Kimi).

---

## 4. Atualização de Modelos e Tabelas de Preços

### 4.1 Grok 4.7 na `PricingTable`

O modelo **Grok 4.7** foi lançado oficialmente pela xAI em 21 de setembro de 2026, projetado para tarefas complexas de raciocínio e engenharia de software com 500k de contexto.

Adicionaremos a tabela `PricingTable.xai` em `Sources/AiTaskbarCore/Cost/PricingTable.swift`:

```swift
/// xAI — Grok family. Consumed by local scanners and Opencode attribution.
/// Prices in USD per 1M tokens as of 2026-09-21.
public static let xai: [String: ModelPricing] = [
    // Grok 4.7 — Flagship frontier model with reasoning effort levels.
    "grok-4.7":           ModelPricing(input: 2.0, output: 6.0, cacheRead: 0.50),
    "grok-4.7-thinking":  ModelPricing(input: 2.0, output: 6.0, cacheRead: 0.50),
    "grok-4.7-code":      ModelPricing(input: 2.0, output: 6.0, cacheRead: 0.50),
    // Grok 4.x / Grok 4
    "grok-4":             ModelPricing(input: 2.0, output: 6.0, cacheRead: 0.50),
    // Grok 2 line
    "grok-2":             ModelPricing(input: 2.0, output: 10.0, cacheRead: 0.50),
    "grok-2-mini":        ModelPricing(input: 0.20, output: 1.0, cacheRead: 0.05),
    "grok-beta":          ModelPricing(input: 5.0, output: 15.0),
]
```

### 4.2 Suporte a Custos e Consumo do Gemini

O Google Generative Language API (`generativelanguage.googleapis.com`) não provê endpoint REST público de billing/consumo financeiro por chave.  
No entanto, quando o usuário utiliza Gemini via CLI local, scripts ou clientes integrados como Opencode, tokens são consumidos e passíveis de custeio.

Adicionaremos a tabela `PricingTable.gemini` em `Sources/AiTaskbarCore/Cost/PricingTable.swift`:

```swift
/// Google Gemini family. Consumed by Opencode and local scanners.
/// Prices in USD per 1M tokens based on Google Cloud official pricing.
public static let gemini: [String: ModelPricing] = [
    // Gemini 2.5 Pro (Prompt <= 128k: $1.25 in / $5.00 out; > 128k: $2.50 in / $10.00 out)
    "gemini-2.5-pro":     ModelPricing(input: 1.25, output: 5.00, cacheRead: 0.3125,
                                       longContextThreshold: 128_000,
                                       longContextInputMultiplier: 2.0,
                                       longContextOutputMultiplier: 2.0),
    // Gemini 2.5 Flash
    "gemini-2.5-flash":   ModelPricing(input: 0.075, output: 0.30, cacheRead: 0.01875),
    // Gemini 1.5 Pro
    "gemini-1.5-pro":     ModelPricing(input: 1.25, output: 5.00, cacheRead: 0.3125,
                                       longContextThreshold: 128_000,
                                       longContextInputMultiplier: 2.0,
                                       longContextOutputMultiplier: 2.0),
    // Gemini 1.5 Flash
    "gemini-1.5-flash":   ModelPricing(input: 0.075, output: 0.30, cacheRead: 0.01875),
]
```

- Adicionaremos o mapeamento do provedor `"gemini"` e `"google"` no `OpencodeScanner.opencodeProviders`.
- No card do Gemini e no Analytics Dashboard:
  - Se houver uso de tokens registrado (via Opencode/CLI), exibimos a contagem de tokens e o valor financeiro estimado.
  - No modo Antigravity puro, exibimos o percentual consumido da quota (5h e semanal) com aviso amigável de que quotas de assinatura cobrem o consumo sem faturamento marginal direto.

---

## 5. Especificação de Interface (UI/UX)

### 5.1 Reordenação da Barra Superior do Popover

No arquivo `Sources/AiTaskbarApp/Views/PopoverContentView.swift`, a barra superior de ações no canto direito passa a ter a ordem:

```text
[Countdown "Próx. em 4:32"]  |  [1. Refresh]  [2. Status]  [3. Analytics]  [4. About]
```

- **1. Refresh (`arrow.clockwise`):** Executa `store.refreshAll(forceRefresh: true)`.
- **2. Status (`waveform.path.ecg` com dot de status):** Abre o painel de status operacional (`overlay = .status`).
- **3. Analytics (`chart.pie.fill` ou `chart.xyaxis.line`):** Abre a nova tela de gráficos (`overlay = .analytics`).
- **4. About (`info.circle`):** Abre as informações sobre o app e botão de saída (`overlay = .about`).

### 5.2 Limpeza do Rodapé e Sair com Confirmação no About

1. **Rodapé (`footerBar`):**
   - Removido o botão vermelho de encerramento (`onQuit()`).
   - O rodapé passa a conter apenas:
     - Botão de **Configurações** (`gearshape`).
     - Toggle de **Abrir no Login**.
2. **`AboutView.swift`:**
   - Adicionada uma nova seção visual no final:
     ```swift
     Button(role: .destructive) {
         showQuitConfirmation = true
     } label: {
         Label(L10n.localizedString("quit_app"), systemImage: "power")
             .foregroundStyle(.red)
     }
     ```
   - Ao clicar, exibe um alerta de confirmação em conformidade com as diretrizes da Apple:
     - **Título:** *"Deseja realmente fechar o AI Taskbar?"*
     - **Mensagem:** *"O monitoramento contínuo das quotas na barra de menu será interrompido."*
     - **Botões:**
       - `"Cancelar"` (Default / Dismiss).
       - `"Fechar App"` (Destructive → `NSApplication.shared.terminate(nil)`).

### 5.3 Tela de Gráficos e Analytics (`AnalyticsView.swift`)

A nova tela será implementada em `Sources/AiTaskbarApp/Views/AnalyticsView.swift`.

#### A. Cabeçalho e Seletores de Período
- Segmented Control estilizado:
  - `[ Hoje / Diário ]`
  - `[ Semana ]`
  - `[ Mês ]`
- Toggle comparativo:
  - `Comparar com período anterior (Semana vs Semana / Mês vs Mês)`.

#### B. Seção Superior (Dual Donut Charts)
Dispostos lado a lado (em `HStack` responsivo):
1. **Donut Esquerdo (Distribuição de Uso):**
   - Segmentos coloridos correspondendo à fatia de cada LLM ativo no total de requisições / utilização.
   - Centro com o volume total de interações ou percentual médio.
2. **Donut Direito (Custo Total em Dinheiro - Conforme Screenshot):**
   - Centro do donut destacando o valor total em destaque: `$XX.XX` (ou `$13.4K` para valores expressivos).
   - Legenda vertical à direita:
     - Ponto colorido de cada LLM (Claude: Laranja, OpenAI: Verde esmeralda, Grok: Roxo/Cinza, Gemini: Azul, Z.AI: Turquesa, etc.).
     - Nome do provedor.
     - Valor monetário formatado (`$7,121.12`, `$134.46`, etc.).

#### C. Seção Inferior (Cards dos LLMs)
Cards organizados em `VStack` dentro de um `ScrollView`:
Para cada LLM ativo:
- **Cabeçalho do Card:** Nome do LLM, ícone e badge com percentual/custo total no período.
- **Pico de Uso (`🔥`):**
  - Identificação clara do dia com maior consumo:
    `🔥 Dia mais movimentado: 18 de Setembro ($42.10 / 84% quota)`.
- **Estatísticas de Sessão:**
  - Quantidade de sessões abertas e turnos registrados.
- **Quebra por Modelo (`costByModel`):**
  - Lista de barras horizontais compactas com a porcentagem e valor gasto por modelo individual (ex: `claude-sonnet-4-6`: $14.20, `claude-opus-4-7`: $28.00).
- **Indicador de Tendência:**
  - Delta versus o período anterior: `↑ +14% em relação à semana anterior` (em vermelho/laranja) ou `↓ -5%` (em verde).

---

## 6. Plano de Implementação Passo a Passo

A implementação será guiada por TDD rigoroso e executada pela skill `make-me-happy`:

### Fase 1: Core Domain, Modelos e Pricing
- **Task 1.1:** Criar `Sources/AiTaskbarCore/Models/AnalyticsModels.swift` com os tipos `GlobalAnalyticsSnapshot`, `VendorAnalyticsSummary`, `PeakDayRecord`, `AnalyticsTimeframe`.
- **Task 1.2:** Adicionar `grok-4.7` e modelos Grok em `PricingTable.swift` (tabela `xai`).
- **Task 1.3:** Adicionar modelos Gemini em `PricingTable.swift` (tabela `gemini`).
- **Task 1.4:** Atualizar `UsageHistoryStore` para retenção padrão de 90 dias e adicionar método de agregação temporal (`samples(between:and:)`).
- **Task 1.5:** Criar testes unitários em `Tests/AiTaskbarCoreTests/AnalyticsModelsTests.swift` e `PricingTableTests.swift`.

### Fase 2: Agregador de Analytics e Scanners
- **Task 2.1:** Implementar `AnalyticsAggregator` em `AiTaskbarCore/Cost/` consolidando `UsageHistoryStore`, `CostEstimator` e `OpencodeScanner`.
- **Task 2.2:** Adicionar identificação algorítmica de `peakDay` com cálculo do dia de maior gasto/uso.
- **Task 2.3:** Integrar provedor Gemini no `OpencodeScanner`.
- **Task 2.4:** Criar `AnalyticsStore` (`@MainActor ObservableObject`) para consumo reativo em SwiftUI.
- **Task 2.5:** Testes unitários completos em `Tests/AiTaskbarCoreTests/AnalyticsAggregatorTests.swift`.

### Fase 3: Componentes de Visualização (Donut & Gráficos)
- **Task 3.1:** Criar `DonutChartView.swift` com suporte a fatias proporcionais, cores personalizadas por vendor e texto customizado no centro.
- **Task 3.2:** Criar `AnalyticsTimeframePicker.swift` para alternância suave entre Diário, Semanal e Mensal.
- **Task 3.3:** Criar `VendorAnalyticsCardView.swift` com badge de fogo (`🔥`) para o dia de pico, contagem de sessões e lista de custos por modelo.
- **Task 3.4:** Montar `AnalyticsView.swift` integrando a visão geral superior (dois donuts) e a lista inferior de cards.

### Fase 4: Reordenação da Toolbar e Sair com Confirmação
- **Task 4.1:** Atualizar `PopoverContentView.swift`:
  - Reordenar toolbar superior: `Refresh` → `Status` → `Analytics` → `About`.
  - Conectar botão `chart.pie.fill` para acionar `overlay = .analytics`.
  - Remover botão `quit` de `footerBar`.
- **Task 4.2:** Atualizar `AboutView.swift`:
  - Adicionar botão de encerramento do app.
  - Implementar o alerta de confirmação com opções `"Cancelar"` e `"Fechar App"`.
- **Task 4.3:** Adicionar chaves de localização em `en`, `pt-BR` e `es` nos arquivos `Localizable.strings`.

### Fase 5: Validação, Regressão e Smoke Launch
- **Task 5.1:** Atualizar `AiTaskbarValidate/main.swift` com asserções de sanidade do Grok 4.7 e cálculos de analytics.
- **Task 5.2:** Executar `make validate` (garantir cobertura ≥ 90%, 0 warnings, smoke launch OK e permission audit OK).
- **Task 5.3:** Atualizar `README.md` e `CHANGELOG.md` conforme as políticas do projeto.

---

## 7. Critérios de Aceite e Verificação

| Item | Critério de Aceite |
|---|---|
| **Donut Charts** | Dois gráficos no topo: à esquerda distribuição percentual de uso; à direita custo total em dólares com valor no centro e legenda por LLM com valores absolutos. |
| **Filtros Temporais** | Diário, Semanal e Mensal funcionando com atualização reativa de todos os dados e opção de comparar períodos anteriores. |
| **Dia de Maior Uso** | Ícone de fogo (`🔥`) renderizado com destaque sobre a data e valor do dia recorde de uso de cada LLM. |
| **Sessões e Modelos** | Quantidade de sessões abertas e custo segmentado por modelo exibidos em cada card. |
| **Grok 4.7** | Modelo `grok-4.7` precificado a $2.00 in / $0.50 cache / $6.00 out na tabela e computado nos scans. |
| **Custo Gemini** | Tabela de preços oficial do Gemini incluída e tokens/custos calculados quando detectados. |
| **Ordem dos Ícones** | Cabeçalho: Refresh (1º), Status (2º), Analytics (3º), About (4º). |
| **Sair do App** | Rodapé limpo sem botão de fechar; botão de encerramento em About com diálogo modal de confirmação. |
| **Qualidade & Gates** | `make validate` verde, zero warnings no compilador, cobertura de testes mantida ≥ 90%. |

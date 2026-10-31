# SDD — Várias contas do Claude na mesma máquina

**Status:** implementado (2026-10-30)
**Data:** 2026-10-30
**Branch:** `feat/claude-multi-account`
**Plataforma:** macOS 13+, Swift 6 (concorrência estrita)

## 1. Resumo

Uma pessoa pode ter mais de uma conta do Claude na mesma máquina (pessoal e
trabalho, por exemplo). Hoje o app enxerga **uma**: lê só o item
`Claude Code-credentials` do Keychain e só percorre `~/.claude/projects`. A
segunda conta não aparece em lugar nenhum: nem a quota, nem o custo.

Este SDD descreve como o app **descobre sozinho** 1, 2, 3… N contas a partir do
que o próprio Claude Code grava, e como as mostra: **agrupadas no card do
Claude, com navegação lateral entre contas**, cada uma com identidade própria
(cache, histórico, notificações, pin na barra de menus), tanto na página
principal quanto na de gráficos.

## 2. Como o Claude Code separa contas (medido em 2026-10-30)

Nada disso está documentado pela Anthropic; foi medido com o CLI real.

1. **Uma conta = uma pasta de configuração.** A conta padrão usa `~/.claude`
   (com o arquivo de configuração em `~/.claude.json`, **fora** da pasta).
   Cada conta extra usa a pasta apontada por `CLAUDE_CONFIG_DIR`, com o
   arquivo de configuração **dentro** dela (`<pasta>/.claude.json`).
2. **A credencial fica num item do Keychain cujo nome deriva da pasta:**
   `Claude Code-credentials` para a padrão, e
   `Claude Code-credentials-<h>` para as demais, onde `<h>` são os 8
   primeiros caracteres hexadecimais do SHA-256 do caminho absoluto da pasta,
   sem barra final. Verificado contra um item real criado pelo CLI; os testes
   fixam a regra num caminho fictício (`/Users/example/.claude-work` →
   `dd1118a7`).
3. **Os identificadores de plano não dizem qual conta é qual.** As duas contas
   medidas têm o mesmo `subscriptionType` / `rateLimitTier`. O que
   distingue uma conta é `oauthAccount.accountUuid` no `.claude.json` da pasta.
4. **O Keychain acumula itens órfãos.** Pode haver vários itens com sufixo
   para pastas que já não existem: vêm de pastas temporárias (ferramentas que
   rodam agentes com `CLAUDE_CONFIG_DIR` próprio). Uma pasta de backup copiada
   (`~/.claude-backup-…`) pode ter `.claude.json` sem item no Keychain.
5. **A ACL do item extra é a mesma do item padrão.** O item
   `Claude Code-credentials-<h>` tem `/usr/bin/security` como app confiável e a partição
   `apple-tool:`, porque é o mesmo CLI que grava os dois com a mesma
   ferramenta. Logo, a leitura somente leitura via `/usr/bin/security` que já
   evita prompts na conta padrão vale para as contas extras (é o caso que o
   CLAUDE.md permite: item gravado pelo seu CLI **com** `/usr/bin/security`).
6. **O uso fica na pasta da conta:** `<pasta>/projects/**/*.jsonl`. Hoje o
   scanner de custo só lê `~/.claude/projects`, então o uso das contas extras
   nunca entrou no custo.

## 3. Fora de escopo

- Troca a quente do conjunto de contas. Os providers são montados uma vez na
  inicialização (como o resto da config); uma conta nova ou deslogada aciona
  o aviso "reinicie para aplicar" que já existe (§6.6).
- Renomear contas nas Configurações e esconder uma conta descoberta: ficam
  para depois. O rótulo vem do nome da pasta (§4.4).
- Contas de API (`sk-ant-…`) e `.credentials.json` em texto puro: o app não
  as usa hoje e continua não usando.
- Outros vendors com várias contas: o modelo de instância (§5) é genérico,
  mas só o Claude ganha descoberta agora.

## 4. Descoberta de contas (`ClaudeAccountDiscovery`, Core)

Pura sobre um sistema de arquivos e uma sonda de Keychain injetados, para ser
testável sem tocar no Keychain real.

### 4.1 Candidatas

1. `~/.claude` (sempre candidata; configuração em `~/.claude.json`).
2. Toda entrada da home cujo nome case `^\.claude[-_.][A-Za-z0-9._-]+$` e seja
   **diretório** (não o arquivo `.claude.json` nem seus backups). Cada pessoa
   nomeia como quiser: `.claude-trabalho`, `.claude_2`, `.claude.pessoal`.
3. `CLAUDE_CONFIG_DIR` do ambiente do app, se definido (raro num app de menu,
   mas barato).
4. `config_dirs` em `[anthropic]` na config: lista opcional de caminhos fora
   da home.

### 4.2 Validação (todas obrigatórias)

1. O `.claude.json` da candidata existe, é arquivo regular, tem até 16 MiB e
   decodifica `oauthAccount.accountUuid` não vazio. **Só esse campo é
   decodificado** (allow-list): e-mail, organização e o resto ficam de fora.
2. O item do Keychain correspondente existe. A sonda pergunta só pelos
   **atributos** (`kSecReturnAttributes`, sem `kSecReturnData`), dentro de
   `KeychainPromptSuppressor.withPromptsSuppressed` e com
   `kSecUseAuthenticationUIFail`: não lê o segredo e não pode abrir prompt.
   Para tolerar uma variável definida com barra final, a sonda tenta o hash
   do caminho com e sem a barra.

Isso descarta sozinho os itens órfãos (sem pasta) e os backups (sem item).

### 4.3 Deduplicação

Duas pastas com o mesmo `accountUuid` são a mesma conta: fica uma só. Vence a
pasta padrão; entre extras, a de item do Keychain modificado mais
recentemente (`kSecAttrModificationDate`), e depois o caminho em ordem
lexicográfica, para o resultado ser determinístico.

### 4.4 Identidade e rótulo

- **Chave da instância:** a conta da pasta padrão usa a chave legada
  `anthropic`, para que quem tem uma conta só não perca nada (§7). Cada conta
  extra usa `anthropic.<k>`, com `<k>` = 8 hexadecimais do SHA-256 do
  `accountUuid`. Derivar da conta, não do caminho, mantém histórico e pin se a
  pasta for renomeada; o UUID em si nunca vai para disco nem para log.
- **Rótulo:** "principal" para `~/.claude` (localizado), e o sufixo do nome da
  pasta para as demais (`.claude-work` → "work"); para uma pasta fora da
  home, o último componente do caminho.
- **Ordem:** a padrão primeiro, depois as extras por rótulo.

## 5. Modelo de instância

Hoje `VendorId` é ao mesmo tempo "qual vendor" (apresentação, formato do
snapshot, preços, página de status) e "qual card". O app passa a separar:

```swift
public struct ProviderInstanceKey: Hashable, Codable, Sendable {
    public let vendor: VendorId
    public let account: String?          // nil = instância única/legada
    public var storageKey: String        // "anthropic" | "anthropic.1a2b3c4d"
}
```

- `UsageProvider` ganha `instanceKey` (padrão: `vendor` com `account == nil`)
  e `accountLabel: String?` (padrão `nil`). Todo provider existente continua
  igual; só o `AnthropicProvider` recebe conta.
- **Tudo que é estado ou persistência passa a usar `storageKey`:** cache em
  disco, histórico, pins, notificações, rastreio de busca em andamento.
- **Tudo que é apresentação continua por `VendorId`:** nome, ícone, cor,
  preços, página de status, ordem dos cards.

## 6. Comportamento por subsistema

### 6.1 Providers (`AppEnvironment.makeProviders`)

Um `AnthropicProvider` por conta descoberta, cada um com:
- `KeychainCredentialReader(service:)` do item da conta. A conta padrão mantém
  o comportamento atual (`keychain_service` / `keychain_account` da config e
  a escolha do token mais novo entre entradas do item base). As extras usam o
  item com sufixo, que tem uma entrada só.
- `DiskCache` em `Caches/ai-taskbar/<storageKey>/`.
- Somente leitura, como hoje (`manage_oauth_refresh` vale só para a conta
  padrão; contas extras nunca renovam token).
- Comando de novo login por conta:
  `CLAUDE_CONFIG_DIR=<pasta> claude auth login` para as extras.

Se a descoberta falhar ou não achar nada, o app monta o provider padrão
exatamente como hoje (sem regressão para quem tem uma conta).

### 6.2 `UsageStore` e grupos

- `vendors` continua sendo a lista de `VendorViewModel`, agora **um por
  instância**. Os mapas internos passam de `VendorId` para `storageKey` (o
  `Dictionary(uniqueKeysWithValues:)` atual derrubaria o app com duas
  instâncias `.anthropic`).
- Novo `vendorGroups: [VendorGroup]` (id = `VendorId`, membros na ordem do
  §4.4) alimenta a lista de cards. `VendorOrder` ordena **grupos**, não
  instâncias, então a ordem salva continua valendo.
- A conta selecionada em cada grupo fica em `UserDefaults`
  (`selected_account_<vendor>` = `storageKey`).
- Recolher o card recolhe o grupo: todos os membros compartilham a chave
  `expanded_<vendor>`. O % da barra de menus considera **todas** as contas de
  um grupo aberto, não só a visível, porque esconder uma conta esgotada atrás
  do seletor mentiria sobre o estado.

### 6.3 Card agrupado (página principal)

- Com uma instância, o card fica exatamente como hoje.
- Com duas ou mais, abaixo do cabeçalho aparece um seletor (‹ • • rótulo ›):
  setas que dão a volta e um ponto por conta. O rótulo do plano continua só o
  plano ("Ultra"), porque o nome da conta já está no seletor. O corpo é a
  visão completa da conta selecionada: barras, Authorize, erro, sparkline,
  custo.
- Um indicador discreto no seletor marca uma conta **não visível** que está
  com erro, bloqueio de Keychain ou acima do limiar de alerta.

### 6.4 Página de gráficos

- Totais por vendor continuam sendo a soma das contas (o gráfico de
  participação e o ranking não mudam de forma).
- O card do Claude ganha o mesmo seletor, com uma posição extra "Todas"
  (padrão) e uma por conta, cada uma com sua série diária, custo e dia mais
  movimentado. Em "Todas", custo e tokens são a soma; percentual de cota não
  soma, então snapshot e histórico vêm de UMA conta, a mais usada
  (`AnalyticsStore.quotaAccount`; empate → a padrão).

### 6.5 Custo (`ClaudeSessionScanner`)

- Percorre `projects/` de **todas** as contas descobertas, atribuindo cada
  linha à conta da pasta onde está.
- A deduplicação por `message.id` + `requestId` passa a ser global entre as
  pastas, para que uma cópia da mesma resposta em duas pastas nunca conte duas
  vezes.
- O `CostEstimator` expõe o total do vendor (soma) e o detalhe por
  `storageKey`.

### 6.6 Descoberta em execução

A descoberta roda na inicialização. Cada vez que o popover abre, o app refaz
a descoberta fora da thread principal (barato: listar a home, ler alguns
`.claude.json`, uma consulta de atributos ao Keychain por candidata) e, se o
**conjunto de chaves** mudou, mostra o aviso "reinicie para aplicar" que já
existe, com o texto "As contas do Claude mudaram". O aviso só é visto com o
popover aberto, então checar a cada ciclo do agendador não acrescentaria nada.

### 6.7 Pins, notificações e barra de menus

- Pin por CARD (revisto após o uso real): fixar o Claude cria um único item
  na barra, que mostra a conta que o card está mostrando; navegar entre as
  contas troca o percentual do item. `pinned_menu_bar_vendors` guarda ids de
  vendor (como antes do multi-conta) e o `autosaveName` continua
  `ai-taskbar.pinned.<vendor>`. Valores por conta gravados por builds
  anteriores (`anthropic.<k>`) viram o vendor. Um pin sem instância nesta
  execução mantém o registro, mas não cria item vazio.
- Notificação por instância: chave do rastreador `(storageKey, janela)` e
  identificador `ai-taskbar.<storageKey>.<janela>.<limiar>` (igual ao atual
  para a padrão); o título inclui o rótulo ("Claude · work").
- Rótulo curto na barra de menus: "Cl" para a padrão e "Cl·" + inicial do
  rótulo para as extras.

### 6.8 Status do serviço

Continua por vendor. A ordem que a página de status recebe da principal passa
a ser a dos grupos, sem duplicatas.

## 7. Compatibilidade

Quem tem uma conta só não vê nenhuma diferença, e nada é migrado: a conta da
pasta padrão usa a chave `anthropic`, então cache (`Caches/ai-taskbar/anthropic/`),
histórico (`history/anthropic.jsonl`), pin, `autosaveName`, `expanded_anthropic`
e identificadores de notificação continuam os mesmos. Testes fixam essas
chaves legadas.

Se a conta da pasta padrão for deslogada e só houver extras, não existe
instância `anthropic`; o histórico legado fica no disco, intocado.

## 8. Segurança

- A descoberta não lê segredo nenhum: só atributos do Keychain e o
  `accountUuid` do `.claude.json`.
- A leitura do token de cada conta segue todas as regras atuais do
  `KeychainCredentialReader` (supressão de prompt, `UIFail`, fallback de
  `/usr/bin/security` só para leitura, com argumentos exatos). A extensão do
  fallback aos itens com sufixo se apoia na medição do §2.5 e entra no
  CLAUDE.md.
- Caminhos vindos da config (`config_dirs`) passam pela mesma validação das
  candidatas: diretório real, `.claude.json` regular e de tamanho limitado.
  Nenhum caminho vira URL de rede.
- O `accountUuid` nunca é gravado nem logado; só o seu hash curto compõe
  `storageKey`.

## 9. Testes

- `ClaudeAccountDiscoveryTests` com pastas temporárias e sonda de Keychain
  falsa: conta padrão, extras com nomes variados, órfãos ignorados, backup sem
  item ignorado, `.claude.json` sem login ignorado, deduplicação por
  `accountUuid`, barra final, `config_dirs`, ordem e rótulos, hash do serviço
  (vetor fixo num caminho fictício: `/Users/example/.claude-work` → `dd1118a7`).
- Chaves legadas fixadas: instância padrão → `anthropic` em cache, histórico,
  pin, notificação e `autosaveName`.
- `UsageStore` com duas instâncias `.anthropic`: não cai, agrupa, ordena,
  seleciona, pin e foco resolvem a instância certa.
- Notificações: duas contas cruzando a mesma janela geram dois alertas com
  identificadores distintos.
- Scanner com duas raízes: atribuição por conta e deduplicação global.

## 10. Fases

1. **Core:** descoberta, `ProviderInstanceKey`, scanner com várias raízes.
2. **Providers/App:** `instanceKey` no protocolo, providers por conta, mapas do
   `UsageStore` por `storageKey`, pins, notificações, histórico e cache.
3. **UI:** card agrupado com seletor na principal e nos gráficos, aviso de
   contas alteradas, documentação.

Cada fase é um commit com `make validate` verde.

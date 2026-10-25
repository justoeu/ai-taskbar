# SDD — `VendorJSONStore`: um único store de valor JSON por fornecedor

**Status:** implementado (2026-10-25)
**Data:** 2026-10-25
**Branch:** `refactor/vendor-json-store`, empilhada sobre
`fix/peak-day-muse-weekly-kimi-opencode2` (PR #52), onde nasceu o
`LastSeenWindowStore`
**Plataforma:** macOS 13+, Swift 6 (concorrência estrita)

## 1. Resumo

Dois stores do Core guardam **um valor `Codable` por fornecedor** num JSON em
Application Support e repetem, linha a linha, a mesma infraestrutura:

| | `CreditBaselineStore` | `LastSeenWindowStore` |
|---|---|---|
| Arquivo | `credits/<vendor>.json` | `quota/<vendor>.json` |
| Valor | `CreditBaseline` (pico de créditos) | `LastSeenWindow` (última semanal) |
| Cache em memória | `OSAllocatedUnfairLock<Value?>` | `OSAllocatedUnfairLock<LoadState>` |
| Lê-altera-grava | `NSLock writeGate` | `NSLock writeGate` |
| Gravação | `AtomicFileWrite`, erro **engolido** (`try?`) | `AtomicFileWrite`, erro **logado** |
| Arquivo ausente | relê o disco **a cada** `load()` | ausência memorizada |
| Limpar | `reset()` | `clear()` |

A tabela mostra o problema: as duas cópias **já divergiram**. As melhorias que
a revisão do PR #52 pediu para o `LastSeenWindowStore` (lembrar a ausência,
logar a falha) não chegaram ao `CreditBaselineStore`. Cada correção futura
teria de ser feita duas vezes, e a segunda tende a ser esquecida.

Este SDD extrai a infraestrutura para um genérico,
`VendorJSONStore<Value>`. Os dois stores passam a ser camadas finas de regra
de domínio sobre ele, com **a mesma API pública, os mesmos arquivos e o mesmo
formato em disco**.

## 2. Fora do escopo (e por quê)

Têm semântica própria e **não** entram:

- `PinStore`: vários hosts por instância, texto puro, `0600` (pseudo-segredo).
- `MetaTokenStore`: segredo selado com `SecretBox` `enc:v2`, verificação de
  tipo de arquivo e tamanho, nunca logado.
- `UsageHistoryStore`: JSONL só de append, com compactação.
- `DiskCache`: TTL, stale, `.last_error`.

Forçá-los no mesmo genérico produziria uma abstração com flags para cada caso,
pior do que a duplicação que se quer remover.

Também fora: mover a escrita do `CreditBaselineStore` para fora do pool
cooperativo. Hoje ela roda no `decodeSnapshot` síncrono do `OpenAIProvider`.
Muda o fluxo do provider e não é refatoração.

## 3. Contrato do genérico

```swift
public final class VendorJSONStore<Value: Codable & Sendable & Equatable>: Sendable {
    public let vendor: VendorId
    public let baseDir: URL
    public var fileURL: URL              // baseDir/<vendor>.json

    public init(vendor: VendorId, baseDir: URL)
    public static func directory(_ name: String) throws -> URL  // App Support/<name>, ensureDir

    public func load() -> Value?
    @discardableResult
    public func update<R>(_ body: (_ current: Value?) -> (write: Value?, result: R)) -> R
    public func clear()
}
```

Regras, cada uma coberta por teste:

1. **Cache com ausência memorizada.** O primeiro `load()` lê o disco. O
   resultado é guardado, inclusive "nada gravado" e "arquivo ilegível", e as
   leituras seguintes não tocam o disco. O app é o único escritor desses
   arquivos, então não há quem os mude por fora durante a execução.
2. **Ilegível = ausente.** Arquivo corrompido, ou valor que o próprio decoder
   do `Value` rejeita (o `CreditBaseline` recusa pico NaN ou negativo), lê-se
   como nada gravado. Custa uma barra re-semeada, nunca um número errado.
3. **`update` é o único caminho de escrita.** Ele carrega o valor atual, chama
   `body` e grava `write` se este for diferente do atual, tudo sob a mesma
   trava. Duas atualizações sobrepostas nunca se intercalam: é a garantia
   RACE-CRO-007 que o `CreditBaselineStore` já tinha. `write == nil` significa
   não gravar nada (não é apagar).
4. **Memória antes do disco.** O valor novo vai para o cache antes da gravação.
   Um diretório que não aceita escrita degrada para um valor só em memória,
   nunca para um crash (teste existente `unwritable_dir_is_survivable`).
5. **Falha de gravação é logada, nunca engolida.** Ela não falha o fetch do
   fornecedor (o store é best-effort), mas fica visível no log.
6. **`clear()` espera um `update` em curso.** Usa a mesma trava, então um
   Recalibrate nunca é revertido por uma gravação atrasada. Apaga a memória e
   o disco; arquivo ausente não é erro.
7. **Sem `0600` próprio.** Os valores não são segredo, e o diretório pai já é
   `0700`. O genérico **não** deve receber segredos: valor sensível vai para o
   `MetaTokenStore` ou o `SecretBox`.

## 4. Como cada store fica

- **`CreditBaselineStore`** mantém `record`, `recordAndPeak`, `load`, `reset`,
  `defaultFor`, `fileURL` e o `init` interno com `afterLoadHook`. O
  `record` vira uma chamada a `update`, e o `afterLoadHook` passa a rodar no
  início do `body`, ainda entre a leitura e a gravação. A validação de pico
  finito e não negativo continua no `record`, antes de pedir a gravação.
- **`LastSeenWindowStore`** mantém `record(_:scope:at:)`, `carried`, `clear`,
  `load`, `defaultFor` e `fileURL`. O intervalo de regravação de 15 min e o
  escopo (plano) ficam no `body` do `update`.

Os dois deixam de ter lock, cache e I/O próprios.

## 5. Mudanças de comportamento (deliberadas)

| | Antes | Depois |
|---|---|---|
| `CreditBaselineStore`, arquivo ausente | relia o disco em toda leitura | ausência memorizada |
| `CreditBaselineStore`, gravação falhou | silencioso (`try?`) | logado |
| `CreditBaselineStore.reset()`, falha ao apagar | silencioso (`try?`) | logado; ausente não é erro |

Nenhuma muda número exibido, caminho, nome de arquivo ou formato JSON.

## 6. Testes

- Novo `VendorJSONStoreTests`, um teste por regra do §3: ida e volta em disco
  entre instâncias, ausência memorizada, ilegível = ausente (incluindo valor
  rejeitado pelo decoder), `update` sem mudança não grava, `write == nil` não
  grava, memória sobrevive a diretório sem escrita, `clear` espera um
  `update` estacionado, `clear` sem arquivo, `directory` cria a pasta.
- `CreditBaselineTests`, `OpenAICreditsProviderTests`, `LastSeenWindowTests`
  e `MetaProviderTests` ficam **inalterados** e têm de passar: são o contrato
  da API pública.
- `make validate` verde, cobertura de Core + Providers ≥ 90%.

## 7. Riscos

| Risco | Mitigação |
|---|---|
| Escritor externo depois de uma ausência memorizada não é visto | o app é o único escritor; documentado na regra 1 |
| Tipo genérico + `Sendable` em Swift 6 | `Value: Sendable`; o estado do lock é um enum `Sendable`; sem `@unchecked` |
| Alguém usar o genérico para segredo | regra 7, comentário de tipo e a regra de CLAUDE.md |

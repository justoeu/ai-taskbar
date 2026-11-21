# SDD — "Reiniciar quota" da Z.AI (resets de 5 horas e semanais)

Status: implementado em 2026-11-21. Par do `SDD-claude-limit-reset.md` e do
`SDD-native-authorization-and-openai-reset.md`, com a mesma regra.

## 1. O que existe do lado da Z.AI (medido, não documentado)

O console (`z.ai/manage-apikey/coding-plan/personal/usage`) mostra o card
**Reset Quota** ("Reiniciar quota") com resets de 5 horas e semanais. Não há
documentação pública; o protocolo foi lido do bundle do console
(`static.bigmodel.cn/z-ai-website/_next/static/chunks/045ln1m8nmhom.js`) e a
listagem foi conferida com a **chave de API** do app em 2026-11-21:

- **Lista:** `GET https://api.z.ai/api/biz/customer-package-reset/list?targetType=PERSONAL`,
  header `Authorization: <chave>` (sem "Bearer", como o uso; com "Bearer"
  também responde 200). Resposta:

  ```json
  {"code":200,"msg":"Operation successful","success":true,
   "data":{"customerId":…,"targetType":"PERSONAL","organizationId":null,"projectId":null,
           "lastFiveHourResetTime":null,"lastWeekResetTime":null,
           "fiveHourResets":[],
           "weekResets":[{"recordId":9,"grantType":"GLOBAL","expireTime":"2026-12-22 23:59:59","available":true}, …]}}
  ```

- **Uso:** `POST https://api.z.ai/api/biz/customer-package-reset/use` com
  `{targetType:"PERSONAL", resetType:"FIVE_HOUR"|"WEEK", recordId, requestId, grantType}`.
  O console gera `requestId` com `crypto.randomUUID()` e o **mantém** entre
  tentativas até o servidor responder; só o descarta numa resposta (sucesso ou
  recusa). Sucesso = `code == 200 && success == true`; qualquer outra resposta
  mostra `msg` e relê a lista.
- **Semântica** (texto do próprio console): cada reset tem a sua validade; o
  reset **semanal também zera a quota de 5 horas** sem gastar um reset de 5
  horas; o console só lista resets não usados e os vencidos há até 7 dias
  (`available: false`). O console habilita "Usar" sempre que a quota daquele
  tipo está acima de 0%.
- **Não verificado:** o `POST /use` com a chave de API não foi exercitado, pois
  gastaria um reset real. A lista aceita a chave, e o `/biz/` inteiro usa o
  mesmo filtro de autenticação, mas a primeira confirmação no app é o teste de
  aceitação. Um 401/403 ali aparece como "a Z.AI recusou a chave" e não gasta nada.

## 2. Regra (a mesma do Claude e da OpenAI)

`ZAISnapshot.limitResetOffers(now:)` oferece um tipo quando há um registro
dele não usado E uma janela que ele recompõe está **estritamente acima de
90%**, é finita e não passou do próprio horário de reset. O reset de 5 horas
recompõe a sessão; o semanal recompõe a semanal **e** a sessão, então com a
sessão em 100% e a semanal em 21% o botão semanal aparece (como no console). A
confirmação diz explicitamente que zera as duas. O registro gasto é o que
vence primeiro (o "Preferido" do console; sem data vai por último). O
controller acrescenta o frescor de sempre (`.ok`, não obsoleto, sem
`lastError`, buscado há −5…300 s).

## 3. Quando a lista é lida

O `ZAIProvider` pede a lista só enquanto a sessão ou a semanal está acima de
90%, na mesma busca, depois do uso. Qualquer falha (transporte, HTTP, `code`
≠ 200, JSON inesperado) mantém os números de uso e **pausa** as leituras por
1 h (`ZAIProvider.resetListPause`). A lista é reduzida à allow-list
(`recordId`, `grantType`, `expireTime`, `available` por entrada) e mesclada
ao payload em cache sob a chave `_aiTaskbarResetList`
(`ZAIResetList.merging(into:)`; com namespace para um campo futuro da Z.AI
nunca ser lido como a lista):
`customerId`, `organizationId` e `projectId` nunca chegam à memória nem ao
disco. Um `resetList` com formato inesperado é ignorado sozinho.

Validação na decodificação: `recordId` inteiro JSON > 0 (decodificado como
`Int64`, sem passar por `Double`); `grantType` `^[A-Za-z0-9_-]{1,32}$` ou
ausente (um valor inválido ou de outro tipo descarta o registro, porque ele
volta no corpo do POST); `expireTime` `yyyy-MM-dd[ HH:mm:ss]` com dígitos ASCII
e data que existe (`2026-02-30` não), senão ausente. A validade é
mostrada como data (sem fuso: o servidor não informa um) e a disponibilidade
vem do `available` do servidor.

## 4. Fluxo de resgate e segurança

`ZAILimitResetService` (Providers):

1. **prepare(kind)** no clique: chave → uso + lista novos → regra → tentativa
   (registro, `grantType`, validade, contagem).
2. **Confirmação** dentro da janela, destrutiva (Return nunca confirma): conta,
   tipo, validade, quantos restam e o que será zerado.
3. **consume**: numa primeira tentativa, uso + lista de novo (o registro sumiu
   ou a regra deixou de valer → `noEligibleReset`); depois o POST.
4. **Respostas**: transporte (cancelamento incluso), HTTP 5xx, 2xx ilegível,
   corpo sem `code` ou `code` 5xx → `submissionUncertain`: o controller guarda
   a tentativa e o próximo clique a retoma com o **mesmo `requestId`**, sem
   reler nada. HTTP/`code` 401/403 → `authorization`; 429 → `rateLimited`;
   outro HTTP 4xx → `failed`. Qualquer outra resposta com corpo é um
   **recibo**, não um erro, para o card ser atualizado (como o console relê a
   lista): `refused` numa primeira tentativa (nada foi gasto) e `unconfirmed`
   numa repetição (a tentativa perdida pode ter sido aplicada, e não se sabe se
   a Z.AI responde sucesso a um `requestId` repetido — o app não afirma que
   nada foi gasto). Numa repetição, qualquer erro lançado mantém a tentativa
   (o mesmo `requestId` é sempre seguro; um novo poderia gastar um segundo
   reset); numa primeira tentativa, só o incerto a mantém.

Todas as chamadas com a chave, inclusive o GET de uso agendado, usam
`HTTPClient.sendBounded` (só redirects HTTPS para a mesma origem); a lista e o
POST com teto de 256 KiB. A mensagem do servidor só vai para o log, passada por `PIIScrub`; a
UI mostra texto localizado. O texto de ajuda (ⓘ ao lado do botão) reproduz a
explicação do console.

## 5. Código compartilhado

`LimitResetController<Attempt, Receipt>` e `LimitResetControls` (App) servem
Claude e Z.AI; cada fornecedor só fornece a `Interpretation` (mensagens, qual
erro é incerto) e a `Presentation` (botões, textos, confirmação).
`ClaudeResetController` / `ZAIResetController` são typealiases.

## 6. Testes

- `ZAILimitResetTests` (Providers): golden da lista medida
  (`Fixtures.zaiResetList200`), falhas da lista, mescla sem ids da conta,
  formato inesperado, validação de cada campo, a regra (semanal por sessão,
  5 horas, exatamente 90%, aguardando reset, ordem por validade), Codable
  compatível, leitura condicional do provider com pausa de 1 h, e cada caminho
  do serviço (corpo do POST, chave crua, repetição sem releitura, registro
  sumido, tentativa adulterada, respostas incertas vs. definitivas).
- `ZAIResetControllerTests` (App) e o golden `zai_golden` (sem lista → sem grants).
- `ai-taskbar-validate`: "Wire types: Z.AI quota resets (customer-package-reset)".

Durante esta mudança apareceu um bug antigo: nos testes, `L10n` lia o bundle de
strings de `.build/arm64-apple-macosx/debug`, que o Swift 6.4 com Xcode
completo não atualiza mais (ele escreve em `.build/out/Products/Debug`). As
strings novas não eram encontradas, e testes do tipo
`message == localizedString(key)` passavam com a própria chave. Agora o
fallback de desenvolvimento escolhe o bundle mais recente.

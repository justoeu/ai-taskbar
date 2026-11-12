# SDD — Resets de limite do Claude (Fable, semanal, 5 horas, completo)

Status: implementado em 2026-11-12. Par do
`SDD-native-authorization-and-openai-reset.md` (resets conquistados da OpenAI).

## 1. O que existe do lado da Anthropic (medido, não documentado)

O Claude Code 2.1.322 traz `/limit-reset [fable|full|5-hour|weekly]`
(nome interno do programa: `cedar_ember`). Lido do bundle do CLI e conferido
contra a API real com uma conta Max em 2026-11-12:

- **Status:** `GET https://api.anthropic.com/api/oauth/usage?cedar_ember=1`
  (Bearer OAuth, `anthropic-beta: oauth-2025-04-20`). Sem o parâmetro, o bloco
  vem `null`. Formato:

  ```json
  "cedar_ember": {
    "eligible": true, "ineligible_reason": null, "at_limit": false, "exhausted": [],
    "grants": [{ "id": "full-reset-2611", "label": "One full limit reset (November 2026)",
                 "resets_total": 1, "resets_left": 1, "starts_at": "…", "ends_at": "…",
                 "clears": ["seven_day", "seven_day_overage_included"], "paused": false,
                 "usable_now": true, "use_requires_limit": false, "percent_used": {…},
                 "blocking": [], "type": "weekly", "gives_back_weekly": false,
                 "unavailable_reason": null }, …],
    "next_grant_id": "full-reset-2611", "weekly_resets_at": "…", "cooldown_until": null,
    "event_props": { "surface": …, "tier": …, "tenure_bucket": …, "billing_path": … }
  }
  ```

- **Resgate:** `POST https://api.anthropic.com/api/organizations/{orgUUID}/reset_rate_limits`
  com corpo `{"program":"cedar_ember","grant_id":…,"request_id":…}`; grant id
  `^[a-z0-9_-]{1,40}$`, request id `^[A-Za-z0-9_-]{1,64}$`. Resposta
  `{result: reset|already_used|not_limited|cooldown|ineligible|unavailable,
  reason, resets_left, cleared, weekly_resets_at, cooldown_until}`; 429 é
  limitação de taxa, 401/403 é autenticação.
- **Tipos** (regra do próprio Claude Code): `gives_back_weekly` → Fable; senão
  o `type`; senão só `five_hour` → 5 horas, só outros → semanal, ambos →
  completo. `seven_day_overage_included` é o limite semanal por modelo (Fable).
- **Restrição de superfície.** O status só vem `eligible` para o Claude Code
  CLI numa versão recente: `claude-cli/2.1.322 (external, cli)` → elegível;
  `claude-cli/1.0 (external, cli)` → `cli_version`; `claude-cli/1.0`,
  `ai-taskbar/… (external, cli)` → `surface`.

## 2. Decisão: apresentar-se como o CLI instalado só nas chamadas de reset

Escolhida pelo mantenedor em 2026-11-12, em vez de (b) um botão que abre o
Claude Code ou (c) não entregar. As chamadas de reset enviam
`claude-cli/<versão instalada> (external, cli)`; todas as outras chamadas à
Anthropic continuam com `claude-cli/1.0`. A versão é lida do local de
instalação (`ClaudeCLIVersion.installed`: symlink do launcher, pasta de
versões, cask do Homebrew, manifesto do npm — nunca executando o binário) e
validada como `dígitos.dígitos.dígitos`, porque vai num header. Sem CLI
instalado → nenhuma leitura de status e nenhum botão. Isso passa
deliberadamente pela restrição de superfície; o reset é do próprio usuário e
só é gasto num clique explícito e confirmado.

## 3. Regra (a mesma da OpenAI)

`AnthropicSnapshot.limitResetOffers(now:)` oferece um tipo quando há um grant
dele utilizável (`resets_left > 0`, não pausado, sem `unavailable_reason`,
dentro de `starts_at…ends_at`) E uma janela que ele recompõe está
**estritamente acima de 90%**, é finita e não passou do próprio horário de
reset. `ClaudeResetController.offers` acrescenta a exigência de frescor da
OpenAI: `.ok`, não obsoleto, sem `lastError`, buscado há −5…300 s. Um botão
por tipo, na ordem do Claude Code (5 horas, semanal, Fable, completo); a
contagem é a soma dos grants daquele tipo. O resgate mira o `next_grant_id`
do servidor quando ele é desse tipo; senão, o grant que expira primeiro.

Janelas que um grant recompõe: `five_hour` → sessão, `seven_day` → semanal,
`seven_day_opus` → Opus, `seven_day_overage_included` → linhas por modelo;
`gives_back_weekly` acrescenta a semanal; um grant completo sem `clears`
recompõe todas.

## 4. Quando o status é lido

O `AnthropicProvider` pede `?cedar_ember=1` (como o CLI) só enquanto alguma
janela está acima de 90% — o único momento em que um botão pode aparecer. A
busca que cruza 90% pela primeira vez faz uma segunda chamada; enquanto
continua acima, a única chamada já traz o status. Uma falha aí pode custar o
botão, nunca os números de uso:

- qualquer falha da chamada de status que não seja 401 (relida uma vez por
  quem chamou) ou cancelamento cai para a chamada simples na mesma busca e
  pausa as leituras de status por uma hora
  (`AnthropicProvider.resetStatusPause`), de modo que um servidor que recuse a
  variante nem derruba o card nem dobra as chamadas;
- um payload de status só é aceito se decodificar, e um `cedar_ember` com
  formato inesperado é ignorado sozinho (sem grants, janelas intactas);
- o cache guarda o payload de status com o `cedar_ember` reduzido à lista
  permitida que é decodificada (`AnthropicResetStatus.sanitizedPayload`), então
  `event_props` (tier, tempo de conta, forma de cobrança) nunca chega ao disco.

## 5. Fluxo de resgate e segurança

`ClaudeLimitResetService` (Providers):

1. **prepare(kind)** no clique: credencial só leitura (nunca renovada nem
   regravada) → `GET /api/oauth/profile` (decodifica SÓ `account.uuid` e
   `organization.uuid`; e-mail e nomes nunca são decodificados) → status →
   regra.
2. **Confirmação**: `ConfirmationRequest` dentro da janela, destrutiva, então
   Return nunca confirma; mostra a conta, o tipo, o rótulo do grant vindo do
   servidor e a contagem.
3. **consume**: perfil de novo (conta ou organização mudou →
   `accountChanged`); numa primeira tentativa, o status de novo (grant sumiu
   ou a regra deixou de valer → `noEligibleReset`); depois o POST.
4. **Erros**: falha de transporte, 5xx ou 2xx ilegível →
   `submissionUncertain` (a requisição pode ter chegado): o controller guarda
   a tentativa e o próximo clique a retoma com o MESMO `request_id`.
   429/401/403/outros 4xx são definitivos e a descartam, inclusive numa
   repetição. Um `result` desconhecido é lido como `unavailable`, nunca como
   reset.
5. A tentativa pendente vive no view model da conta (sobrevive a fechar o
   popover), só em memória. Ao contrário da OpenAI, não há diário em disco: um
   relançamento começa do zero, e uma nova tentativa relê os grants antes de
   resgatar.

O UUID da organização e o grant id são validados antes de chegar à URL/corpo.
As três chamadas de reset usam `HTTPClient.sendBounded` (só redirects HTTPS
para a mesma origem): um 307 para outro host reenviaria o POST e a resposta
seria lida como resultado do resgate. Uma verificação que termina com o
popover fechado deixa uma confirmação que a view nunca apresentou; o próximo
clique a limpa e apresenta de novo. Ela NÃO é reapresentada no `onAppear`, de
propósito: o card é reconstruído quando o estado alterna entre `.ok` e
`.failed`, e um segundo `present` cancela o pedido aberto (cujo `onCancel`
limpa a tentativa), deixando "Confirmar" sem efeito.

## 6. Testes

- `ClaudeLimitResetTests` (Providers): decodificação golden de um fixture com
  formato real (`Fixtures.anthropicUsageWithResets200`), classificação, a
  regra (exatamente 90%, só Fable, expirado / não iniciado, aguardando reset,
  sessão, completo, NaN), compatibilidade do Codable, cada caminho do serviço
  (headers, URL, corpo, repetição sem nova checagem, troca de conta, erros
  incertos vs. definitivos, entrada adulterada), a leitura condicional de
  status do provider, o fallback com pausa de 1 h e o cache sanitizado.
- `ClaudeCLIVersionTests` (Core), `ClaudeResetControllerTests` (App).
- `ai-taskbar-validate`: "Wire types: Claude limit resets (cedar_ember)".

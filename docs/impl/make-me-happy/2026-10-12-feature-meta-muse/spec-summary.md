# Meta (Muse Code) — spec summary

Kind: feature · Loop: full · Spec: `docs/SDD-meta-muse.md` (draft, Etapa Zero)

Goal: cartão "Muse (Meta)" com quota de assinatura (janelas sessão/semanal
via `POST api.meta.ai/muse-code/key` com token `dca:` do `muse login`,
read-only e prompt-free) + histórico local de tokens por modelo (scanner de
`~/.local/share/muse/sessions/**/session.jsonl`, kinds `model_completed` e
`automated_review_completed`, bucket por `recorded_at` na `CostWindow`).

Actors: utilizador do ai-taskbar com Muse Code instalado/logado.

In scope: `VendorId.meta`, `MetaSnapshot`, `[meta]` config (enabled=false,
sem api_key/base_url), `MetaCredentialReader` (auth.json inline > Keychain
`ai.meta.dev.credentials`/`meta`), `MetaProvider`+`MetaWireTypes` (decode por
allow-list; chave cunhada/PII descartados), `MuseSessionScanner` (input inclui
cache read; reasoning dentro de output), Analytics sem USD (unpriced), UI +
Settings + i18n ×3, goldens + validate section.

Out of scope: executar o CLI, inferência, prompts de Keychain, cookies/quota
de time dev.meta.ai (fase 2), pricing/USD, feed de status.

Contracts: mint request/response subset (§8 do SDD); linhas session.jsonl (§9).

Done when: `make validate` verde, cobertura Core+Providers ≥ 90%, cartão
mostra janelas/tokens reais ou estado honesto (PAYG/idle/sem login), score
MMH 10 com review 3 eixos APPROVE.

# Spec Summary — Checagem Automática Diária de Versões e Banner de Atualização

**Kind:** feature  
**Goal:** Permitir que o AI Taskbar verifique periodicamente (1 vez ao dia / 24h) novas versões publicadas no GitHub Releases em background e exiba um banner elegante no topo do popover com botão de atualização rápida e download seguro via `.dmg` com validação de hash SHA-256.

## Atores
- Usuário do AI Taskbar (interage com o banner de atualização).
- `RefreshScheduler` / `UpdateChecker` (agenda a cada 24h e gerencia estados).
- GitHub Releases API (`api.github.com/repos/justoeu/ai-taskbar/releases/latest`).

## Contratos
- `UserDefaults` keys: `ai_taskbar_last_update_check_at` e `ai_taskbar_dismissed_update_tag`.
- `UpdateChecker.checkIfNeeded(force:)`, `UpdateChecker.dismissCurrentUpdate()`, `isUpdateBannerVisible`.
- Banner visual em `PopoverContentView.swift` com estados: Disponível, Baixando, Concluído e Dispensar.

## Fora de Escopo
- Auto-substituição do binário sem aprovação ou confirmação do usuário (sem helper de root / Sparkle).
- Reinício forçado do app.

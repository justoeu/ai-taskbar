# Revisões — autorização Claude e reset OpenAI

2026-09-06. Escopo: worktrees 3 e 4, integrados na branch de trabalho original. Nenhuma publicação externa ou resgate real autorizado pelos testes.

## Vereditos independentes

| Revisão | Claude | OpenAI |
|---|---|---|
| Correção / regressões | PASS | PASS |
| Segurança / autenticação / persistência | APPROVED | APPROVED |
| Swift 6 / concorrência / performance / dependências | PASS | PASS |

Os revisores trabalharam em modo read-only; builds e testes foram executados pelo integrador. Não houve alterações em `Package.swift` ou `Package.resolved`: nenhuma dependência nova; isto não representa uma reauditoria completa dos CVEs preexistentes.

## Achados tratados

- Leitura comum entre contas volta a selecionar a credencial mais recente, vinculando sua referência persistente. Conta configurada duplicada falha fechada; candidato bloqueado por ACL não fica escondido por sibling legado legível.
- Exclusão, referência inválida e troca de item descartam cache e tokens pendentes. Queries restringem serviço, conta e item. Escritas não recriam credenciais nem usam fallback por serviço.
- Testes de Keychain usam arquivo temporário privado e não podem passar silenciosamente se a criação da fixture falhar. A fixture legacy-only comprovou leitura, escrita e probe nativo sem depender do login Keychain.
- Reset verifica identidade retornada pelo servidor, exige disponibilidade positiva e uso estritamente acima de 90%, e recusa snapshots stale, com erro ou vencidos.
- Falhas anteriores ao envio não viram repetição ambígua. Resultados confirmados permanecem confirmados mesmo se a leitura posterior falhar.
- Journal atômico 0600 e lock cross-process preservam UUID/conta entre reinícios e impedem substituição concorrente. Rejeição explícita do método de consumo limpa somente uma tentativa nova; nunca apaga uma submissão antiga sem resultado conclusivo.
- Transporte executa diretamente o Mach-O oficial assinado, usa relógio monotônico e limita frames, bytes e tempo. Não envia refresh token/id token; não herda configuração de autenticação/logging/proxy do usuário.
- Golden atualizado, metadata experimental malformada tolerada, traduções verificadas e testes do controller, journal e subprocesso adicionados.

## Evidências e refutações

- RED→GREEN reproduziu regressões de seleção entre contas, estado após exclusão, fronteira de envio e suporte a método. A renomeação do item já falhava fechada antes do reforço de query; não é apresentada como regressão reproduzida.
- O schema gerado pela CLI oficial instalada 0.153.4 confirmou `accountId` no resultado de `account/rateLimits/read`, apesar de exemplos/schemas checked-in consultados o omitirem. A verificação de identidade foi mantida; versões/respostas sem essa informação ficam indisponíveis para resgate.
- A suíte integrada executou 626 testes com 91,87% de cobertura em Core + Providers, além de 314 assertions do validador. A inicialização do app-server instalado é exercitada sem login, consulta de quota ou consumo real.

## Aceitação manual ainda necessária

1. Build Developer ID: desbloquear o Keychain de assinatura local. A validação ad-hoc não prova persistência de consentimento entre versões assinadas.
2. Item Claude estrangeiro com ACL bloqueada: clicar Autorizar, validar o resultado e reabrir/atualizar sem novo prompt. Fixtures próprias não provam a alteração real da ACL do Claude.
3. Conta OpenAI elegível: verificar visualmente botão/confirmação; executar um resgate somente após confirmação explícita do usuário. Não houve resgate real nesta implementação.

Detalhes de arquitetura e contrato: [SDD](SDD-native-authorization-and-openai-reset.md).

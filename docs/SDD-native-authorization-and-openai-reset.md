# SDD — autorização nativa do Claude e reset de limite do OpenAI

Data: 2026-09-05. Escopo autorizado: onboarding sem Terminal e resgate explícito de um reset disponível no card OpenAI/Codex. Não inclui compra de créditos, aumento artificial de quota, renovação OAuth compartilhada ou publicação de release.

## 1. Contrato de produto

- Claude: atualizações automáticas jamais abrem diálogos. O botão **Autorizar** permite uma leitura interativa do item exato; a senha é recebida exclusivamente pelo macOS. Sucesso só é informado após nova leitura silenciosa do mesmo item. A assinatura Developer ID estável é obrigatória nesse fluxo.
- OpenAI: mostrar **Usar reset** somente com snapshot atual, não stale, com até 300 segundos de idade, uma janela ativa estritamente acima de 90% e contagem de resets conhecida e positiva. 90% exatos, disponibilidade ausente, loading, falha ou janela já vencida não habilitam a ação.
- Clicar consulta novamente o servidor; não consome nada. A confirmação informa conta e quantidade disponível, explicando que a operação consome um reset.
- Uma tentativa sem resposta conclusiva ganha ação separada de repetição, mesmo se o percentual depois cair: essa ação recupera a tentativa anterior, não oferece um novo crédito. Cancelar a confirmação não resgata nada.

## 2. Autorização Claude

`KeychainCredentialReader` serializa leitura, autorização, reconciliação e escrita com um lock recursivo. A identidade inclui referência persistente e conta; consultas também restringem serviço e conta. Tokens pendentes e cache pertencem exclusivamente a essa identidade. Exclusão, referência inválida ou troca de item limpam os estados associados; não existe fallback de escrita por serviço nem recriação de item.

Leituras normais preservam a escolha do token legível mais recente. Uma conta explicitamente configurada é estrita. Um candidato bloqueado por ACL não pode ser ocultado por um item legado legível. A seleção para autorização e uma escrita ainda não vinculada exigem identidade inequívoca.

Todas as operações automáticas ficam dentro de `withPromptsSuppressed` e usam `kSecUseAuthenticationUIFail`. Somente o clique em Autorizar abre `withPromptsAllowed` com `kSecUseAuthenticationUIAllow`, seguido de verificação silenciosa. Cancelamento, negação e permissão não persistente têm resultados distintos. O app não modifica listas de partições por shell e não coleta senha.

## 3. Reset OpenAI: componentes e sequência

| Componente | Responsabilidade |
|---|---|
| OpenAI wire / snapshot | Decodificar contagem opcional, sem confundir reset com saldo pago; preservar caches antigos |
| OpenAIResetControls / Controller | Elegibilidade visual, confirmação, exclusão de duplo clique, feedback e recuperação de tentativa |
| OpenAIResetProtocol | Login externo, confirmação de conta, pré-condições, resgate idempotente e interpretação de resultado |
| CodexResetProcess | Transporte JSON-RPC stdio limitado, processo nativo oficial assinado, ambiente isolado |
| OpenAIResetJournal | Registro atômico 0600 de conta e UUID; nunca armazena tokens |

Sequência normal: snapshot elegível → clique → `initialize` → `initialized` → `account/login/start` em modo `chatgptAuthTokens` → `account/rateLimits/read` → confirmação → nova autenticação/leitura → validar conta e elegibilidade → persistir UUID → `account/rateLimitResetCredit/consume` → consultar limites → atualizar card.

`accountId` retornado pelo servidor deve corresponder exatamente à conta confirmada, inclusive em repetição. Ausência de identidade falha fechada. Repetição usa o mesmo `idempotencyKey`; não gera outro UUID após resposta perdida. Falhas anteriores ao envio não são classificadas como resgate ambíguo. Resultados conhecidos: `reset`, `alreadyRedeemed`, `nothingToReset`, `noCredit`. Falha na atualização posterior não converte resgate já confirmado em falha de resgate.

## 4. Segurança e isolamento

- O monitor lê `auth.json`, mas não grava nem renova o refresh token compartilhado. Apenas access token e account ID seguem por stdin ao subprocesso; id token e refresh token não são enviados.
- Executar diretamente o Mach-O do Codex, com assinatura Apple/Developer ID da OpenAI, identificador `codex` e Team ID `2DC432GLL2`. Não executar o wrapper Node. Instalações não reconhecidas ficam indisponíveis, sem fallback inseguro.
- `CODEX_HOME`, diretório de trabalho e temporários próprios em diretório UUID 0700. Ambiente restrito; não herdar proxies, configurações de projeto ou opções de logging. Stderr descartado. Autenticação externa é efêmera no app-server.
- Limitar tamanho de stdout, quantidade de frames e tempo por request com relógio monotônico. Encerrar apenas o processo criado; cleanup não atinge sessões Codex do usuário.
- Journal contém somente metadados da operação e é escrito atomicamente com 0600 antes do resgate. Um lock de arquivo não bloqueante cobre verificação de UUID/conta, autenticação, envio e conclusão entre instâncias do app; o descritor não é herdado pelo subprocesso. Erros de persistência não são ignorados. Não apagar uma tentativa ambígua automaticamente.
- A rejeição JSON-RPC `-32601` do método de consumo limpa somente uma tentativa nova, sem journal anterior. A mesma rejeição durante uma repetição não prova o resultado da operação antiga e preserva a chave. Rejeições de inicialização/login/leitura jamais limpam o journal.

## 5. Compatibilidade e limites

Referência local: Codex CLI 0.153.4. O fluxo externo do app-server é experimental upstream; ausência de método ou mudança de schema deve falhar fechada, mantendo o monitoramento de uso independente. Não há garantia de disponibilidade de resets em todo plano/conta. O botão depende de confirmação positiva do backend; não deduz elegibilidade pela assinatura paga.

O campo `accountId` foi confirmado também no JSON Schema gerado localmente por `codex app-server generate-json-schema` na versão 0.153.4, sem credenciais. Exemplos e schemas checked-in consultados podem omitir esse campo: sua ausência na resposta real mantém o resgate indisponível, não reduz a verificação de conta.

Não há promessa de “nunca mais pedir senha”: revogação, recriação da credencial, mudança de assinatura ou políticas do Keychain podem exigir nova autorização. O objetivo é autorização nativa, explícita e verificável, sem comando manual na distribuição.

## 6. Plano de verificação

RED→GREEN nas regressões reproduzíveis; golden do novo campo e retrocompatibilidade; limites 90/90,1; stale/loading/idade/reset vencido; troca e ausência de conta; falta de crédito no pré-envio; cancelamento; repetição idempotente; confirmação com falha na atualização; timeout/EOF/frames; journal e permissões; Keychain temporário isolado, exclusão/recriação/renomeação, seleção entre contas e serialização de escritas.

Gate: `make validate` (Core + Providers ≥90%, runtime assertions, testes, montagem, smoke, permissões, mirrors e warnings). Com o Keychain de assinatura bloqueado, `make validate APP_SIGN_IDENTITY=-` verifica a build ad-hoc; isso não substitui o teste da versão Developer ID.

Três revisões independentes: correção, segurança e Swift/concurrency/performance. Integrar worktrees 3/4 somente após gate verde; remover os auxiliares depois da integração.

UAT pendente: versão Developer ID, item Claude estrangeiro bloqueado, confirmação nativa, refresh/reabertura sem novo prompt; visualização do card OpenAI em conta elegível; resgate real somente com confirmação do usuário. Testes automatizados usam fixtures e não consomem créditos reais.

## 7. Fontes primárias

- [App-server: earned rate-limit resets e autenticação externa](https://learn.chatgpt.com/docs/app-server#8-earned-rate-limit-resets-chatgpt).
- [Contrato oficial de conta, créditos e parâmetros](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/src/protocol/v2/account.rs).
- [Processador oficial de respostas de conta](https://github.com/openai/codex/blob/main/codex-rs/app-server/src/request_processors/account_processor.rs).
- [Gerenciador oficial da autenticação externa](https://github.com/openai/codex/blob/main/codex-rs/login/src/auth/manager.rs).

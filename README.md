# ollama-opencode-config

Roda o [OpenCode](https://opencode.ai) com modelos locais do [Ollama](https://ollama.com), no Windows, sem você descobrir na tentativa e erro qual modelo cabe na sua placa.

Um arquivo. Ele olha seu hardware, escolhe o modelo e a janela de contexto que cabem na memória que você tem, e escreve o `opencode.json` pronto.

```powershell
irm https://raw.githubusercontent.com/boliveiras/ollama-opencode-config/main/install.ps1 | iex
```

## Por que isso existe

Configurar Ollama + OpenCode na mão trava em dois pontos.

**Contexto pequeno demais.** O padrão do Ollama é 2k–4k tokens; o OpenCode precisa de 64k para chamar ferramentas de forma confiável. Com menos que isso ele para de editar arquivos sem erro nenhum — parece modelo ruim, é configuração.

**Modelo grande demais.** Você baixa 19 GB de um 30B, ele não cabe na VRAM, o Ollama joga metade na RAM e cada resposta demora minutos.

## Como rodar

Abra um terminal **de usuário comum**. O script recusa rodar elevado de propósito: o Ollama e o OpenCode não precisam disso, e um agente que executa comandos não deveria herdar privilégio de admin. Precisa de Windows 10/11 com PowerShell 5.1 (já vem) ou 7+, e `winget` ou `npm`.

```powershell
# so a recomendacao, sem instalar nada
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/boliveiras/ollama-opencode-config/main/install.ps1))) -ShowPlanOnly

# instalar
irm https://raw.githubusercontent.com/boliveiras/ollama-opencode-config/main/install.ps1 | iex
```

`irm | iex` roda com os padrões; a forma com `[scriptblock]::Create` é a que aceita parâmetros.

Ou baixe e leia antes — é o que eu faria:

```powershell
irm https://raw.githubusercontent.com/boliveiras/ollama-opencode-config/main/install.ps1 -OutFile install.ps1
notepad install.ps1
.\install.ps1 -WhatIf
```

Antes de mexer em qualquer coisa ele mostra o plano e pergunta. Depois instala o que falta, sobe o daemon em loopback, baixa o modelo, cria uma variante com o `num_ctx` calculado e escreve o `opencode.json` preservando o que já estava lá, com backup.

## Como ele decide

O orçamento de memória é `VRAM × 0,85` quando há GPU dedicada de 4 GB ou mais — o resto é do driver e do desktop. Sem GPU dedicada, `RAM × 0,50`. Aí vale a conta:

```
pesos_do_modelo + custo_do_contexto <= orçamento
```

Contexto custa memória, e não é pouco: num modelo de 14B, 128k de contexto consomem cerca de 7,7 GB só de cache KV — mais do que os pesos inteiros de um 7B. É por isso que não dá para escolher modelo e contexto separadamente.

O contexto é arredondado para baixo em blocos de 8k, com piso de 32k. Em modo CPU há teto de 64k, porque processar prompt longo sem GPU fica insuportável mesmo com RAM sobrando.

| Hardware | Orçamento | Escolha |
|---|---|---|
| RTX 4060 8 GB | 6,8 GB | `qwen2.5-coder:7b` @ 57k |
| RTX 4070 12 GB | 10,2 GB | `qwen2.5-coder:7b` @ 128k |
| RTX 4080 16 GB | 13,6 GB | `qwen2.5-coder:14b` @ 72k |
| RTX 3090 24 GB | 20,4 GB | `devstral:24b` @ 64k |
| Sem GPU, 32 GB RAM | 16 GB | `qwen2.5-coder:14b` @ 64k |

Os pesos assumem quantização Q4_K_M e o custo de cache KV é estimado por família. É ponto de partida seguro, não medição da sua máquina. Mediu número melhor? Manda PR no `$script:ModelCatalog`, dizendo em que hardware.

## Parâmetros

| Parâmetro | Padrão | O que faz |
|---|---|---|
| `-Model` | autodetectado | Fixa o modelo. Desliga a escolha automática. |
| `-ContextLength` | autodimensionado | Fixa o `num_ctx`. |
| `-ConfigScope` | `User` | `User` grava o config global; `Project`, na pasta atual. |
| `-PermissionProfile` | `Strict` | `Strict`: bash e edit pedem confirmação, webfetch bloqueado. `Standard` é mais solto. |
| `-OllamaEndpoint` | `127.0.0.1:11434` | Só aceita loopback. |
| `-SkipInstall` | — | Não instala nada, só configura. |
| `-SkipModelPull` | — | Não baixa modelo. |
| `-NoAutoDetect` | — | Pula a detecção e usa perfil conservador. |
| `-ShowPlanOnly` | — | Mostra a recomendação e sai. |
| `-Force` | — | Não pergunta antes de alterar a máquina. |
| `-WhatIf` | — | Simula tudo sem tocar em nada. |

Passou `-Model` sem `-ContextLength`? Ele redimensiona o contexto para o modelo que você escolheu, não reaproveita o número de outro.

## Segurança

`irm | iex` é execução de código remoto arbitrário, e não adianta fingir que não é. Você está confiando neste repositório, no GitHub e na sua conexão. Se isso te incomoda — e deveria, em máquina de trabalho — baixe o arquivo, leia e rode local. É um arquivo só, justamente para caber numa leitura.

Para adotar em equipe, **fixe uma tag**. URL apontando para `main` muda quando o repositório muda; tag não.

```powershell
irm https://raw.githubusercontent.com/boliveiras/ollama-opencode-config/refs/tags/v1.0.1/install.ps1 | iex
```

Cada tag é assinada pelo Sigstore (keyless, via OIDC do GitHub Actions) e o SHA-256 vai no resumo do job. Baixe o `install.ps1` e o `install.ps1.sigstore.json` da release e confira com o [CLI do sigstore](https://pypi.org/project/sigstore/):

```powershell
sigstore verify identity install.ps1 `
  --bundle install.ps1.sigstore.json `
  --cert-identity "https://github.com/boliveiras/ollama-opencode-config/.github/workflows/security.yml@refs/tags/v1.0.1" `
  --cert-oidc-issuer https://token.actions.githubusercontent.com
```

Passou, o arquivo saiu daquele workflow, naquela tag, sem ninguém no meio. A assinatura não diz que o código é bom — diz que é o mesmo código que a CI analisou e testou.

O que ele faz por padrão:

- **Pergunta antes de alterar qualquer coisa** e faz backup do `opencode.json` antes de escrever, preservando as chaves que já existiam. `-Force` pula a pergunta.
- **Recusa rodar como administrador.** Um agente que executa comando arbitrário não deveria ter esse privilégio.
- **Só aceita loopback.** A API do Ollama não tem autenticação nenhuma: exposta na rede, qualquer um que alcance a máquina usa seu modelo e lê seus prompts — que incluem seu código-fonte. O script recusa `OLLAMA_HOST` fora de `127.0.0.1` e avisa se a porta 11434 aparecer escutando em outro endereço.
- **`bash` e `edit` pedem confirmação.** O OpenCode executa comando e edita arquivo conforme o modelo decidir; o perfil `Strict` te deixa no circuito.
- **ACL restritiva** no config e nos backups (só você e o SYSTEM, herança quebrada), **log JSONL** em `%LOCALAPPDATA%\opencode-setup\` sem segredo nem prompt, e **nome de modelo validado por regex** antes de virar linha de comando.

O que ele **não** faz: verificar a assinatura Authenticode dos instaladores baixados pelo winget. Ambiente regulado, hospede um fork interno. Achou algo? [SECURITY.md](SECURITY.md).

## Quando algo dá errado

**O OpenCode não chama ferramentas / não edita arquivos.** Quase sempre é contexto pequeno. Rode `-ShowPlanOnly` e confira se o `num_ctx` está em 32k ou mais.

**Respostas absurdamente lentas.** O modelo não coube na VRAM e está rodando na RAM. O plano mostra o orçamento real — escolha um modelo abaixo dele.

**`Ollama instalado, mas ausente do PATH`.** Feche e reabra o terminal, depois rode com `-SkipInstall`.

**A execução some sem mensagem no PowerShell 5.1.** Política de execução. Rode `powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1` — escopo de processo, não altera a máquina.

**Acentos saindo como `Ã§Ã£o`.** Não deveria acontecer: o arquivo é ASCII puro. Você tem uma cópia antiga.

## Desenvolvimento

```powershell
Invoke-Pester ./tests
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

Os testes carregam o `install.ps1` com ponto; o script detecta isso pelo `$MyInvocation.InvocationName` e expõe as funções sem executar o provisionamento — é o que permite testar tudo mantendo arquivo único.

Quatro regras que os testes garantem, e que não são negociáveis:

- **ASCII puro, sem BOM.** O PS 5.1 lê `.ps1` sem BOM na codepage ANSI e o console usa outra; qualquer byte acima de `0x7F` vira lixo na tela.
- **Nada de sintaxe do PowerShell 7.** Sem ternário, `??`, `&&`, `ConvertFrom-Json -AsHashtable`. A maioria das máquinas Windows ainda só tem o 5.1.
- **Sem `exit`, `$PSScriptRoot`, `$PSCmdlet` ou `#Requires`.** Nada disso existe quando o código chega por `iex` — e `exit` fecharia a sessão do usuário.
- **A confirmação antes de alterar a máquina tem que existir.** Um teste falha se ela sumir.

O `ci.yml` responde "funciona?": Pester no PowerShell 5.1 **e** no 7, execução real via `irm | iex` nos dois, e checagem de encoding e do blob. O `security.yml` responde "é seguro?": PSScriptAnalyzer com SARIF no code scanning, CodeQL e zizmor nos workflows, gitleaks no histórico inteiro, actions fixadas por SHA e assinatura Sigstore nas tags.

Não há SCA clássico porque não há dependência de runtime — o `install.ps1` não importa módulo nenhum, e um teste falha se alguém introduzir um `Import-Module`. DAST e scan de container também não se aplicam: não há aplicação web nem imagem.

O `git commit` roda Trivy e PSScriptAnalyzer localmente, antes da CI. Ative uma vez por clone com `pre-commit install`. O gate local usa o mesmo critério do da CI: `Error` e `Warning` bloqueiam, `Information` não. Se você não vir os dois como **Passed** ao commitar, o gate não rodou — o hook do `pre-commit` sai 0 em silêncio quando não acha a configuração.

`VERSION` na raiz é a fonte da verdade, em SemVer. O `install.ps1` repete o número em `$script:ScriptVersion` porque rodando via `iex` não existe arquivo em disco para ler; um teste falha se os dois divergirem. Não há endpoint `/version` aqui — não há processo servindo nada. O banner e o log JSONL fazem esse papel.

## Licença

MIT. Veja [LICENSE](LICENSE).

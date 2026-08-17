# ollama-opencode-config

Roda o [OpenCode](https://opencode.ai) com modelos locais do [Ollama](https://ollama.com), no Windows, sem você ter que descobrir na tentativa e erro qual modelo cabe na sua placa.

Um arquivo. Ele olha seu hardware, escolhe o modelo e a janela de contexto que cabem na memória que você tem, e escreve o `opencode.json` pronto.

```powershell
irm https://raw.githubusercontent.com/boliveiras/ollama-opencode-config/main/install.ps1 | iex
```

## Por que isso existe

Configurar Ollama + OpenCode na mão trava em dois pontos:

1. **Contexto pequeno demais.** O padrão do Ollama é 2k–4k tokens. O OpenCode precisa de pelo menos 64k para chamar ferramentas de forma confiável. Com menos que isso ele simplesmente para de editar arquivos, sem erro nenhum — parece que o modelo é ruim, mas é a configuração.
2. **Modelo grande demais.** Você baixa 19 GB de um 30B, ele não cabe na VRAM, o Ollama joga metade na RAM e cada resposta demora minutos.

O script resolve os dois: calcula quanto de memória você tem de fato e dimensiona modelo e contexto para caber.

## Como rodar

**Só ver a recomendação, sem instalar nada:**

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/boliveiras/ollama-opencode-config/main/install.ps1))) -ShowPlanOnly
```

**Instalar:**

```powershell
irm https://raw.githubusercontent.com/boliveiras/ollama-opencode-config/main/install.ps1 | iex
```

**Com opções:**

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/boliveiras/ollama-opencode-config/main/install.ps1))) -Model 'devstral:24b' -ConfigScope Project
```

A forma com `[scriptblock]::Create` é a que aceita parâmetros. `irm | iex` roda com os padrões.

**Ou baixe e leia antes** — é o que eu faria:

```powershell
irm https://raw.githubusercontent.com/boliveiras/ollama-opencode-config/main/install.ps1 -OutFile install.ps1
notepad install.ps1
.\install.ps1 -WhatIf
```

Abra um terminal **de usuário comum**, não como administrador. O script recusa rodar elevado de propósito — o Ollama e o OpenCode não precisam disso, e um agente que executa comandos não deveria herdar privilégio de admin.

Precisa de Windows 10/11 com PowerShell 5.1 (já vem no Windows) ou 7+, e `winget` ou `npm`.

## O que ele faz

1. Detecta CPU, RAM, VRAM e espaço em disco.
2. Escolhe o maior modelo que cabe, e o maior contexto que cabe junto com ele.
3. Mostra a conta e pergunta se pode continuar.
4. Instala Ollama e OpenCode se faltarem (`winget`, com fallback para `npm`).
5. Sobe o daemon do Ollama em `127.0.0.1` e espera ficar de pé.
6. Baixa o modelo e cria uma variante com o `num_ctx` calculado.
7. Escreve o `opencode.json` — preservando o que já estava lá, com backup antes.
8. Valida se funcionou de verdade e falha se não funcionou.

## Como ele decide

**Orçamento de memória:**

- Com GPU dedicada de 4 GB ou mais: `VRAM × 0,85` (o resto é do driver e do desktop).
- Sem GPU dedicada: `RAM × 0,50` (o resto é do sistema e das suas ferramentas).

**Cabe ou não cabe:**

```
pesos_do_modelo + custo_do_contexto <= orçamento
```

O contexto custa memória de forma linear. Num modelo de 14B, 128k de contexto consomem cerca de 7,7 GB só de cache KV — mais do que os pesos inteiros de um 7B. É por isso que não dá para escolher modelo e contexto separadamente.

O contexto é arredondado para baixo em blocos de 8k, com piso de 32k. Em modo CPU há um teto de 64k, porque processar prompt longo sem GPU fica insuportável mesmo com RAM sobrando.

**Resultado esperado:**

| Hardware | Orçamento | Escolha |
|---|---|---|
| RTX 4060 8 GB | 6,8 GB | `qwen2.5-coder:7b` @ 57k |
| RTX 4070 12 GB | 10,2 GB | `qwen2.5-coder:7b` @ 128k |
| RTX 4080 16 GB | 13,6 GB | `qwen2.5-coder:14b` @ 72k |
| RTX 3090 24 GB | 20,4 GB | `devstral:24b` @ 64k |
| Sem GPU, 32 GB RAM | 16 GB | `qwen2.5-coder:14b` @ 64k |

Os pesos assumem quantização Q4_K_M e os custos de cache KV são estimativas por família de modelo. É um ponto de partida seguro, não uma medição da sua máquina. Se você medir números melhores, manda PR no `$script:ModelCatalog`.

## Parâmetros

| Parâmetro | Padrão | O que faz |
|---|---|---|
| `-Model` | autodetectado | Fixa o modelo. Desliga a escolha automática. |
| `-ContextLength` | autodimensionado | Fixa o `num_ctx`. |
| `-ConfigScope` | `User` | `User` grava o config global; `Project` grava na pasta atual. |
| `-PermissionProfile` | `Strict` | `Strict`: bash e edit pedem confirmação, webfetch bloqueado. `Standard` é mais solto. |
| `-OllamaEndpoint` | `127.0.0.1:11434` | Só aceita loopback. Ver a seção de segurança. |
| `-SkipInstall` | — | Não instala nada, só configura. |
| `-SkipModelPull` | — | Não baixa modelo. |
| `-NoAutoDetect` | — | Pula a detecção e usa um perfil conservador. |
| `-ShowPlanOnly` | — | Mostra a recomendação e sai. |
| `-Force` | — | Não pergunta antes de alterar a máquina. |
| `-WhatIf` | — | Simula tudo sem tocar em nada. |

Se você passar `-Model` mas não `-ContextLength`, ele redimensiona o contexto para o modelo que você escolheu — não usa o número de outro modelo.

## Segurança

**Sobre o `irm | iex`.** Isso é execução de código remoto arbitrário, e não adianta fingir que não é. Você está confiando neste repositório, no GitHub e na sua conexão. Se isso te incomoda — e deveria, em máquina de trabalho —, baixe o arquivo, leia, e rode local. É um arquivo só, justamente para caber numa leitura.

Se for adotar em equipe, **fixe uma tag** em vez de `main`:

```powershell
irm https://raw.githubusercontent.com/boliveiras/ollama-opencode-config/refs/tags/v1.0.1/install.ps1 | iex
```

Uma URL apontando para `main` muda quando o repositório muda. Uma tag não.

### Verificar antes de executar

Cada tag é assinada pelo Sigstore (keyless, via OIDC do GitHub Actions) e o SHA-256 vai no resumo do job. Para conferir que o arquivo que você baixou é o que a CI publicou:

```powershell
$tag = 'v1.0.1'
$base = "https://github.com/boliveiras/ollama-opencode-config/releases/download/$tag"
irm "$base/install.ps1" -OutFile install.ps1
irm "$base/install.ps1.sigstore.json" -OutFile install.ps1.sigstore.json

# precisa do CLI: pip install sigstore
sigstore verify identity install.ps1 `
  --bundle install.ps1.sigstore.json `
  --cert-identity "https://github.com/boliveiras/ollama-opencode-config/.github/workflows/security.yml@refs/tags/$tag" `
  --cert-oidc-issuer https://token.actions.githubusercontent.com
```

Se passar, o arquivo saiu daquele workflow, naquela tag, sem ninguém no meio. A assinatura não diz que o código é bom — diz que é o mesmo código que a CI analisou e testou.

O que o script faz por padrão, e por quê:

- **Pergunta antes de alterar qualquer coisa.** Mostra o que vai instalar, qual modelo vai baixar e onde vai gravar. Pule com `-Force` se souber o que está fazendo.
- **Recusa rodar como administrador.** Um agente que executa comandos arbitrários não deveria ter privilégio de admin. Use `-AllowElevated` se tiver um motivo real.
- **Só aceita loopback.** A API do Ollama **não tem autenticação nenhuma**. Se você expor a porta 11434 na rede, qualquer um que alcançar a máquina usa seu modelo e lê seus prompts — que incluem seu código-fonte. O script recusa `OLLAMA_HOST` apontando para fora de `127.0.0.1` e avisa se detectar a porta escutando em outro endereço.
- **`bash` e `edit` pedem confirmação.** O OpenCode executa comandos e edita arquivos com base no que o modelo decidir. O perfil `Strict` deixa você no circuito.
- **Backup antes de escrever.** Seu `opencode.json` atual é copiado com timestamp e as chaves que já existiam (tema, outros providers, outros modelos) são preservadas.
- **ACL restritiva.** O arquivo de config e os backups ficam acessíveis só para você e para o SYSTEM, com herança quebrada.
- **Não deixa sujeira na sua sessão.** Rodando via `iex`, o script está no seu escopo global. Ele salva e restaura `$ErrorActionPreference` e `$ProgressPreference`, e não usa `exit` — que fecharia seu terminal.
- **Log estruturado.** JSONL com timestamp UTC em `%LOCALAPPDATA%\opencode-setup\`, pronto para SIEM. Sem segredos, sem prompts.
- **Nomes de modelo validados por regex.** Eles vão parar em linha de comando e dentro de um Modelfile; `bad;rm -rf /` é rejeitado antes de chegar lá.

O que ele **não** faz: não verifica a assinatura Authenticode dos instaladores baixados pelo winget. Se seu ambiente é regulado, hospede um fork interno.

Achou algo? Veja [SECURITY.md](SECURITY.md).

## Quando algo dá errado

**Acentos saindo como `Ã§Ã£o`**
Não deveria acontecer: o script é ASCII puro. Se acontecer, você tem uma cópia antiga.

**`Ollama instalado, mas ausente do PATH`**
Feche e reabra o terminal, depois rode com `-SkipInstall`.

**O OpenCode não chama ferramentas / não edita arquivos**
Quase sempre é contexto pequeno. Rode com `-ShowPlanOnly` e confira se o `num_ctx` está em 32k ou mais.

**Respostas absurdamente lentas**
O modelo não coube na VRAM e está sendo processado na RAM. O plano mostra o orçamento real — escolha um modelo abaixo dele.

**A execução some sem mensagem no PowerShell 5.1**
Política de execução. Rode `powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1` (escopo de processo, não altera a máquina).

## Desenvolvimento

```powershell
Invoke-Pester ./tests
Invoke-ScriptAnalyzer -Path . -Recurse -Severity Warning
```

Os testes carregam o `install.ps1` com ponto (`. .\install.ps1`). O script detecta isso pelo `$MyInvocation.InvocationName` e expõe as funções sem executar o provisionamento — é o que permite testar tudo mantendo arquivo único.

Quatro regras que os testes garantem, e que não são negociáveis:

- **ASCII puro, sem BOM.** O PowerShell 5.1 lê `.ps1` sem BOM na codepage ANSI, e o console usa outra. Qualquer byte acima de `0x7F` vira lixo na tela.
- **Nada de sintaxe do PowerShell 7.** Sem ternário, `??`, `&&`, `ConvertFrom-Json -AsHashtable`. A maioria das máquinas Windows ainda só tem o 5.1.
- **Sem `exit`, sem `$PSScriptRoot`, sem `$PSCmdlet`, sem `#Requires`.** Nada disso funciona quando o código chega por `iex`: não há arquivo em disco, não há contexto de cmdlet, e `exit` fecharia a sessão do usuário.
- **A confirmação antes de alterar a máquina tem que existir.** Um teste falha se ela sumir.

### Pipeline

`ci.yml` responde "funciona?"; `security.yml` responde "é seguro?".

| Verificação | Ferramenta | Onde |
|---|---|---|
| Testes | Pester 5.7.1, em PowerShell 5.1 **e** 7 | `ci.yml` |
| Execução via `irm \| iex` | o próprio script, nos dois shells | `ci.yml` |
| Encoding e integridade do blob | ASCII, BOM, `git ls-files --eol`, blob vs arquivo | `ci.yml` |
| SAST PowerShell | PSScriptAnalyzer 1.24.0 → SARIF → code scanning | `security.yml` |
| SAST dos workflows | CodeQL (`actions`) + zizmor | `security.yml` |
| SCA / supply chain | pin por SHA, versão exata no PSGallery, Dependabot | `security.yml` |
| Segredos | gitleaks, histórico completo | `security.yml` |
| Assinatura | Sigstore keyless + SHA-256, em tags | `security.yml` |

Sobre o que **não** está aqui, para ninguém procurar: **DAST** não se aplica — não há aplicação web; o mais próximo é a checagem em runtime de que a porta do Ollama não escuta fora de loopback. **Scan de container** não se aplica — não há imagem. **Scan de IaC** é coberto pelo CodeQL e pelo zizmor nos workflows, que é a única infra declarada aqui.

Também não há SCA clássico porque não há dependência de runtime: o `install.ps1` não importa nenhum módulo, e um teste falha se alguém introduzir um `Import-Module`. A superfície de supply chain que existe de fato são as Actions do CI e os módulos do PSGallery — e é exatamente isso que o job `supply-chain` verifica.

Para rodar as mesmas checagens localmente:

```powershell
Invoke-Pester ./tests
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

```bash
pipx run zizmor .github/workflows/
actionlint
```

Para adicionar um modelo ao catálogo, edite `$script:ModelCatalog`. Diga no PR em que hardware você mediu.

## Licença

MIT. Veja [LICENSE](LICENSE).

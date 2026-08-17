# Política de Segurança

## Como reportar

Não abra issue pública para vulnerabilidade.

Use **Security > Report a vulnerability** no GitHub (Private Vulnerability Reporting) ou mande e-mail para o mantenedor listado no perfil do repositório.

Inclua: o que acontece, como reproduzir, versão do PowerShell e do Windows, e o impacto que você enxerga. Se puder, anexe a saída de `.\Get-OllamaHostInventory.ps1 -AsJson`.

Resposta em até 5 dias úteis. Correção conforme a gravidade. Você é creditado no release, salvo se preferir o contrário.

## O que está no escopo

- Execução de código a partir de entrada não confiável (nome de modelo, caminho, conteúdo do `opencode.json`).
- Escalação de privilégio ou escrita fora dos diretórios esperados.
- Vazamento de credencial, token ou conteúdo de prompt em log, config ou stdout.
- Configuração gerada que exponha o Ollama fora de loopback.
- Falha de permissão que deixe o `opencode.json` legível por outros usuários.

## O que está fora do escopo

- Vulnerabilidades no Ollama, no OpenCode ou nos modelos. Reporte no projeto de origem.
- O fato de o OpenCode executar comandos sugeridos pelo modelo. Isso é o produto funcionando; o perfil `Strict` é a mitigação e está ligado por padrão.
- Uso deliberadamente inseguro: `-AllowElevated`, `-PermissionProfile Standard` ou `OLLAMA_HOST` apontando para fora de loopback são escolhas conscientes do operador, e todas emitem aviso.

## Modelo de ameaça resumido

O que este projeto protege:

| Ameaça | Controle |
|---|---|
| Injeção de argumento via nome de modelo | Validação por regex + arrays de argumentos, nunca concatenação |
| Agente executando comando destrutivo | `bash` e `edit` exigem confirmação por padrão |
| Exposição da API do Ollama na rede | Endpoint restrito a loopback; verificação ativa da porta após instalar |
| Config lida por outro usuário da máquina | ACL com herança quebrada: só o dono e o SYSTEM |
| Perda da configuração existente | Backup com timestamp antes de qualquer escrita |
| Pacote errado na instalação | `winget --exact --id`; `npm --ignore-scripts` |
| Ausência de rastreabilidade | Log JSONL em UTC, gravado inclusive em `-WhatIf` |

O que ele **não** protege:

- A API do Ollama continua sem autenticação. A única barreira é o bind em loopback: qualquer processo local rodando com o seu usuário consegue usá-la.
- Não há verificação de assinatura dos instaladores baixados pelo winget.
- Um modelo local comprometido ou envenenado pode sugerir comandos maliciosos. O perfil `Strict` te dá a chance de recusar, mas a decisão é sua.

## Se você for publicar um fork

Não commite `opencode.json` com caminhos internos, nem os logs de `%LOCALAPPDATA%\opencode-setup\`. O `.gitignore` já cobre os dois.

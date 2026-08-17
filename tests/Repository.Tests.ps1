#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Testes de higiene do arquivo publicado.

    Existem porque as regressoes que mais doeram neste projeto nao foram de
    logica: foram encoding e compatibilidade com o Windows PowerShell 5.1.
    Ambas sao detectaveis estaticamente.

    Como o install.ps1 e servido para 'irm | iex', ele tambem precisa
    sobreviver a execucao sem arquivo em disco. Isso e verificado aqui.

    Encoding: ASCII puro, sem BOM, CRLF.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:MainScript = Join-Path $script:RepoRoot 'install.ps1'
    $script:PsFiles = @(
        Get-ChildItem -Path $script:RepoRoot -Recurse -Include '*.ps1', '*.psm1', '*.psd1' -File |
            Where-Object { $_.FullName -notmatch '[\\/](\.git|node_modules)[\\/]' }
    )
}

Describe 'Encoding' {
    It 'encontrou arquivos para analisar' {
        $script:PsFiles.Count | Should -BeGreaterThan 0
    }

    It 'nao usa nenhum byte acima de 0x7F' {
        # O PS 5.1 le .ps1 sem BOM na codepage ANSI e o console usa outra:
        # qualquer byte fora de ASCII vira mojibake na tela.
        $violacoes = @()
        foreach ($file in $script:PsFiles) {
            foreach ($b in [System.IO.File]::ReadAllBytes($file.FullName)) {
                if ($b -gt 127) { $violacoes += $file.Name; break }
            }
        }
        $violacoes -join '; ' | Should -BeNullOrEmpty
    }

    It 'nao comeca com BOM' {
        # Servido via HTTP e passado por iex, um BOM aparece como caractere
        # invisivel no inicio do primeiro token e quebra o parse.
        $violacoes = @()
        foreach ($file in $script:PsFiles) {
            $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
            if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
                $violacoes += $file.Name
            }
        }
        $violacoes -join '; ' | Should -BeNullOrEmpty
    }
}

Describe 'Compatibilidade com Windows PowerShell 5.1' {
    It 'nao usa sintaxe exclusiva do PowerShell 7 (ternario, ??, &&, ||)' {
        $proibidos = @('TernaryExpressionAst', 'CoalesceExpressionAst', 'PipelineChainAst')
        $violacoes = @()
        foreach ($file in $script:PsFiles) {
            $errors = $null
            $tokens = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            foreach ($tipo in $proibidos) {
                foreach ($a in $ast.FindAll({ param($n) $n.GetType().Name -eq $tipo }, $true)) {
                    $violacoes += "$($file.Name):$($a.Extent.StartLineNumber) $tipo"
                }
            }
        }
        $violacoes -join '; ' | Should -BeNullOrEmpty
    }

    It 'nao usa cmdlets ou parametros indisponiveis no 5.1' {
        # Os testes citam esses nomes como padrao de busca; analisa-los daria
        # falso positivo permanente.
        $alvos = @($script:PsFiles | Where-Object { $_.FullName -notmatch '[\\/]tests[\\/]' })
        $padroes = @(
            @{ Regex = '-AsHashtable'; Motivo = 'ConvertFrom-Json -AsHashtable requer PS 6+' }
            @{ Regex = 'utf8NoBOM|utf8BOM'; Motivo = 'valor de -Encoding do PS 6+' }
            @{ Regex = '\bJoin-String\b|\bGet-Error\b|\bTest-Json\b'; Motivo = 'cmdlet exclusivo do PS 7' }
        )
        $violacoes = @()
        foreach ($file in $alvos) {
            # Tokeniza em vez de varrer linha a linha: a documentacao do
            # proprio script cita esses nomes para explicar por que NAO os
            # usa, e um filtro de '^#' nao pega comentario de bloco <# #>.
            $errors = $null
            $tokens = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile(
                $file.FullName, [ref]$tokens, [ref]$errors)

            foreach ($token in $tokens) {
                if ($token.Kind -eq 'Comment') { continue }
                foreach ($p in $padroes) {
                    if ($token.Text -match $p.Regex) {
                        $violacoes += "$($file.Name):$($token.Extent.StartLineNumber) $($p.Motivo)"
                    }
                }
            }
        }
        $violacoes -join '; ' | Should -BeNullOrEmpty
    }
}

Describe 'Execucao remota (irm | iex)' {
    It 'nao contem instrucao #Requires, invalida fora de arquivo de script' {
        $linhas = Get-Content -LiteralPath $script:MainScript
        @($linhas | Where-Object { $_ -match '^\s*#Requires' }).Count | Should -Be 0
    }

    It 'nao usa exit, que encerraria a sessao do usuario em modo iex' {
        $errors = $null
        $tokens = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($script:MainScript, [ref]$tokens, [ref]$errors)
        $exits = @($tokens | Where-Object { $_.Kind -eq 'Exit' })
        $exits.Count | Should -Be 0
    }

    It 'nao usa variaveis indisponiveis fora de arquivo de script' {
        # Token a token: os comentarios do script citam $PSScriptRoot e
        # $PSCmdlet justamente para explicar por que nao sao usados.
        $errors = $null
        $tokens = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:MainScript, [ref]$tokens, [ref]$errors)

        $proibidas = @('PSScriptRoot', 'PSCmdlet', 'PSCommandPath')
        $violacoes = @()
        foreach ($token in $tokens) {
            if ($token.Kind -eq 'Comment') { continue }
            if ($token -is [System.Management.Automation.Language.VariableToken]) {
                if ($proibidas -contains $token.Name.UserPath) {
                    $violacoes += "linha $($token.Extent.StartLineNumber): `$$($token.Name.UserPath)"
                }
            }
        }
        $violacoes -join '; ' | Should -BeNullOrEmpty
    }

    It 'restaura as preferencias alteradas na sessao' {
        $conteudo = Get-Content -LiteralPath $script:MainScript -Raw
        $conteudo | Should -Match 'finally'
        $conteudo | Should -Match '\$ErrorActionPreference = \$script:PrefErrorAction'
    }

    It 'e parseavel como scriptblock, exatamente como o iex faz' {
        $texto = Get-Content -LiteralPath $script:MainScript -Raw
        { [scriptblock]::Create($texto) } | Should -Not -Throw
    }

    It 'aceita parametros quando invocado como scriptblock' {
        $texto = Get-Content -LiteralPath $script:MainScript -Raw
        $sb = [scriptblock]::Create($texto)
        # O bloco param() precisa sobreviver a criacao dinamica, senao a forma
        # '& ([scriptblock]::Create((irm ...))) -ShowPlanOnly' nao funciona.
        $sb.Ast.ParamBlock | Should -Not -BeNullOrEmpty
        @($sb.Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) |
            Should -Contain 'ShowPlanOnly'
    }
}

Describe 'Higiene de seguranca' {
    It 'nao contem segredos em texto claro' {
        $padroes = @(
            'sk-[A-Za-z0-9]{20,}'
            'ghp_[A-Za-z0-9]{20,}'
            'AKIA[0-9A-Z]{16}'
            '-----BEGIN [A-Z ]*PRIVATE KEY-----'
        )
        $violacoes = @()
        foreach ($file in $script:PsFiles) {
            $conteudo = Get-Content -LiteralPath $file.FullName -Raw
            foreach ($p in $padroes) {
                if ($conteudo -match $p) { $violacoes += "$($file.Name): $p" }
            }
        }
        $violacoes -join '; ' | Should -BeNullOrEmpty
    }

    It 'mantem o endpoint restrito a loopback' {
        $conteudo = Get-Content -LiteralPath $script:MainScript -Raw
        $conteudo | Should -Match "127\\\.0\\\.0\\\.1\|localhost"
        $conteudo | Should -Not -Match 'baseURL\s*=\s*.http://0\.0\.0\.0'
    }

    It 'pede confirmacao antes de alterar a maquina' {
        # Sem isso, 'irm | iex' instalaria coisas sem o usuario dizer sim.
        $conteudo = Get-Content -LiteralPath $script:MainScript -Raw
        $conteudo | Should -Match 'function Confirm-Execution'
        $conteudo | Should -Match 'if \(-not \(Confirm-Execution\)\)'
    }
}

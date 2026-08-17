<#
    Configuracao do PSScriptAnalyzer.

    Regra geral: TODAS as regras de seguranca ficam ligadas. As exclusoes
    abaixo sao apenas de estilo, e cada uma tem uma justificativa concreta.
    Excluir regra de seguranca aqui exige revisao no pull request.

    Encoding: ASCII puro, sem BOM.
#>

@{
    # Analisa tudo, e as exclusoes abaixo tiram apenas o que nao se aplica.
    IncludeDefaultRules = $true

    Severity = @('Error', 'Warning', 'Information')

    ExcludeRules = @(
        # O script e uma ferramenta de linha de comando interativa: a saida
        # formatada e o produto, nao efeito colateral. Write-Output aqui
        # poluiria o pipeline de quem chama o script via scriptblock.
        'PSAvoidUsingWriteHost',

        # $global:LASTEXITCODE e a unica forma de propagar o codigo de saida
        # de processo externo, e de devolver status ao chamador em modo iex
        # (onde 'exit' fecharia a sessao do usuario).
        'PSAvoidGlobalVars',

        # O controle de operacao mutante e feito por Test-Approved, e nao por
        # SupportsShouldProcess nas funcoes internas. Motivo em Test-Approved:
        # executado via 'iex' o script roda no escopo global, onde $PSCmdlet
        # pode nao existir e $PSCmdlet.ShouldProcess quebraria sob StrictMode.
        # O parametro -WhatIf continua funcionando via $WhatIfPreference.
        'PSUseShouldProcessForStateChangingFunctions',

        # Install-Dependencies e Assert-Preconditions operam sobre conjuntos.
        # O plural descreve o que a funcao faz melhor que o singular forcado.
        'PSUseSingularNouns',

        # Os arquivos sao ASCII puro por decisao de projeto (ver .gitattributes
        # e README). BOM quebraria a execucao via 'irm | iex'.
        'PSUseBOMForUnicodeEncodedFile'
    )

    Rules = @{
        # Compatibilidade de sintaxe com as duas versoes suportadas.
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }

        # Correcao de estilo que ajuda revisao de seguranca: bloco mal
        # indentado esconde escopo errado.
        PSPlaceOpenBrace = @{
            Enable             = $true
            OnSameLine         = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }

        PSUseConsistentIndentation = @{
            Enable              = $true
            Kind                = 'space'
            IndentationSize     = 4
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
        }
    }
}

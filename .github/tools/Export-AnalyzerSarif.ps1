<#
.SYNOPSIS
    Converte a saida do PSScriptAnalyzer para SARIF 2.1.0.

.DESCRIPTION
    O GitHub code scanning consome SARIF. O PSScriptAnalyzer nao emite esse
    formato, e existe modulo de terceiro para isso - mas para trinta linhas de
    mapeamento nao vale acrescentar dependencia de supply chain a um pipeline
    de seguranca. A conversao fica aqui, versionada e testavel.

    Mapeamento de severidade:
      Error       -> error
      Warning     -> warning
      Information -> note

.PARAMETER Diagnostics
    Objetos DiagnosticRecord vindos de Invoke-ScriptAnalyzer.

.PARAMETER OutputPath
    Arquivo .sarif a ser gravado.

.PARAMETER RepoRoot
    Raiz do repositorio. Os caminhos no SARIF precisam ser relativos a ela,
    senao o GitHub nao consegue anotar as linhas no pull request.

.EXAMPLE
    $d = Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
    .\.github\tools\Export-AnalyzerSarif.ps1 -Diagnostics $d -OutputPath results.sarif

.NOTES
    Vive sob .github/ porque seu unico consumidor e o workflow security.yml.

    Encoding: ASCII puro, sem BOM, CRLF.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Diagnostics,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [string]$RepoRoot = (Get-Location).Path
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function ConvertTo-SarifLevel {
    param([string]$Severity)
    switch ($Severity) {
        'Error' { return 'error' }
        'Warning' { return 'warning' }
        'Information' { return 'note' }
        'ParseError' { return 'error' }
        default { return 'warning' }
    }
}

function ConvertTo-RelativeUri {
    <#
    .SYNOPSIS
        Caminho relativo a raiz do repositorio, com barras normais.
    #>
    param([string]$Path, [string]$Root)

    if (-not $Path) { return 'desconhecido' }

    $normalizado = $Path -replace '\\', '/'
    $raiz = ($Root -replace '\\', '/').TrimEnd('/')

    if ($raiz -and $normalizado.StartsWith($raiz, [StringComparison]::OrdinalIgnoreCase)) {
        $normalizado = $normalizado.Substring($raiz.Length)
    }

    return $normalizado.TrimStart('/')
}

$regras = @{}
$resultados = @()

foreach ($d in @($Diagnostics)) {
    if ($null -eq $d) { continue }

    $ruleName = "$($d.RuleName)"
    if (-not $ruleName) { $ruleName = 'PSScriptAnalyzer' }

    if (-not $regras.ContainsKey($ruleName)) {
        $regra = [ordered]@{
            id                   = $ruleName
            name                 = $ruleName
            shortDescription     = [ordered]@{ text = $ruleName }
            defaultConfiguration = [ordered]@{ level = (ConvertTo-SarifLevel -Severity "$($d.Severity)") }
            helpUri              = "https://learn.microsoft.com/powershell/utility-modules/psscriptanalyzer/rules/$ruleName"
        }
        $regras[$ruleName] = $regra
    }

    $arquivo = ''
    $linha = 1
    $coluna = 1
    if ($d.PSObject.Properties.Name -contains 'ScriptPath') { $arquivo = "$($d.ScriptPath)" }
    if ($d.PSObject.Properties.Name -contains 'Line' -and $d.Line) { $linha = [int]$d.Line }
    if ($d.PSObject.Properties.Name -contains 'Column' -and $d.Column) { $coluna = [int]$d.Column }

    # SARIF exige startLine >= 1; PSScriptAnalyzer pode devolver 0.
    if ($linha -lt 1) { $linha = 1 }
    if ($coluna -lt 1) { $coluna = 1 }

    $resultados += [ordered]@{
        ruleId    = $ruleName
        level     = (ConvertTo-SarifLevel -Severity "$($d.Severity)")
        message   = [ordered]@{ text = "$($d.Message)" }
        locations = @(
            [ordered]@{
                physicalLocation = [ordered]@{
                    artifactLocation = [ordered]@{
                        uri = (ConvertTo-RelativeUri -Path $arquivo -Root $RepoRoot)
                    }
                    region           = [ordered]@{
                        startLine   = $linha
                        startColumn = $coluna
                    }
                }
            }
        )
    }
}

$sarif = [ordered]@{
    '$schema' = 'https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json'
    version   = '2.1.0'
    runs      = @(
        [ordered]@{
            tool    = [ordered]@{
                driver = [ordered]@{
                    name           = 'PSScriptAnalyzer'
                    informationUri = 'https://github.com/PowerShell/PSScriptAnalyzer'
                    rules          = @($regras.Values)
                }
            }
            results = @($resultados)
        }
    )
}

$json = $sarif | ConvertTo-Json -Depth 12

# Caminho absoluto respeitando o que o usuario passou: Join-Path cego
# transformaria '/tmp/x.sarif' em '<cwd>/tmp/x.sarif'.
if ([System.IO.Path]::IsPathRooted($OutputPath)) {
    $destino = $OutputPath
}
else {
    $destino = Join-Path (Get-Location).Path $OutputPath
}
$destino = [System.IO.Path]::GetFullPath($destino)

$encoding = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($destino, $json, $encoding)

Write-Host ("SARIF gravado em {0}: {1} resultado(s), {2} regra(s)." -f $OutputPath, $resultados.Count, $regras.Count)

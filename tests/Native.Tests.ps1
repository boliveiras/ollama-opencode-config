#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Testes da execucao de processos externos.

    Existem por causa de um bug real: com $ErrorActionPreference = 'Stop', o
    Windows PowerShell 5.1 transforma a PRIMEIRA linha que um processo escreve
    em stderr num erro terminante, mesmo que o processo esteja indo bem e
    termine com exit 0. O 'ollama pull' escreve o progresso em stderr, entao
    o download de modelo morria na linha 'pulling manifest'.

    O PowerShell 7 nao se comporta assim, entao o teste so pega a regressao
    quando roda no 5.1 - e por isso a CI executa a suite nos dois shells.

    Encoding: ASCII puro, sem BOM, CRLF.
#>

BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'install.ps1')
    Initialize-AuditLog

    # cmd.exe da controle fino sobre stderr e codigo de saida no Windows.
    $script:TemCmd = [bool](Get-Command cmd.exe -ErrorAction SilentlyContinue)
}

Describe 'Invoke-Native com processo que escreve em stderr' {
    It 'nao aborta quando o processo escreve em stderr e retorna 0' -Skip:(-not $script:TemCmd) {
        # Regressao: era aqui que o 'ollama pull' morria no PS 5.1.
        $ErrorActionPreference = 'Stop'
        $r = Invoke-Native -FilePath 'cmd.exe' -Arguments @('/c', 'echo pulling manifest 1>&2 & exit 0')
        $r.ExitCode | Should -Be 0
    }

    It 'ainda falha quando o codigo de saida indica erro' -Skip:(-not $script:TemCmd) {
        $ErrorActionPreference = 'Stop'
        { Invoke-Native -FilePath 'cmd.exe' -Arguments @('/c', 'echo falha real 1>&2 & exit 3') } |
            Should -Throw -ExpectedMessage '*exit=3*'
    }

    It 'inclui a saida do processo na mensagem de erro' -Skip:(-not $script:TemCmd) {
        $ErrorActionPreference = 'Stop'
        { Invoke-Native -FilePath 'cmd.exe' -Arguments @('/c', 'echo disco cheio 1>&2 & exit 1') } |
            Should -Throw -ExpectedMessage '*disco cheio*'
    }

    It 'respeita -IgnoreExitCode' -Skip:(-not $script:TemCmd) {
        $ErrorActionPreference = 'Stop'
        $r = Invoke-Native -FilePath 'cmd.exe' -Arguments @('/c', 'exit 5') -IgnoreExitCode
        $r.ExitCode | Should -Be 5
    }

    It 'devolve ErrorActionPreference ao valor anterior' -Skip:(-not $script:TemCmd) {
        $ErrorActionPreference = 'Stop'
        $null = Invoke-Native -FilePath 'cmd.exe' -Arguments @('/c', 'exit 0')
        $ErrorActionPreference | Should -Be 'Stop'
    }
}

Describe 'Format-NativeOutput' {
    It 'remove retorno de carro, que apagaria a mensagem de erro no console' {
        $texto = Format-NativeOutput -Lines @("pulling 45%`r pulling 90%`r pronto")
        $texto.Contains([char]13) | Should -BeFalse
    }

    It 'remove sequencias ANSI de cor' {
        $esc = [char]27
        $texto = Format-NativeOutput -Lines @("$esc[32mverde$esc[0m", 'erro')
        $texto.Contains([char]27) | Should -BeFalse
        $texto | Should -Match 'verde'
    }

    It 'preserva a ultima linha, que costuma ser a causa real' {
        $texto = Format-NativeOutput -Lines @("progresso`r mais progresso", 'erro: disco cheio')
        $texto | Should -Match 'disco cheio'
    }

    It 'descarta linhas vazias geradas pela limpeza' {
        $texto = Format-NativeOutput -Lines @("a`r`n`r`n`r`nb")
        @($texto -split [Environment]::NewLine).Count | Should -Be 2
    }

    It 'limita a quantidade de linhas' {
        $texto = Format-NativeOutput -Lines (1..50 | ForEach-Object { "linha $_" }) -Last 3
        @($texto -split [Environment]::NewLine).Count | Should -Be 3
    }

    It 'aceita entrada vazia sem estourar' {
        Format-NativeOutput -Lines @() | Should -BeNullOrEmpty
        Format-NativeOutput -Lines $null | Should -BeNullOrEmpty
    }
}

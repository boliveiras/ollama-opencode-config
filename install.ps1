<#
.SYNOPSIS
    Configura o OpenCode com modelos locais do Ollama, escolhendo modelo e
    janela de contexto de acordo com o hardware da maquina.

.DESCRIPTION
    Arquivo unico, autocontido, executavel remotamente.

    Uso remoto (sem argumentos):
        irm https://raw.githubusercontent.com/boliveiras/ollama-opencode-config/main/install.ps1 | iex

    Uso remoto (com argumentos):
        & ([scriptblock]::Create((irm https://raw.githubusercontent.com/boliveiras/ollama-opencode-config/main/install.ps1))) -ShowPlanOnly

    Uso local:
        .\install.ps1 -WhatIf

    ATENCAO: executar codigo remoto direto no shell e execucao de codigo
    arbitrario por definicao. Antes de confiar, baixe e leia:
        $src = irm https://raw.githubusercontent.com/boliveiras/ollama-opencode-config/main/install.ps1
        $src > install.ps1   # leia o arquivo
        .\install.ps1 -ShowPlanOnly
    E prefira fixar uma tag (.../refs/tags/v1.0.0/install.ps1) em vez de 'main'.

.NOTES
    Compativel com Windows PowerShell 5.1 e PowerShell 7+.
    Encoding: ASCII puro, sem BOM, CRLF. NAO reintroduza acentuacao: o PS 5.1
    le .ps1 sem BOM na codepage ANSI e qualquer byte acima de 0x7F vira lixo.

    Sem instrucao #Requires: ela nao e valida quando o conteudo e executado
    via iex ou scriptblock. A verificacao de versao e feita em tempo de
    execucao logo abaixo.
#>

# ATENCAO: este bloco param() NAO usa atributos de validacao (ValidatePattern,
# ValidateRange, ValidateSet, ValidateNotNullOrEmpty) de proposito.
#
# Executado via 'iex', o script roda no escopo GLOBAL. Ali o PowerShell anexa
# os atributos a variaveis daquele escopo e valida o valor corrente na hora da
# anexacao: um parametro nao informado vale '' ou 0, o que dispara
#   "The attribute cannot be added because variable Model with value would no
#    longer be valid"
# e aborta antes da primeira linha util. A validacao equivalente esta em
# Assert-ParameterSanity, chamada no inicio de Invoke-Main.
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # Omitido -> escolhido automaticamente a partir do hardware detectado.
    [string]$Model,

    # Omitido -> dimensionado automaticamente pelo orcamento de memoria.
    [int]$ContextLength,

    # User | Project
    [string]$ConfigScope = 'User',

    [string]$ProjectPath = (Get-Location).Path,

    # Strict | Standard
    [string]$PermissionProfile = 'Strict',

    # Apenas loopback. A API do Ollama nao tem autenticacao.
    [string]$OllamaEndpoint = '127.0.0.1:11434',

    [switch]$SkipInstall,
    [switch]$SkipModelPull,

    # Desliga a deteccao e usa um perfil conservador.
    [switch]$NoAutoDetect,

    # Detecta, imprime o plano e encerra sem alterar nada.
    [switch]$ShowPlanOnly,

    # Pula a confirmacao interativa antes de alterar a maquina.
    [switch]$Force,

    # Permite execucao elevada (desencorajado - viola least privilege).
    [switch]$AllowElevated,

    [string]$LogPath
)

$script:ScriptVersion = '1.0.1'

# Padroes de validacao. Vivem aqui porque nao podem ser atributos do param()
# (ver o comentario acima do bloco).
$script:ModelTagPattern = '^[a-z0-9]([a-z0-9._-]*[a-z0-9])?(/[a-z0-9]([a-z0-9._-]*[a-z0-9])?)?(:[A-Za-z0-9._-]+)?$'
$script:EndpointPattern = '^(127\.0\.0\.1|localhost|\[::1\]):(6[0-5][0-9]{3}|[1-9][0-9]{0,4})$'

# ---------------------------------------------------------------------------
# Verificacao de versao em tempo de execucao (substitui #Requires)
# ---------------------------------------------------------------------------
if ($PSVersionTable.PSVersion -lt [Version]'5.1') {
    throw "Este script exige PowerShell 5.1 ou superior. Versao atual: $($PSVersionTable.PSVersion)."
}

# ---------------------------------------------------------------------------
# Preferencias
#
# Executado via 'iex', este codigo roda no escopo GLOBAL: alterar preferencias
# sem restaurar contaminaria a sessao interativa do usuario. Guardamos os
# valores originais e devolvemos no bloco finally do final do arquivo.
# ---------------------------------------------------------------------------
$script:PrefErrorAction = $ErrorActionPreference
$script:PrefProgress = $ProgressPreference
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($null -eq $global:LASTEXITCODE) { $global:LASTEXITCODE = 0 }

# ---------------------------------------------------------------------------
# Camada de compatibilidade 5.1 / 7+
# O PS 5.1 nao possui: operador ternario, ConvertFrom-Json -AsHashtable,
# -Encoding utf8NoBOM e a variavel automatica $IsWindows.
# ---------------------------------------------------------------------------
if ($PSVersionTable.PSVersion.Major -lt 6) {
    $script:OnWindows = $true
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }
    catch {
        Write-Warning "Nao foi possivel fixar TLS 1.2 nesta sessao: $($_.Exception.Message)"
    }
}
else {
    $script:OnWindows = $IsWindows
}

[System.IO.Directory]::SetCurrentDirectory((Get-Location).Path)

# O que o usuario informou explicitamente decide o que sera autodetectado.
$script:AutoModel = -not $PSBoundParameters.ContainsKey('Model')
$script:AutoContext = -not $PSBoundParameters.ContainsKey('ContextLength')

# ---------------------------------------------------------------------------
# Constantes
# ---------------------------------------------------------------------------
$script:Constants = @{
    OllamaWingetId   = 'Ollama.Ollama'
    OpencodeWingetId = 'SST.opencode'
    OpencodeNpmId    = 'opencode-ai'
    NpmProvider      = '@ai-sdk/openai-compatible'
    ProviderKey      = 'ollama'
    HealthTimeoutSec = 5
    StartupWaitSec   = 60
    ConfigSchema     = 'https://opencode.ai/config.json'
}

$script:BaseUrl = "http://$OllamaEndpoint/v1"
$script:ApiRoot = "http://$OllamaEndpoint"
$script:LogFile = $null
$script:Findings = New-Object System.Collections.Generic.List[string]

# Perfil conservador: usado com -NoAutoDetect ou quando a deteccao falha.
$script:FallbackModel = 'qwen2.5-coder:7b'
$script:FallbackContext = 32768

# ===========================================================================
# SECAO 1 - Dimensionamento
#
# WeightsGB : tamanho aproximado dos pesos em quantizacao Q4_K_M.
# KvPer1k   : GB de cache KV por 1024 tokens de contexto.
# MaxCtx    : contexto maximo suportado pelo modelo.
#
# Estimativas de engenharia para escolher um ponto de partida seguro, nao
# medicoes. PRs com numeros medidos em hardware real sao bem-vindos.
# ===========================================================================
$script:ModelCatalog = @(
    [pscustomobject]@{
        Tag = 'qwen3-coder:30b'; ParamsB = 30
        WeightsGB = 18.6; KvPer1k = 0.105; MaxCtx = 262144; Rank = 100
        Notes = 'MoE 30B-A3B. Melhor tool calling do catalogo.'
    }
    [pscustomobject]@{
        Tag = 'devstral:24b'; ParamsB = 24
        WeightsGB = 14.3; KvPer1k = 0.085; MaxCtx = 131072; Rank = 90
        Notes = 'Denso, treinado para fluxos agenticos de codigo.'
    }
    [pscustomobject]@{
        Tag = 'qwen2.5-coder:14b'; ParamsB = 14
        WeightsGB = 9.0; KvPer1k = 0.060; MaxCtx = 131072; Rank = 70
        Notes = 'Melhor equilibrio entre qualidade e VRAM.'
    }
    [pscustomobject]@{
        Tag = 'qwen2.5-coder:7b'; ParamsB = 7
        WeightsGB = 4.7; KvPer1k = 0.035; MaxCtx = 131072; Rank = 50
        Notes = 'Roda em hardware modesto. Tool calling aceitavel.'
    }
    [pscustomobject]@{
        Tag = 'qwen2.5-coder:3b'; ParamsB = 3
        WeightsGB = 1.9; KvPer1k = 0.020; MaxCtx = 32768; Rank = 20
        Notes = 'Ultimo recurso. Tool calling encadeado falha com frequencia.'
    }
)

$script:MinUsableCtx = 32768      # abaixo disto o OpenCode perde tool calls
$script:HardFloorCtx = 16384      # abaixo disto o modelo e inutilizavel
$script:CpuModeCtxCap = 65536     # em CPU, prompt longo fica proibitivo
$script:GpuBudgetFactor = 0.85    # reserva para driver e desktop
$script:RamBudgetFactor = 0.50    # reserva para SO e ferramentas
$script:MinDedicatedVramGB = 4.0  # abaixo disto tratamos como iGPU
$script:DiskOverheadFactor = 1.2  # margem sobre o tamanho dos pesos

function Get-OllamaModelCatalog {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    return $script:ModelCatalog
}

function Get-SizingConstant {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return @{
        MinUsableCtx       = $script:MinUsableCtx
        HardFloorCtx       = $script:HardFloorCtx
        CpuModeCtxCap      = $script:CpuModeCtxCap
        GpuBudgetFactor    = $script:GpuBudgetFactor
        RamBudgetFactor    = $script:RamBudgetFactor
        MinDedicatedVramGB = $script:MinDedicatedVramGB
        DiskOverheadFactor = $script:DiskOverheadFactor
    }
}

function Invoke-Safely {
    <#
    .SYNOPSIS
        Executa um bloco e devolve um valor padrao em caso de falha.
    .DESCRIPTION
        A coleta de inventario e best-effort: a ausencia de um contador nao
        pode abortar o provisionamento.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Expression,
        $Default = $null
    )
    try { return & $Expression }
    catch {
        Write-Verbose "Coleta falhou: $($_.Exception.Message)"
        return $Default
    }
}

function Get-HostCpuInfo {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $desconhecida = @{ Name = 'desconhecida'; PhysicalCores = 0; LogicalCores = [Environment]::ProcessorCount; MaxClockMHz = 0 }
    if (-not $script:OnWindows) { return $desconhecida }

    $cpu = Invoke-Safely { @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)[0] }
    if (-not $cpu) { return $desconhecida }

    return @{
        Name          = "$($cpu.Name)".Trim()
        PhysicalCores = [int]$cpu.NumberOfCores
        LogicalCores  = [int]$cpu.NumberOfLogicalProcessors
        MaxClockMHz   = [int]$cpu.MaxClockSpeed
    }
}

function Get-HostMemoryInfo {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    if ($script:OnWindows) {
        $cs = Invoke-Safely { Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop }
        $os = Invoke-Safely { Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop }
        $total = 0.0
        $free = 0.0
        if ($cs) { $total = [math]::Round([double]$cs.TotalPhysicalMemory / 1GB, 1) }
        if ($os) { $free = [math]::Round([double]$os.FreePhysicalMemory * 1KB / 1GB, 1) }
        return @{ TotalGB = $total; AvailableGB = $free }
    }

    $total = 0.0
    $free = 0.0
    foreach ($line in @(Invoke-Safely { Get-Content '/proc/meminfo' -ErrorAction Stop } @())) {
        if ($line -match '^MemTotal:\s+(\d+)\s+kB') { $total = [math]::Round([double]$Matches[1] / 1MB, 1) }
        if ($line -match '^MemAvailable:\s+(\d+)\s+kB') { $free = [math]::Round([double]$Matches[1] / 1MB, 1) }
    }
    return @{ TotalGB = $total; AvailableGB = $free }
}

function Get-HostGpuInfo {
    <#
    .SYNOPSIS
        Enumera GPUs e a VRAM DEDICADA real.
    .DESCRIPTION
        Win32_VideoController.AdapterRAM e uint32 e satura em 4 GB, sendo
        inutil para placas modernas. A fonte confiavel no Windows e o valor
        HardwareInformation.qwMemorySize da chave de classe de video.
        Havendo driver NVIDIA, nvidia-smi e preferido por ser autoritativo.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    $found = @()

    $smi = Get-Command -Name 'nvidia-smi' -CommandType Application -ErrorAction SilentlyContinue
    if ($smi) {
        $raw = Invoke-Safely {
            & $smi.Source '--query-gpu=name,memory.total' '--format=csv,noheader,nounits' 2>$null
        } @()
        foreach ($line in @($raw)) {
            $text = "$line".Trim()
            if (-not $text) { continue }
            $parts = $text -split ','
            if ($parts.Count -lt 2) { continue }
            $found += [pscustomobject]@{
                Name        = $parts[0].Trim()
                DedicatedGB = [math]::Round([double]$parts[1].Trim() / 1024, 1)
                Source      = 'nvidia-smi'
            }
        }
    }

    if ($found.Count -gt 0 -or -not $script:OnWindows) { return $found }

    $classKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    foreach ($key in @(Invoke-Safely { Get-ChildItem -Path $classKey -ErrorAction Stop } @())) {
        if ($key.PSChildName -notmatch '^\d{4}$') { continue }
        $props = Invoke-Safely { Get-ItemProperty -Path $key.PSPath -ErrorAction Stop }
        if (-not $props) { continue }

        $names = $props.PSObject.Properties.Name
        if ($names -notcontains 'DriverDesc') { continue }

        $vram = 0.0
        if ($names -contains 'HardwareInformation.qwMemorySize') {
            $vram = [math]::Round([double]$props.'HardwareInformation.qwMemorySize' / 1GB, 1)
        }

        $found += [pscustomobject]@{
            Name        = "$($props.DriverDesc)".Trim()
            DedicatedGB = $vram
            Source      = 'registry'
        }
    }

    return $found
}

function Get-HostDiskInfo {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    if ($script:OnWindows) { $reference = $env:USERPROFILE } else { $reference = $HOME }
    if (-not $reference) { $reference = (Get-Location).Path }

    $root = Invoke-Safely { [System.IO.Path]::GetPathRoot($reference) } '/'
    $driveName = $root
    if ($script:OnWindows -and $root.Length -ge 1) { $driveName = $root.Substring(0, 1) }

    $drive = Invoke-Safely { Get-PSDrive -Name $driveName -PSProvider FileSystem -ErrorAction Stop }
    if (-not $drive) { return @{ Volume = $root; FreeGB = 0.0 } }

    return @{ Volume = $root; FreeGB = [math]::Round([double]$drive.Free / 1GB, 1) }
}

function Get-OllamaRuntimeInfo {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$ApiRoot = 'http://127.0.0.1:11434')

    $info = @{ Installed = $false; Version = $null; Reachable = $false; Models = @() }

    $cmd = Get-Command -Name 'ollama' -CommandType Application -ErrorAction SilentlyContinue
    if ($cmd) {
        $info.Installed = $true
        $info.Version = Invoke-Safely {
            (& $cmd.Source '--version' 2>$null | Select-Object -First 1) -replace '\s+', ' '
        }
    }

    $tags = Invoke-Safely {
        Invoke-RestMethod -Uri "$ApiRoot/api/tags" -TimeoutSec 5 -Method Get -ErrorAction Stop
    }
    if ($tags -and ($tags.PSObject.Properties.Name -contains 'models')) {
        $info.Reachable = $true
        $info.Models = @($tags.models | ForEach-Object {
                [pscustomobject]@{ Name = $_.name; SizeGB = [math]::Round([double]$_.size / 1GB, 1) }
            })
    }

    return $info
}

function Get-HostInventory {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$ApiRoot = 'http://127.0.0.1:11434')

    return @{
        CollectedUtc = [DateTime]::UtcNow.ToString('o')
        PsVersion    = $PSVersionTable.PSVersion.ToString()
        IsWindows    = $script:OnWindows
        Cpu          = Get-HostCpuInfo
        Memory       = Get-HostMemoryInfo
        Gpu          = @(Get-HostGpuInfo)
        Disk         = Get-HostDiskInfo
        Ollama       = Get-OllamaRuntimeInfo -ApiRoot $ApiRoot
    }
}

function Get-InferenceBudget {
    <#
    .SYNOPSIS
        Calcula o orcamento de memoria disponivel para inferencia.
    .DESCRIPTION
        Com GPU dedicada suficiente, o orcamento e uma fracao da VRAM: o que
        nao couber la sofre offload para RAM e derruba a taxa de tokens em
        uma ordem de grandeza. Sem GPU, usa fracao da RAM total.
        Funcao pura: nao le hardware, so calcula sobre o inventario recebido.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory = $true)][hashtable]$Inventory)

    $bestVram = 0.0
    $bestName = $null
    foreach ($g in @($Inventory.Gpu)) {
        if ($null -eq $g) { continue }
        if ([double]$g.DedicatedGB -gt $bestVram) {
            $bestVram = [double]$g.DedicatedGB
            $bestName = $g.Name
        }
    }

    if ($bestVram -ge $script:MinDedicatedVramGB) {
        return @{
            Mode       = 'GPU'
            BudgetGB   = [math]::Round($bestVram * $script:GpuBudgetFactor, 1)
            DeviceName = $bestName
            VramGB     = $bestVram
            Rationale  = "VRAM dedicada de $bestVram GB x $($script:GpuBudgetFactor) (reserva para driver e desktop)"
        }
    }

    $ram = [double]$Inventory.Memory.TotalGB
    return @{
        Mode       = 'CPU'
        BudgetGB   = [math]::Round($ram * $script:RamBudgetFactor, 1)
        DeviceName = $bestName
        VramGB     = $bestVram
        Rationale  = "Sem GPU dedicada com $($script:MinDedicatedVramGB) GB ou mais: RAM total de $ram GB x $($script:RamBudgetFactor)"
    }
}

function Get-FittedContext {
    <#
    .SYNOPSIS
        Maior num_ctx que cabe no orcamento para um modelo especifico.
    .DESCRIPTION
        ctx = (orcamento - pesos) / custo_kv_por_1k, truncado em blocos de 8k
        e limitado pelo maximo do modelo. Retorna 0 se nao couber de forma
        utilizavel. Funcao pura.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)][double]$BudgetGB,
        [Parameter(Mandatory = $true)]$Candidate,
        [ValidateSet('GPU', 'CPU')][string]$Mode = 'GPU'
    )

    $available = $BudgetGB - [double]$Candidate.WeightsGB
    if ($available -le 0) { return 0 }

    $kBlocks = [math]::Floor($available / [double]$Candidate.KvPer1k)
    $ctx = [int]([math]::Floor(($kBlocks * 1024) / 8192) * 8192)

    if ($ctx -gt [int]$Candidate.MaxCtx) { $ctx = [int]$Candidate.MaxCtx }
    if ($Mode -eq 'CPU' -and $ctx -gt $script:CpuModeCtxCap) { $ctx = $script:CpuModeCtxCap }
    if ($ctx -lt $script:HardFloorCtx) { return 0 }

    return $ctx
}

function Get-SizingPlan {
    <#
    .SYNOPSIS
        Avalia todo o catalogo e elege a melhor combinacao modelo/contexto.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Inventory,
        [object[]]$Catalog
    )

    if (-not $Catalog) { $Catalog = Get-OllamaModelCatalog }

    $budget = Get-InferenceBudget -Inventory $Inventory
    $freeDisk = [double]$Inventory.Disk.FreeGB

    $rows = @()
    foreach ($candidate in $Catalog) {
        $ctx = Get-FittedContext -BudgetGB $budget.BudgetGB -Candidate $candidate -Mode $budget.Mode
        $needDisk = [math]::Round([double]$candidate.WeightsGB * $script:DiskOverheadFactor, 1)

        if ($ctx -eq 0) {
            $status = 'NaoCabe'
            $reason = 'Pesos e cache KV excedem o orcamento de memoria'
        }
        elseif ($freeDisk -gt 0 -and $freeDisk -lt $needDisk) {
            $status = 'SemDisco'
            $reason = "Requer $needDisk GB livres, ha $freeDisk GB"
        }
        elseif ($ctx -lt $script:MinUsableCtx) {
            $status = 'Limitado'
            $reason = "Contexto abaixo de $($script:MinUsableCtx); tool calling fica instavel"
        }
        else {
            $status = 'Recomendado'
            $reason = 'Cabe com folga no orcamento'
        }

        $rows += [pscustomobject]@{
            Modelo  = $candidate.Tag
            PesosGB = $candidate.WeightsGB
            NumCtx  = $ctx
            DiscoGB = $needDisk
            Status  = $status
            Motivo  = $reason
            Rank    = $candidate.Rank
            Notas   = $candidate.Notes
        }
    }

    $best = @($rows | Where-Object { $_.Status -eq 'Recomendado' } |
            Sort-Object -Property Rank -Descending | Select-Object -First 1)
    if ($best.Count -eq 0) {
        $best = @($rows | Where-Object { $_.Status -eq 'Limitado' } |
                Sort-Object -Property Rank -Descending | Select-Object -First 1)
    }

    # Indexar array vazio lanca excecao sob StrictMode: sem candidato viavel,
    # Best precisa ser $null para o chamador cair no perfil de fallback.
    $chosen = $null
    if (@($best).Count -gt 0) { $chosen = @($best)[0] }

    return @{ Budget = $budget; Table = $rows; Best = $chosen }
}

function Write-SizingPlanReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Inventory,
        [Parameter(Mandatory = $true)][hashtable]$Plan
    )

    Write-Host ''
    Write-Host '=== Hardware detectado ===' -ForegroundColor Green
    Write-Host ("  CPU......: {0} ({1}C/{2}T)" -f $Inventory.Cpu.Name, $Inventory.Cpu.PhysicalCores, $Inventory.Cpu.LogicalCores)
    Write-Host ("  RAM......: {0} GB total / {1} GB livre" -f $Inventory.Memory.TotalGB, $Inventory.Memory.AvailableGB)
    if (@($Inventory.Gpu).Count -eq 0) {
        Write-Host '  GPU......: nenhuma detectada'
    }
    else {
        foreach ($g in @($Inventory.Gpu)) {
            Write-Host ("  GPU......: {0} - {1} GB dedicada [{2}]" -f $g.Name, $g.DedicatedGB, $g.Source)
        }
    }
    Write-Host ("  Disco....: {0} {1} GB livres" -f $Inventory.Disk.Volume, $Inventory.Disk.FreeGB)

    Write-Host ''
    Write-Host '=== Orcamento de memoria ===' -ForegroundColor Green
    Write-Host ("  Modo.....: {0}" -f $Plan.Budget.Mode)
    Write-Host ("  Criterio.: {0}" -f $Plan.Budget.Rationale)
    Write-Host ("  Orcamento: {0} GB" -f $Plan.Budget.BudgetGB)

    Write-Host ''
    Write-Host '=== Dimensionamento (pesos Q4_K_M, estimativa) ===' -ForegroundColor Green
    # Formatacao explicita: em hosts sem terminal a largura do console e
    # indefinida e Format-Table | Out-String devolveria uma tabela vazia.
    Write-Host ('  {0,-20} {1,8} {2,9} {3,9}  {4,-12} {5}' -f 'MODELO', 'PESOS_GB', 'NUM_CTX', 'DISCO_GB', 'STATUS', 'MOTIVO')
    Write-Host ('  ' + ('-' * 100))
    foreach ($row in $Plan.Table) {
        Write-Host ('  {0,-20} {1,8} {2,9} {3,9}  {4,-12} {5}' -f
            $row.Modelo, $row.PesosGB, $row.NumCtx, $row.DiscoGB, $row.Status, $row.Motivo)
    }
}

# ===========================================================================
# SECAO 2 - Infraestrutura (log, I/O, processos)
# ===========================================================================
function Write-Utf8File {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Add-Utf8Line {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Line
    )
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($Path, $Line + [Environment]::NewLine, $encoding)
}

function ConvertTo-HashtableDeep {
    <#
    .SYNOPSIS
        Substitui ConvertFrom-Json -AsHashtable, indisponivel no PS 5.1.
    #>
    [CmdletBinding()]
    param([Parameter(Position = 0)]$InputObject)

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in @($InputObject.Keys)) {
            $result[[string]$key] = ConvertTo-HashtableDeep $InputObject[$key]
        }
        return $result
    }

    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $result = @{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $result[$prop.Name] = ConvertTo-HashtableDeep $prop.Value
        }
        return $result
    }

    if (($InputObject -is [System.Collections.IEnumerable]) -and ($InputObject -isnot [string])) {
        $items = @()
        foreach ($item in $InputObject) { $items += , (ConvertTo-HashtableDeep $item) }
        return , $items
    }

    return $InputObject
}

function Initialize-AuditLog {
    [CmdletBinding()]
    param()

    if ($LogPath) {
        $dir = Split-Path -Path $LogPath -Parent
        $script:LogFile = $LogPath
    }
    else {
        if ($script:OnWindows) { $root = $env:LOCALAPPDATA } else { $root = Join-Path $HOME '.local/state' }
        $dir = Join-Path $root 'opencode-setup'
        $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
        $script:LogFile = Join-Path $dir "setup-$stamp.jsonl"
    }

    # A trilha de auditoria e gravada inclusive em simulacao: sem ela perde-se
    # o registro de quem executou o que e quando.
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false -Confirm:$false | Out-Null
    }
}

function Write-AuditLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')][string]$Level,
        [Parameter(Mandatory = $true)][string]$EventName,
        [string]$Message = '',
        [hashtable]$Data = @{}
    )

    $entry = [ordered]@{
        timestamp = [DateTime]::UtcNow.ToString('o')
        level     = $Level
        event     = $EventName
        message   = $Message
        actor     = [Environment]::UserName
        host      = [Environment]::MachineName
        pid       = $PID
        version   = $script:ScriptVersion
        data      = $Data
    }

    if ($script:LogFile) {
        try {
            Add-Utf8Line -Path $script:LogFile -Line ($entry | ConvertTo-Json -Depth 6 -Compress)
        }
        catch {
            Write-Warning "Falha ao gravar log de auditoria: $($_.Exception.Message)"
        }
    }

    switch ($Level) {
        'ERROR' { $color = 'Red' }
        'WARN' { $color = 'Yellow' }
        'DEBUG' { $color = 'DarkGray' }
        default { $color = 'Cyan' }
    }
    if ($Message) { $display = $Message } else { $display = $EventName }

    if ($Level -ne 'DEBUG' -or $VerbosePreference -ne 'SilentlyContinue') {
        Write-Host ("[{0}] {1}" -f $Level, $display) -ForegroundColor $color
    }
}

function Add-Finding {
    param([Parameter(Mandatory = $true)][string]$Text)
    $script:Findings.Add($Text)
}

function Test-Approved {
    <#
    .SYNOPSIS
        Porta de entrada para toda operacao mutante.
    .DESCRIPTION
        Nao usa $PSCmdlet.ShouldProcess de proposito: quando o conteudo e
        executado via 'iex', o script roda no escopo global e $PSCmdlet pode
        nao existir, o que quebraria toda a cadeia sob StrictMode.
        $WhatIfPreference funciona nos dois modos.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Action
    )

    if ($WhatIfPreference) {
        Write-Host ("What if: {0} -> {1}" -f $Action, $Target) -ForegroundColor DarkYellow
        return $false
    }
    return $true
}

function Test-IsElevated {
    if (-not $script:OnWindows) { return $false }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-CommandAvailable {
    param([Parameter(Mandatory = $true)][string]$Name)
    return [bool](Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue)
}

function Format-NativeOutput {
    <#
    .SYNOPSIS
        Limpa a saida de um processo externo para uso em mensagem de erro.
    .DESCRIPTION
        Barras de progresso (ollama pull, winget) usam retorno de carro e
        sequencias ANSI para reescrever a linha. Repassadas cruas para o
        console, elas sobrescrevem a propria mensagem de erro e o usuario ve
        so o resto da barra - foi exatamente assim que uma falha de pull
        apareceu como 'pulling manifest' e nada mais.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([object[]]$Lines, [int]$Last = 8)

    if (-not $Lines) { return '' }

    $esc = [char]27
    $texto = (@($Lines) | ForEach-Object { "$_" }) -join "`n"
    $texto = $texto -replace "$esc\[[0-9;?]*[a-zA-Z]", ''   # sequencias ANSI
    $texto = $texto -replace "`r", "`n"                      # retorno de carro

    $limpas = @($texto -split "`n" | ForEach-Object { $_.TrimEnd() } | Where-Object { $_ })
    return (@($limpas | Select-Object -Last $Last) -join [Environment]::NewLine)
}

function Invoke-Native {
    <#
    .SYNOPSIS
        Executa processo externo com array de argumentos.
    .DESCRIPTION
        Array em vez de concatenacao de string: fecha a porta para injecao de
        argumento (CWE-88) caso algum valor escape da validacao.

        -Stream deixa a saida ir direto para o console (download de modelo com
        varios GB precisa mostrar progresso) e avalia apenas o codigo de saida.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [switch]$IgnoreExitCode,
        [switch]$Stream
    )

    Write-AuditLog -Level DEBUG -EventName 'process.exec' -Data @{ file = $FilePath; args = ($Arguments -join ' ') }

    $global:LASTEXITCODE = 0
    $output = @()

    # ErrorActionPreference volta para 'Continue' durante a chamada nativa.
    # Com 'Stop', a PRIMEIRA linha que o processo escreve em stderr vira
    # ErrorRecord terminante e aborta o script - mesmo com o processo indo
    # bem. O 'ollama pull' escreve o progresso em stderr, entao o download
    # morria na linha 'pulling manifest'. Codigo de saida e o unico sinal
    # confiavel de falha em processo externo.
    $prefAnterior = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Stream) {
            & $FilePath @Arguments
        }
        else {
            $output = @(& $FilePath @Arguments 2>&1)
        }
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prefAnterior
    }

    if (-not $IgnoreExitCode -and $code -ne 0) {
        Write-AuditLog -Level ERROR -EventName 'process.failed' -Data @{ file = $FilePath; exitCode = $code }
        $detalhe = Format-NativeOutput -Lines $output
        $mensagem = "Comando '$FilePath $($Arguments -join ' ')' falhou (exit=$code)."
        if ($detalhe) { $mensagem = $mensagem + [Environment]::NewLine + $detalhe }
        throw $mensagem
    }

    return New-Object psobject -Property @{ ExitCode = $code; Output = $output }
}

function Update-SessionPath {
    if (-not $script:OnWindows) { return }
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $extra = Join-Path $env:LOCALAPPDATA 'Programs\Ollama'
    $env:Path = (@($machine, $user, $extra) | Where-Object { $_ }) -join ';'
}

# ===========================================================================
# SECAO 3 - Pre-condicoes
# ===========================================================================
function Assert-ParameterSanity {
    <#
    .SYNOPSIS
        Valida os parametros. Substitui os atributos do bloco param(), que
        nao podem ser usados aqui por causa do modo de execucao remota.
    .DESCRIPTION
        Estas checagens nao sao cosmeticas: o nome do modelo termina em linha
        de comando e dentro de um Modelfile, e o endpoint vira a baseURL
        gravada na configuracao do agente.
    #>
    [CmdletBinding()]
    param()

    if ($Model -and $Model -notmatch $script:ModelTagPattern) {
        throw "Nome de modelo invalido: '$Model'. Use o formato do Ollama, por exemplo 'qwen2.5-coder:7b'. Caracteres fora de [a-z0-9._-/:] sao recusados porque o valor e usado em linha de comando e em Modelfile."
    }

    if ($ContextLength -ne 0 -and ($ContextLength -lt 16384 -or $ContextLength -gt 1048576)) {
        throw "ContextLength invalido: $ContextLength. Informe um valor entre 16384 e 1048576, ou omita para dimensionamento automatico."
    }

    if ($ConfigScope -ne 'User' -and $ConfigScope -ne 'Project') {
        throw "ConfigScope invalido: '$ConfigScope'. Use 'User' ou 'Project'."
    }

    if ($PermissionProfile -ne 'Strict' -and $PermissionProfile -ne 'Standard') {
        throw "PermissionProfile invalido: '$PermissionProfile'. Use 'Strict' ou 'Standard'."
    }

    if ([string]::IsNullOrWhiteSpace($ProjectPath)) {
        throw 'ProjectPath nao pode ser vazio.'
    }

    if ($OllamaEndpoint -notmatch $script:EndpointPattern) {
        throw @"
Endpoint invalido ou fora de loopback: '$OllamaEndpoint'.
A API do Ollama nao tem autenticacao. Apontar o endpoint para um endereco
alcancavel pela rede expoe inferencia irrestrita e o conteudo dos prompts.
Formatos aceitos: 127.0.0.1:PORTA, localhost:PORTA, [::1]:PORTA.
"@
    }
}

function Assert-Preconditions {
    [CmdletBinding()]
    param()

    Write-AuditLog -Level INFO -EventName 'precheck.start' -Message 'Verificando pre-condicoes'

    if ($PSVersionTable.PSVersion.Major -lt 6) {
        Add-Finding 'Windows PowerShell 5.1 detectado. Funciona, mas considere o PowerShell 7+: winget install --exact --id Microsoft.PowerShell'
    }

    if (-not $script:OnWindows) {
        Add-Finding 'Executando fora do Windows: instalacao via winget e hardening de ACL serao ignorados.'
        Write-AuditLog -Level WARN -EventName 'precheck.platform' -Message 'Plataforma nao-Windows detectada'
    }

    if ((Test-IsElevated) -and -not $AllowElevated) {
        throw @'
Execucao em contexto ADMINISTRATIVO detectada e bloqueada (least privilege).
O Ollama e o OpenCode rodam no contexto do usuario. Executar este script como
administrador faria o daemon e o agente herdarem privilegio elevado, ampliando
o impacto de qualquer execucao de codigo dirigida pelo modelo.
Reabra o terminal como usuario padrao. Havendo justificativa, use -AllowElevated.
'@
    }

    $envHost = [Environment]::GetEnvironmentVariable('OLLAMA_HOST')
    if ($envHost -and $envHost -notmatch '^(https?://)?(127\.0\.0\.1|localhost|\[::1\])(:\d+)?/?$') {
        throw @"
OLLAMA_HOST esta definido como '$envHost'.
A API do Ollama nao implementa autenticacao nem autorizacao. Qualquer bind fora
de loopback expoe inferencia irrestrita e o conteudo dos prompts - que inclui
seu codigo-fonte - a toda a rede alcancavel. Remova a variavel ou aponte-a
para 127.0.0.1 antes de prosseguir.
"@
    }

    Write-AuditLog -Level DEBUG -EventName 'precheck.ok' -Data @{
        psVersion = $PSVersionTable.PSVersion.ToString()
        psEdition = "$($PSVersionTable.PSEdition)"
        elevated  = (Test-IsElevated)
    }
}

# ===========================================================================
# SECAO 4 - Escolha de modelo e contexto
# ===========================================================================
function Resolve-Provisioning {
    <#
    .SYNOPSIS
        Define modelo e contexto a partir do hardware, respeitando o que o
        usuario informou explicitamente.
    #>
    [CmdletBinding()]
    param()

    if ($NoAutoDetect) {
        if ($script:AutoModel) { $script:Model = $script:FallbackModel }
        if ($script:AutoContext) { $script:ContextLength = $script:FallbackContext }
        Write-AuditLog -Level INFO -EventName 'sizing.disabled' -Message 'Autodeteccao desativada por -NoAutoDetect'
        return $null
    }

    Write-AuditLog -Level INFO -EventName 'sizing.start' -Message 'Detectando hardware para dimensionar modelo e contexto'

    try {
        $inventory = Get-HostInventory -ApiRoot $script:ApiRoot
        $plan = Get-SizingPlan -Inventory $inventory
    }
    catch {
        # Fail secure: sem inventario confiavel, perfil conservador em vez de
        # assumir um modelo que pode nao caber na maquina.
        Add-Finding "Deteccao de hardware falhou ($($_.Exception.Message)). Aplicado o perfil conservador."
        Write-AuditLog -Level WARN -EventName 'sizing.failed' -Message 'Falha na deteccao; usando fallback'
        if ($script:AutoModel) { $script:Model = $script:FallbackModel }
        if ($script:AutoContext) { $script:ContextLength = $script:FallbackContext }
        return $null
    }

    Write-SizingPlanReport -Inventory $inventory -Plan $plan

    if (-not $plan.Best) {
        Add-Finding 'Nenhum modelo do catalogo cabe nesta maquina. Aplicado o perfil conservador; espere desempenho ruim ou considere inferencia remota.'
        if ($script:AutoModel) { $script:Model = $script:FallbackModel }
        if ($script:AutoContext) { $script:ContextLength = $script:FallbackContext }
        Write-AuditLog -Level WARN -EventName 'sizing.nofit' -Data @{
            budgetGB = $plan.Budget.BudgetGB; mode = $plan.Budget.Mode
        }
        return @{ Inventory = $inventory; Plan = $plan }
    }

    if ($script:AutoModel) { $script:Model = [string]$plan.Best.Modelo }

    if ($script:AutoContext) {
        # O contexto do plano vale para o modelo eleito. Se o usuario fixou
        # outro modelo, redimensiona o contexto para ESSE modelo.
        $target = @(Get-OllamaModelCatalog | Where-Object { $_.Tag -eq $script:Model })
        if ($target.Count -eq 1) {
            $fitted = Get-FittedContext -BudgetGB $plan.Budget.BudgetGB -Candidate $target[0] -Mode $plan.Budget.Mode
            if ($fitted -gt 0) {
                $script:ContextLength = $fitted
            }
            else {
                $script:ContextLength = $script:FallbackContext
                Add-Finding "O modelo '$($script:Model)' nao cabe no orcamento de $($plan.Budget.BudgetGB) GB. Contexto reduzido para $($script:FallbackContext); espere offload para RAM e queda de desempenho."
            }
        }
        else {
            $script:ContextLength = $script:FallbackContext
            Add-Finding "Modelo '$($script:Model)' fora do catalogo: contexto fixado em $($script:FallbackContext). Informe -ContextLength se souber o limite do seu hardware."
        }
    }

    Write-AuditLog -Level INFO -EventName 'sizing.resolved' -Data @{
        model = $script:Model; contextLength = $script:ContextLength
        autoModel = $script:AutoModel; autoContext = $script:AutoContext
        budgetGB = $plan.Budget.BudgetGB; mode = $plan.Budget.Mode
    }

    return @{ Inventory = $inventory; Plan = $plan }
}

# ===========================================================================
# SECAO 5 - Instalacao das dependencias
# ===========================================================================
function Install-WingetPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PackageId,
        [Parameter(Mandatory = $true)][string]$DisplayName
    )

    if (-not (Test-CommandAvailable 'winget')) { return $false }
    if (-not (Test-Approved -Target $DisplayName -Action "Instalar via winget ($PackageId)")) { return $true }

    Write-AuditLog -Level INFO -EventName 'install.begin' -Message "Instalando $DisplayName via winget"

    # --exact + --id impede resolucao ambigua de nome (typosquatting no
    # catalogo). --scope user mantem a instalacao sem privilegio de admin.
    $result = Invoke-Native -FilePath 'winget' -IgnoreExitCode -Arguments @(
        'install', '--exact', '--id', $PackageId,
        '--source', 'winget',
        '--scope', 'user',
        '--accept-package-agreements', '--accept-source-agreements',
        '--disable-interactivity'
    )

    # 0 = ok; -1978335189 = ja instalado / nada a atualizar.
    if ($result.ExitCode -ne 0 -and $result.ExitCode -ne -1978335189) {
        Write-AuditLog -Level WARN -EventName 'install.winget.failed' -Data @{ packageId = $PackageId; exitCode = $result.ExitCode }
        return $false
    }

    Update-SessionPath
    return $true
}

function Install-Dependencies {
    [CmdletBinding()]
    param()

    if ($SkipInstall) {
        Write-AuditLog -Level INFO -EventName 'install.skipped' -Message 'Instalacao ignorada por -SkipInstall'
        return
    }

    if (Test-CommandAvailable 'ollama') {
        Write-AuditLog -Level INFO -EventName 'install.ollama.present' -Message 'Ollama ja instalado'
    }
    else {
        if (-not (Install-WingetPackage -PackageId $script:Constants.OllamaWingetId -DisplayName 'Ollama')) {
            throw @"
Nao foi possivel instalar o Ollama automaticamente (winget indisponivel ou falhou).
Instale a partir da origem oficial https://ollama.com/download, validando a
assinatura Authenticode do instalador, e reexecute com -SkipInstall.
"@
        }
        Update-SessionPath
        if (-not (Test-CommandAvailable 'ollama') -and -not $WhatIfPreference) {
            throw 'Ollama instalado, mas ausente do PATH. Feche e reabra o terminal e reexecute com -SkipInstall.'
        }
    }

    if (Test-CommandAvailable 'opencode') {
        Write-AuditLog -Level INFO -EventName 'install.opencode.present' -Message 'OpenCode ja instalado'
        return
    }

    $installed = Install-WingetPackage -PackageId $script:Constants.OpencodeWingetId -DisplayName 'OpenCode'

    if (-not $installed -and (Test-CommandAvailable 'npm')) {
        if (Test-Approved -Target 'OpenCode' -Action "Instalar via npm ($($script:Constants.OpencodeNpmId))") {
            Write-AuditLog -Level INFO -EventName 'install.opencode.npm' -Message 'Fallback para npm'
            # --ignore-scripts bloqueia lifecycle scripts arbitrarios de
            # dependencias transitivas durante a instalacao (supply chain).
            Invoke-Native -FilePath 'npm' -Arguments @(
                'install', '--global', '--ignore-scripts', $script:Constants.OpencodeNpmId
            ) | Out-Null
            $installed = $true
            Update-SessionPath
        }
    }

    if (-not $installed -and -not $WhatIfPreference) {
        throw 'Nao foi possivel instalar o OpenCode (winget e npm indisponiveis). Instale manualmente e reexecute com -SkipInstall.'
    }
}

# ===========================================================================
# SECAO 6 - Runtime e modelo
# ===========================================================================
function Test-OllamaHealth {
    [CmdletBinding()]
    param([int]$TimeoutSec = 5)
    try {
        $null = Invoke-RestMethod -Uri "$($script:ApiRoot)/api/version" -TimeoutSec $TimeoutSec -Method Get
        return $true
    }
    catch { return $false }
}

function Start-OllamaRuntime {
    [CmdletBinding()]
    param()

    if (Test-OllamaHealth -TimeoutSec $script:Constants.HealthTimeoutSec) {
        Write-AuditLog -Level INFO -EventName 'runtime.healthy' -Message "Daemon Ollama respondendo em $($script:ApiRoot)"
        return
    }

    if (-not (Test-Approved -Target 'ollama serve' -Action 'Iniciar daemon local')) { return }

    Write-AuditLog -Level INFO -EventName 'runtime.starting' -Message 'Iniciando daemon Ollama'

    $env:OLLAMA_HOST = $OllamaEndpoint
    Start-Process -FilePath 'ollama' -ArgumentList 'serve' -WindowStyle Hidden | Out-Null

    $deadline = [DateTime]::UtcNow.AddSeconds($script:Constants.StartupWaitSec)
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 2
        if (Test-OllamaHealth -TimeoutSec 3) {
            Write-AuditLog -Level INFO -EventName 'runtime.ready' -Message 'Daemon Ollama pronto'
            return
        }
    }

    throw "Daemon Ollama nao respondeu em $($script:Constants.StartupWaitSec)s em $($script:ApiRoot). Verifique se a porta esta ocupada por outro processo."
}

function Get-DerivedModelName {
    param(
        [Parameter(Mandatory = $true)][string]$BaseModel,
        [Parameter(Mandatory = $true)][int]$Ctx
    )
    return ('{0}-ctx{1}k' -f ($BaseModel -replace '[:/]', '-'), [int]($Ctx / 1024))
}

function Test-ModelPresent {
    param([Parameter(Mandatory = $true)][string]$Name)
    try {
        $tags = Invoke-RestMethod -Uri "$($script:ApiRoot)/api/tags" -TimeoutSec 10 -Method Get
        if (-not ($tags.PSObject.Properties.Name -contains 'models')) { return $false }
        return [bool](@($tags.models | Where-Object { $_.name -eq $Name -or $_.name -eq ($Name + ':latest') }))
    }
    catch { return $false }
}

function Invoke-ModelProvisioning {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$DerivedName)

    if ($SkipModelPull) {
        Write-AuditLog -Level INFO -EventName 'model.skipped' -Message 'Pull ignorado por -SkipModelPull'
        return
    }

    if (Test-ModelPresent -Name $script:Model) {
        Write-AuditLog -Level INFO -EventName 'model.present' -Message "Modelo base '$($script:Model)' ja disponivel"
    }
    elseif (Test-Approved -Target $script:Model -Action 'Baixar modelo (ollama pull)') {
        Write-AuditLog -Level INFO -EventName 'model.pull' -Message "Baixando '$($script:Model)' (varios GB, pode levar minutos)"
        # -Stream: o progresso do download vai direto para o console. Sem isso
        # o usuario fica varios minutos olhando para um cursor parado.
        Invoke-Native -FilePath 'ollama' -Arguments @('pull', $script:Model) -Stream | Out-Null
    }

    if (Test-ModelPresent -Name $DerivedName) {
        Write-AuditLog -Level INFO -EventName 'model.variant.present' -Message "Variante '$DerivedName' ja existe"
        return
    }

    if (-not (Test-Approved -Target $DerivedName -Action "Criar variante com num_ctx=$($script:ContextLength)")) { return }

    $workDir = Join-Path ([System.IO.Path]::GetTempPath()) ('opencode-setup-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        Protect-FileSystemAcl -Path $workDir

        $modelfile = Join-Path $workDir 'Modelfile'
        # $script:Model ja validado por regex - sem interpolacao insegura.
        $content = "FROM $($script:Model)" + [Environment]::NewLine + "PARAMETER num_ctx $($script:ContextLength)" + [Environment]::NewLine
        Write-Utf8File -Path $modelfile -Content $content

        Write-AuditLog -Level INFO -EventName 'model.variant.create' -Data @{ name = $DerivedName; numCtx = $script:ContextLength }
        Invoke-Native -FilePath 'ollama' -Arguments @('create', $DerivedName, '-f', $modelfile) | Out-Null
    }
    finally {
        if (Test-Path -LiteralPath $workDir) {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ===========================================================================
# SECAO 7 - Configuracao do OpenCode
# ===========================================================================
function Protect-FileSystemAcl {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not $script:OnWindows) { return }
    if (-not (Test-Path -LiteralPath $Path)) { return }

    try {
        $acl = Get-Acl -LiteralPath $Path
        $acl.SetAccessRuleProtection($true, $false)   # quebra heranca
        foreach ($rule in @($acl.Access)) { $null = $acl.RemoveAccessRule($rule) }

        $me = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $system = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
        if (Test-Path -LiteralPath $Path -PathType Container) {
            $inherit = 'ContainerInherit, ObjectInherit'
        }
        else {
            $inherit = 'None'
        }

        foreach ($sid in @($me, $system)) {
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                        $sid, 'FullControl', $inherit, 'None', 'Allow')))
        }

        Set-Acl -LiteralPath $Path -AclObject $acl
        Write-AuditLog -Level DEBUG -EventName 'acl.hardened' -Data @{ path = $Path }
    }
    catch {
        Add-Finding "Nao foi possivel endurecer a ACL de '$Path': $($_.Exception.Message)"
        Write-AuditLog -Level WARN -EventName 'acl.failed' -Data @{ path = $Path }
    }
}

function Get-ConfigPath {
    if ($ConfigScope -eq 'Project') {
        return (Join-Path (Resolve-Path -LiteralPath $ProjectPath -ErrorAction Stop).Path 'opencode.json')
    }
    if ($script:OnWindows) { $userHome = $env:USERPROFILE } else { $userHome = $HOME }
    return (Join-Path $userHome '.config/opencode/opencode.json')
}

function Get-PermissionBlock {
    if ($PermissionProfile -eq 'Strict') {
        return [ordered]@{ bash = 'ask'; edit = 'ask'; webfetch = 'deny' }
    }
    return [ordered]@{ bash = 'ask'; edit = 'allow'; webfetch = 'ask' }
}

function Write-OpencodeConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$DerivedName)

    $configPath = Get-ConfigPath
    $configDir = Split-Path -Path $configPath -Parent

    $config = @{}
    if (Test-Path -LiteralPath $configPath) {
        try {
            $raw = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $config = ConvertTo-HashtableDeep ($raw | ConvertFrom-Json)
            }
        }
        catch {
            throw "Config existente em '$configPath' e JSON invalido. Corrija ou remova o arquivo: $($_.Exception.Message)"
        }

        if (Test-Approved -Target $configPath -Action 'Criar backup') {
            $backup = "$configPath.$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')).bak"
            Copy-Item -LiteralPath $configPath -Destination $backup -Force
            Protect-FileSystemAcl -Path $backup
            Write-AuditLog -Level INFO -EventName 'config.backup' -Data @{ path = $backup }
        }
    }

    $providerBlock = [ordered]@{
        npm     = $script:Constants.NpmProvider
        name    = 'Ollama (local)'
        options = [ordered]@{ baseURL = $script:BaseUrl }
        models  = [ordered]@{
            $DerivedName = [ordered]@{
                name    = "$($script:Model) (num_ctx $([int]($script:ContextLength/1024))k)"
                tools   = $true
                options = [ordered]@{ num_ctx = $script:ContextLength }
                limit   = [ordered]@{ context = $script:ContextLength; output = 8192 }
            }
        }
    }

    if (-not $config.ContainsKey('provider')) { $config['provider'] = @{} }
    $existingProviders = $config['provider']

    # Preserva outros modelos ja declarados para o mesmo provider.
    if ($existingProviders.ContainsKey($script:Constants.ProviderKey)) {
        $current = $existingProviders[$script:Constants.ProviderKey]
        if ($current -is [hashtable] -and $current.ContainsKey('models') -and $current['models'] -is [hashtable]) {
            foreach ($key in $current['models'].Keys) {
                if (-not $providerBlock['models'].Contains($key)) {
                    $providerBlock['models'][$key] = $current['models'][$key]
                }
            }
        }
    }

    $existingProviders[$script:Constants.ProviderKey] = $providerBlock
    $config['$schema'] = $script:Constants.ConfigSchema
    $config['model'] = "$($script:Constants.ProviderKey)/$DerivedName"

    if ($config.ContainsKey('permission')) {
        Add-Finding "Bloco 'permission' preexistente substituido pelo perfil '$PermissionProfile'. O backup preserva o valor anterior."
    }
    $config['permission'] = Get-PermissionBlock

    if (-not (Test-Approved -Target $configPath -Action 'Gravar configuracao do OpenCode')) { return $configPath }

    if (-not (Test-Path -LiteralPath $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        Protect-FileSystemAcl -Path $configDir
    }

    Write-Utf8File -Path $configPath -Content ($config | ConvertTo-Json -Depth 24)
    Protect-FileSystemAcl -Path $configPath

    Write-AuditLog -Level INFO -EventName 'config.written' -Message "Configuracao gravada em $configPath"
    return $configPath
}

# ===========================================================================
# SECAO 8 - Validacao
# ===========================================================================
function Test-Integration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DerivedName,
        [Parameter(Mandatory = $true)][string]$ConfigPath
    )

    $checks = New-Object System.Collections.Generic.List[object]

    function Add-Check {
        param([string]$Name, [bool]$Ok, [string]$Detail = '')
        if ($Ok) { $status = 'OK' } else { $status = 'FALHA' }
        $checks.Add((New-Object psobject -Property ([ordered]@{
                        Verificacao = $Name; Resultado = $status; Detalhe = $Detail
                    })))
    }

    $modelsOk = $false
    $detail = ''
    try {
        $resp = Invoke-RestMethod -Uri "$($script:BaseUrl)/models" -TimeoutSec 10 -Method Get
        $ids = @($resp.data | ForEach-Object { $_.id })
        $modelsOk = ($ids -contains $DerivedName) -or ($ids -contains ($DerivedName + ':latest'))
        $detail = "$($ids.Count) modelo(s) expostos"
    }
    catch { $detail = $_.Exception.Message }
    Add-Check -Name "Endpoint /v1/models expoe '$DerivedName'" -Ok $modelsOk -Detail $detail

    $cfgOk = $false
    $detail = ''
    try {
        $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $cfgOk = ($cfg.model -eq "$($script:Constants.ProviderKey)/$DerivedName")
        $detail = "model = $($cfg.model)"
    }
    catch { $detail = $_.Exception.Message }
    Add-Check -Name 'opencode.json valido e apontando para o provider local' -Ok $cfgOk -Detail $detail

    Add-Check -Name 'CLI opencode disponivel no PATH' -Ok (Test-CommandAvailable 'opencode')

    $bindOk = $true
    $detail = 'loopback'
    if ($script:OnWindows -and (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
        try {
            $port = [int](($OllamaEndpoint -split ':')[-1])
            $exposed = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue |
                Where-Object { $_.LocalAddress -ne '127.0.0.1' -and $_.LocalAddress -ne '::1' }
            if ($exposed) {
                $bindOk = $false
                $detail = 'escutando em ' + ((@($exposed) | ForEach-Object { $_.LocalAddress } | Sort-Object -Unique) -join ', ')
                Add-Finding "CRITICO: a porta $port escuta fora de loopback. A API do Ollama nao tem autenticacao."
            }
        }
        catch { $detail = 'nao verificavel' }
    }
    Add-Check -Name 'Daemon restrito a loopback' -Ok $bindOk -Detail $detail

    return $checks
}

# ===========================================================================
# SECAO 9 - Orquestracao
# ===========================================================================
function Confirm-Execution {
    <#
    .SYNOPSIS
        Confirmacao antes da primeira operacao que altera a maquina.
    .DESCRIPTION
        Existe por causa do modo remoto: quem roda 'irm ... | iex' nao leu o
        codigo. Mostrar o que sera feito e pedir confirmacao e o minimo.
        Em sessao nao interativa (CI, tarefa agendada) segue sem perguntar,
        pois nao haveria ninguem para responder.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if ($Force -or $WhatIfPreference -or $ShowPlanOnly) { return $true }
    if (-not [Environment]::UserInteractive) { return $true }
    if ($env:CI) { return $true }

    Write-Host ''
    Write-Host 'Isto vai alterar sua maquina:' -ForegroundColor Yellow
    if (-not $SkipInstall) { Write-Host '  - instalar Ollama e OpenCode (winget/npm, escopo de usuario)' }
    if (-not $SkipModelPull) { Write-Host ("  - baixar o modelo {0}" -f $script:Model) }
    Write-Host ("  - gravar {0} (com backup do arquivo atual)" -f (Get-ConfigPath))
    Write-Host ''

    $answer = Read-Host 'Continuar? [s/N]'
    return ($answer -match '^[sSyY]')
}

function Invoke-Main {
    Initialize-AuditLog

    Write-Host ''
    Write-Host "ollama-opencode-config v$($script:ScriptVersion)" -ForegroundColor Cyan
    Write-Host ''

    Write-AuditLog -Level INFO -EventName 'run.start' -Message 'Iniciando provisionamento Ollama + OpenCode' -Data @{
        scope = $ConfigScope; permissionProfile = $PermissionProfile
        endpoint = $OllamaEndpoint; whatIf = [bool]$WhatIfPreference
        showPlanOnly = [bool]$ShowPlanOnly; psVersion = $PSVersionTable.PSVersion.ToString()
    }

    Assert-ParameterSanity
    Assert-Preconditions
    $null = Resolve-Provisioning

    Write-Host ''
    Write-Host '=== Configuracao escolhida ===' -ForegroundColor Green
    if ($script:AutoModel) { $origemModelo = 'autodetectado' } else { $origemModelo = 'informado por -Model' }
    if ($script:AutoContext) { $origemCtx = 'autodimensionado' } else { $origemCtx = 'informado por -ContextLength' }
    Write-Host ("  Modelo...: {0}  ({1})" -f $script:Model, $origemModelo)
    Write-Host ("  num_ctx..: {0}  ({1})" -f $script:ContextLength, $origemCtx)

    if ($ShowPlanOnly) {
        Write-Host ''
        Write-Host 'Modo -ShowPlanOnly: nada foi instalado ou alterado.' -ForegroundColor Yellow
        Write-Host 'Para aplicar:' -ForegroundColor Cyan
        Write-Host ("  .\install.ps1 -Model '{0}' -ContextLength {1}" -f $script:Model, $script:ContextLength)
        Write-SecurityFindings
        return
    }

    if (-not (Confirm-Execution)) {
        Write-Host 'Cancelado pelo usuario. Nada foi alterado.' -ForegroundColor Yellow
        Write-AuditLog -Level INFO -EventName 'run.cancelled' -Message 'Cancelado na confirmacao'
        return
    }

    Install-Dependencies

    $derived = Get-DerivedModelName -BaseModel $script:Model -Ctx $script:ContextLength

    Start-OllamaRuntime
    Invoke-ModelProvisioning -DerivedName $derived
    $configPath = Write-OpencodeConfiguration -DerivedName $derived

    if ($WhatIfPreference) {
        Write-Host ''
        Write-Host '[WhatIf] Simulacao concluida. Nenhuma alteracao foi aplicada.' -ForegroundColor Yellow
        return
    }

    Write-Host ''
    Write-Host '=== Validacao da integracao ===' -ForegroundColor Green
    $results = Test-Integration -DerivedName $derived -ConfigPath $configPath
    foreach ($r in $results) {
        if ($r.Resultado -eq 'OK') { $cor = 'Green' } else { $cor = 'Red' }
        Write-Host ('  [{0,-5}] {1} {2}' -f $r.Resultado, $r.Verificacao, $(if ($r.Detalhe) { "($($r.Detalhe))" } else { '' })) -ForegroundColor $cor
    }

    $failed = @($results | Where-Object { $_.Resultado -eq 'FALHA' })

    Write-Host ''
    Write-Host '=== Resumo ===' -ForegroundColor Green
    Write-Host "  Config....: $configPath"
    Write-Host "  Provider..: $($script:Constants.ProviderKey) -> $($script:BaseUrl)"
    Write-Host "  Modelo....: $($script:Constants.ProviderKey)/$derived (num_ctx $($script:ContextLength))"
    Write-Host "  Permissoes: $PermissionProfile"
    Write-Host "  Log.......: $($script:LogFile)"

    Write-SecurityFindings

    Write-AuditLog -Level INFO -EventName 'run.end' -Message 'Provisionamento concluido' -Data @{
        failedChecks = $failed.Count; findings = $script:Findings.Count
    }

    if ($failed.Count -gt 0) {
        # Fail secure: sinaliza falha em vez de reportar sucesso parcial.
        throw "$($failed.Count) verificacao(oes) de integracao falharam. Consulte a lista acima e o log em $($script:LogFile)."
    }

    Write-Host ''
    Write-Host "Pronto. Execute 'opencode' no diretorio do projeto e use /models para confirmar o provider." -ForegroundColor Green
}

function Write-SecurityFindings {
    if ($script:Findings.Count -eq 0) { return }
    Write-Host ''
    Write-Host '=== Observacoes de seguranca ===' -ForegroundColor Yellow
    foreach ($f in $script:Findings) { Write-Host "  - $f" -ForegroundColor Yellow }
}

# ===========================================================================
# Ponto de entrada
#
# Quando o arquivo e carregado com ponto (. .\install.ps1), InvocationName e
# '.': os testes obtem todas as funcoes sem disparar o provisionamento.
# Executado normalmente, via iex ou via scriptblock, o fluxo roda.
#
# Nao ha 'exit': em modo iex o script roda no escopo global e 'exit' fecharia
# a sessao do usuario. Erros viram registro + $LASTEXITCODE.
# ===========================================================================
if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-Main
        $global:LASTEXITCODE = 0
    }
    catch {
        Write-Host ''
        Write-Host "[ERRO] $($_.Exception.Message)" -ForegroundColor Red
        if ($script:LogFile) {
            Write-AuditLog -Level ERROR -EventName 'run.failed' -Message $_.Exception.Message -Data @{
                exceptionType = $_.Exception.GetType().FullName
            }
            Write-Host "Log de auditoria: $($script:LogFile)" -ForegroundColor DarkGray
        }
        $global:LASTEXITCODE = 1
    }
    finally {
        # Devolve as preferencias: em modo iex estamos no escopo global do
        # usuario e nao podemos deixar ErrorActionPreference='Stop' para tras.
        $ErrorActionPreference = $script:PrefErrorAction
        $ProgressPreference = $script:PrefProgress
    }
}

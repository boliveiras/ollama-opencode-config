#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Testes do dimensionamento.

    O install.ps1 e carregado com ponto: quando InvocationName e '.', ele
    expoe as funcoes sem executar o provisionamento. E o que permite testar
    o arquivo unico sem separar em modulo.

    As funcoes de calculo sao puras: recebem inventarios sinteticos e nao
    tocam o hardware, entao da para testar 24 GB de VRAM num runner que nao
    tem GPU nenhuma.

    Encoding: ASCII puro, sem BOM, CRLF.
#>

BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'install.ps1')

    function New-TestInventory {
        param(
            [double]$VramGB = 0,
            [double]$RamGB = 32,
            [double]$FreeDiskGB = 500,
            [string]$GpuName = 'GPU de teste'
        )
        $gpu = @()
        if ($VramGB -gt 0) {
            $gpu = @([pscustomobject]@{ Name = $GpuName; DedicatedGB = $VramGB; Source = 'test' })
        }
        return @{
            CollectedUtc = '2026-01-01T00:00:00.0000000Z'
            PsVersion    = '5.1.0.0'
            IsWindows    = $true
            Cpu          = @{ Name = 'CPU de teste'; PhysicalCores = 8; LogicalCores = 16; MaxClockMHz = 3000 }
            Memory       = @{ TotalGB = $RamGB; AvailableGB = [math]::Round($RamGB / 2, 1) }
            Gpu          = $gpu
            Disk         = @{ Volume = 'C:\'; FreeGB = $FreeDiskGB }
            Ollama       = @{ Installed = $false; Version = $null; Reachable = $false; Models = @() }
        }
    }
}

Describe 'Carregamento com ponto' {
    It 'expoe as funcoes sem executar o provisionamento' {
        Get-Command Get-SizingPlan -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Invoke-Main -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'nao criou configuracao alguma so por ser carregado' {
        # Se o guard de InvocationName quebrasse, o dot-source teria rodado o
        # provisionamento inteiro durante os testes.
        $script:Findings.Count | Should -Be 0
    }
}

Describe 'Catalogo de modelos' {
    It 'nao esta vazio' {
        @(Get-OllamaModelCatalog).Count | Should -BeGreaterThan 0
    }

    It 'tem todos os campos obrigatorios preenchidos' {
        foreach ($m in Get-OllamaModelCatalog) {
            $m.Tag | Should -Not -BeNullOrEmpty
            $m.WeightsGB | Should -BeGreaterThan 0
            $m.KvPer1k | Should -BeGreaterThan 0
            $m.MaxCtx | Should -BeGreaterThan 0
        }
    }

    It 'usa apenas tags aceitas pela validacao do parametro -Model' {
        $pattern = '^[a-z0-9]([a-z0-9._-]*[a-z0-9])?(/[a-z0-9]([a-z0-9._-]*[a-z0-9])?)?(:[A-Za-z0-9._-]+)?$'
        foreach ($m in Get-OllamaModelCatalog) {
            $m.Tag | Should -Match $pattern
        }
    }

    It 'nao tem Rank duplicado, senao a escolha do melhor seria ambigua' {
        $ranks = @(Get-OllamaModelCatalog | ForEach-Object { $_.Rank })
        ($ranks | Sort-Object -Unique).Count | Should -Be $ranks.Count
    }
}

Describe 'Orcamento de memoria' {
    It 'usa a VRAM quando ha GPU dedicada suficiente' {
        $b = Get-InferenceBudget -Inventory (New-TestInventory -VramGB 12 -RamGB 64)
        $b.Mode | Should -Be 'GPU'
        $b.BudgetGB | Should -Be 10.2
    }

    It 'cai para RAM quando a GPU e integrada' {
        $b = Get-InferenceBudget -Inventory (New-TestInventory -VramGB 0.5 -RamGB 32)
        $b.Mode | Should -Be 'CPU'
        $b.BudgetGB | Should -Be 16
    }

    It 'cai para RAM quando nao ha GPU alguma' {
        $b = Get-InferenceBudget -Inventory (New-TestInventory -VramGB 0 -RamGB 16)
        $b.Mode | Should -Be 'CPU'
        $b.BudgetGB | Should -Be 8
    }

    It 'escolhe a GPU de maior VRAM em notebook hibrido' {
        $inv = New-TestInventory -VramGB 8
        $inv.Gpu += [pscustomobject]@{ Name = 'dGPU'; DedicatedGB = 16.0; Source = 'test' }
        (Get-InferenceBudget -Inventory $inv).VramGB | Should -Be 16
    }
}

Describe 'Ajuste da janela de contexto' {
    BeforeAll {
        $script:Big = [pscustomobject]@{ Tag = 'x:30b'; WeightsGB = 18.6; KvPer1k = 0.105; MaxCtx = 262144 }
        $script:Small = [pscustomobject]@{ Tag = 'x:7b'; WeightsGB = 4.7; KvPer1k = 0.035; MaxCtx = 131072 }
    }

    It 'devolve 0 quando os pesos nao cabem' {
        Get-FittedContext -BudgetGB 8 -Candidate $script:Big | Should -Be 0
    }

    It 'devolve 0 quando so sobra memoria para um contexto inutilizavel' {
        Get-FittedContext -BudgetGB 4.75 -Candidate $script:Small | Should -Be 0
    }

    It 'nunca passa do MaxCtx do modelo' {
        Get-FittedContext -BudgetGB 999 -Candidate $script:Small | Should -Be 131072
    }

    It 'alinha o resultado em blocos de 8k' {
        (Get-FittedContext -BudgetGB 8 -Candidate $script:Small) % 8192 | Should -Be 0
    }

    It 'aplica o teto de contexto no modo CPU' {
        $gpuCtx = Get-FittedContext -BudgetGB 40 -Candidate $script:Small -Mode 'GPU'
        $cpuCtx = Get-FittedContext -BudgetGB 40 -Candidate $script:Small -Mode 'CPU'
        $gpuCtx | Should -BeGreaterThan $cpuCtx
        $cpuCtx | Should -Be (Get-SizingConstant).CpuModeCtxCap
    }

    It 'cresce de forma monotonica com o orcamento' {
        $anterior = -1
        foreach ($budget in 5, 6, 8, 10, 12, 16) {
            $ctx = Get-FittedContext -BudgetGB $budget -Candidate $script:Small
            $ctx | Should -BeGreaterOrEqual $anterior
            $anterior = $ctx
        }
    }
}

Describe 'Plano de dimensionamento' {
    It 'nunca recomenda um modelo que nao cabe' {
        foreach ($vram in 6, 8, 12, 16, 24, 48) {
            $plan = Get-SizingPlan -Inventory (New-TestInventory -VramGB $vram)
            if ($plan.Best) {
                $c = @(Get-OllamaModelCatalog | Where-Object { $_.Tag -eq $plan.Best.Modelo })[0]
                ($c.WeightsGB + ($c.KvPer1k * ($plan.Best.NumCtx / 1024))) | Should -BeLessOrEqual $plan.Budget.BudgetGB
            }
        }
    }

    It 'escolhe modelos maiores conforme a VRAM aumenta' {
        $p8 = Get-SizingPlan -Inventory (New-TestInventory -VramGB 8)
        $p24 = Get-SizingPlan -Inventory (New-TestInventory -VramGB 24)
        $r8 = @(Get-OllamaModelCatalog | Where-Object { $_.Tag -eq $p8.Best.Modelo })[0].Rank
        $r24 = @(Get-OllamaModelCatalog | Where-Object { $_.Tag -eq $p24.Best.Modelo })[0].Rank
        $r24 | Should -BeGreaterThan $r8
    }

    It 'sempre recomenda contexto igual ou acima do minimo utilizavel' {
        $min = (Get-SizingConstant).MinUsableCtx
        foreach ($vram in 8, 12, 16, 24) {
            (Get-SizingPlan -Inventory (New-TestInventory -VramGB $vram)).Best.NumCtx |
                Should -BeGreaterOrEqual $min
        }
    }

    It 'marca SemDisco quando falta espaco para os pesos' {
        $plan = Get-SizingPlan -Inventory (New-TestInventory -VramGB 24 -FreeDiskGB 5)
        $grandes = @($plan.Table | Where-Object { $_.PesosGB -gt 5 -and $_.NumCtx -gt 0 })
        $grandes.Count | Should -BeGreaterThan 0
        foreach ($row in $grandes) { $row.Status | Should -Be 'SemDisco' }
    }

    It 'nao elege nada em maquina sem memoria suficiente, sem estourar' {
        # Regressao: indexar array vazio sob StrictMode lancava excecao aqui.
        $plan = Get-SizingPlan -Inventory (New-TestInventory -VramGB 0 -RamGB 2)
        $plan.Best | Should -BeNullOrEmpty
    }

    It 'avalia o catalogo inteiro, sem truncar em silencio' {
        @((Get-SizingPlan -Inventory (New-TestInventory -VramGB 12)).Table).Count |
            Should -Be @(Get-OllamaModelCatalog).Count
    }

    It 'e deterministico para o mesmo inventario' {
        $inv = New-TestInventory -VramGB 16
        $a = Get-SizingPlan -Inventory $inv
        $b = Get-SizingPlan -Inventory $inv
        $a.Best.Modelo | Should -Be $b.Best.Modelo
        $a.Best.NumCtx | Should -Be $b.Best.NumCtx
    }
}

Describe 'Coleta de hardware' {
    It 'devolve um inventario com todas as secoes' {
        $inv = Get-HostInventory
        foreach ($chave in 'Cpu', 'Memory', 'Gpu', 'Disk', 'Ollama') {
            $inv.ContainsKey($chave) | Should -BeTrue
        }
    }

    It 'nao lanca excecao em maquina sem GPU nem Ollama' {
        { Get-HostInventory } | Should -Not -Throw
    }

    It 'produz um plano utilizavel a partir do hardware real do runner' {
        $plan = Get-SizingPlan -Inventory (Get-HostInventory)
        @($plan.Table).Count | Should -BeGreaterThan 0
    }
}

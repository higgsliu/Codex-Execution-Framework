[CmdletBinding()]
param(
    [Parameter()]
    [string]$ProjectRoot = (Get-Location).Path,

    [Parameter()]
    [ValidateSet('Shell', 'Primary', 'LunaReader')]
    [string]$Mode = 'Shell',

    [Parameter()]
    [int]$Iterations = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path -LiteralPath $ProjectRoot).Path

if ($Iterations -le 0) {
    $Iterations = if ($Mode -eq 'Shell') { 5 } else { 1 }
}

function Get-Median {
    param([double[]]$Values)

    if ($Values.Count -eq 0) { return 0 }
    $sorted = @($Values | Sort-Object)
    $middle = [math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2 -eq 1) {
        return [double]$sorted[$middle]
    }
    return ([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2
}

function Invoke-Timed {
    param([scriptblock]$Action)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $Action
    $sw.Stop()
    return $sw.Elapsed.TotalMilliseconds
}

function Assert-GitRepo {
    $null = & git -C $root rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "ProjectRoot is not inside a Git repository: $root"
    }
}

function Invoke-CodexProbe {
    param([string]$Prompt)

    if ($null -eq (Get-Command codex -ErrorAction SilentlyContinue)) {
        throw 'codex command not found'
    }

    $oldLocation = Get-Location
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Set-Location -LiteralPath $root
        $lines = (& codex exec --json $Prompt 2>&1) | ForEach-Object { $_.ToString() }
        $exitCode = $LASTEXITCODE
    } finally {
        $sw.Stop()
        Set-Location $oldLocation
    }

    $usage = $null
    foreach ($line in $lines) {
        try {
            $event = $line | ConvertFrom-Json -ErrorAction Stop
            if ($event.type -eq 'turn.completed' -and $null -ne $event.usage) {
                $usage = $event.usage
            }
        } catch {
            # Ignore non-JSON stderr or informational lines.
        }
    }

    $joined = $lines -join "`n"
    $ok = ($exitCode -eq 0 -and $joined -match 'BENCHMARK_OK')

    return [pscustomobject]@{
        Success = $ok
        ExitCode = $exitCode
        WallMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
        InputTokens = if ($null -ne $usage -and $null -ne $usage.input_tokens) { $usage.input_tokens } else { $null }
        CachedInputTokens = if ($null -ne $usage -and $null -ne $usage.cached_input_tokens) { $usage.cached_input_tokens } else { $null }
        OutputTokens = if ($null -ne $usage -and $null -ne $usage.output_tokens) { $usage.output_tokens } else { $null }
        ReasoningTokens = if ($null -ne $usage -and $null -ne $usage.reasoning_output_tokens) { $usage.reasoning_output_tokens } else { $null }
    }
}

if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'git command not found'
}

Assert-GitRepo

Write-Host "PROJECT_ROOT=$root"
Write-Host "MODE=$Mode"
Write-Host "ITERATIONS=$Iterations"
Write-Host ''

if ($Mode -eq 'Shell') {
    $checks = @(
        [pscustomobject]@{
            Name = 'git status --short'
            Action = { $null = & git -C $root status --short }
        },
        [pscustomobject]@{
            Name = 'git diff --stat'
            Action = { $null = & git -C $root diff --stat }
        },
        [pscustomobject]@{
            Name = 'git ls-files (first 50)'
            Action = { $null = @(& git -C $root ls-files | Select-Object -First 50) }
        }
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($check in $checks) {
        $samples = [System.Collections.Generic.List[double]]::new()
        for ($i = 1; $i -le $Iterations; $i++) {
            $ms = Invoke-Timed $check.Action
            $samples.Add($ms)
        }

        $rows.Add([pscustomobject]@{
            Check = $check.Name
            MedianMs = [math]::Round((Get-Median $samples.ToArray()), 1)
            MinMs = [math]::Round(($samples | Measure-Object -Minimum).Minimum, 1)
            MaxMs = [math]::Round(($samples | Measure-Object -Maximum).Maximum, 1)
        })
    }

    $rows | Format-Table -AutoSize
    Write-Host ''
    Write-Host 'NOTE=Shell mode measures local command baseline only and consumes no model tokens.'
    exit 0
}

if ($Mode -eq 'Primary') {
    $prompt = @'
Benchmark task. Do not spawn subagents.
Run exactly these read-only repository checks: `git status --short`, `git diff --stat`, and `git ls-files` while inspecting at most the first 20 file paths.
Do not modify files. Do not perform extra repository exploration.
Return exactly BENCHMARK_OK when the checks finish.
'@
} else {
    $prompt = @'
Benchmark task. Use exactly one project custom agent named luna_reader.
Ask the subagent to run exactly these read-only repository checks: `git status --short`, `git diff --stat`, and `git ls-files` while inspecting at most the first 20 file paths.
The subagent must not modify files and must not spawn another agent.
After it returns, reply with exactly BENCHMARK_OK.
'@
}

Write-Host 'WARNING=This mode calls Codex and consumes model tokens.' -ForegroundColor Yellow

$probeRows = [System.Collections.Generic.List[object]]::new()
for ($i = 1; $i -le $Iterations; $i++) {
    $result = Invoke-CodexProbe -Prompt $prompt
    $probeRows.Add([pscustomobject]@{
        Run = $i
        Success = $result.Success
        WallMs = $result.WallMs
        InputTokens = $result.InputTokens
        CachedInputTokens = $result.CachedInputTokens
        OutputTokens = $result.OutputTokens
        ReasoningTokens = $result.ReasoningTokens
        ExitCode = $result.ExitCode
    })
}

$probeRows | Format-Table -AutoSize

$successful = @($probeRows | Where-Object { $_.Success })
Write-Host ''
if ($successful.Count -gt 0) {
    $medianWall = Get-Median ([double[]]@($successful | ForEach-Object { [double]$_.WallMs }))
    Write-Host ('MEDIAN_WALL_MS=' + [math]::Round($medianWall, 1))
}

if ($successful.Count -eq $probeRows.Count) {
    Write-Host 'BENCHMARK_STATUS=PASS' -ForegroundColor Green
    exit 0
}

Write-Host 'BENCHMARK_STATUS=PARTIAL_OR_FAIL' -ForegroundColor Red
exit 1

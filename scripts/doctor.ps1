[CmdletBinding()]
param(
    [Parameter()]
    [string]$ProjectRoot = (Get-Location).Path,

    [Parameter()]
    [switch]$LiveProbe
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$results = [System.Collections.Generic.List[object]]::new()

function Add-Check {
    param(
        [string]$Name,
        [bool]$Pass,
        [string]$Detail,
        [bool]$Critical = $true
    )

    $results.Add([pscustomobject]@{
        Check    = $Name
        Status   = if ($Pass) { 'PASS' } else { 'FAIL' }
        Critical = $Critical
        Detail   = $Detail
    })
}

function Test-Regex {
    param(
        [string]$Text,
        [string]$Pattern
    )
    return [regex]::IsMatch($Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
}

try {
    $resolvedRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
    Add-Check 'PROJECT_ROOT' $true $resolvedRoot
} catch {
    Add-Check 'PROJECT_ROOT' $false "Project root not found: $ProjectRoot"
    $results | Format-Table -AutoSize
    Write-Host ''
    Write-Host 'READY=NO'
    exit 1
}

$git = Get-Command git -ErrorAction SilentlyContinue
if ($null -ne $git) {
    $gitVersion = (& git --version 2>$null) -join ' '
    Add-Check 'GIT' ($LASTEXITCODE -eq 0) $gitVersion
} else {
    Add-Check 'GIT' $false 'git command not found'
}

$codex = Get-Command codex -ErrorAction SilentlyContinue
if ($null -ne $codex) {
    $codexVersion = (& codex --version 2>$null) -join ' '
    Add-Check 'CODEX' ($LASTEXITCODE -eq 0) $codexVersion
} else {
    Add-Check 'CODEX' $false 'codex command not found'
}

if ($null -ne $git) {
    $repoRootOutput = (& git -C $resolvedRoot rev-parse --show-toplevel 2>$null) -join ''
    $repoPass = ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($repoRootOutput))
    $repoDetail = if ($repoPass) { $repoRootOutput } else { 'ProjectRoot is not inside a Git repository' }
    Add-Check 'GIT_REPOSITORY' $repoPass $repoDetail
}

$configPath = Join-Path $resolvedRoot '.codex/config.toml'
if (Test-Path -LiteralPath $configPath) {
    $config = Get-Content -LiteralPath $configPath -Raw
    Add-Check 'CONFIG_FILE' $true $configPath

    Add-Check 'PRIMARY_NOT_PINNED' (-not (Test-Regex $config '(?m)^\s*model\s*=')) 'Top-level model should remain unset in project config'
    Add-Check 'AGENTS_ENABLED' (Test-Regex $config '(?m)^\s*enabled\s*=\s*true\s*$') 'agents.enabled = true'
    Add-Check 'WORKER_LIMIT' (Test-Regex $config '(?m)^\s*max_concurrent_threads_per_session\s*=\s*6\s*$') 'max_concurrent_threads_per_session = 6'
    Add-Check 'WORKER_MODEL' (Test-Regex $config '(?m)^\s*default_subagent_model\s*=\s*"gpt-5\.6-luna"\s*$') 'default_subagent_model = gpt-5.6-luna'
    Add-Check 'WORKER_REASONING' (Test-Regex $config '(?m)^\s*default_subagent_reasoning_effort\s*=\s*"max"\s*$') 'default_subagent_reasoning_effort = max'
    Add-Check 'SHELL_SNAPSHOT' (Test-Regex $config '(?m)^\s*shell_snapshot\s*=\s*true\s*$') 'shell_snapshot = true'
} else {
    Add-Check 'CONFIG_FILE' $false "Missing: $configPath"
}

$agentChecks = @(
    @{
        Name = 'LUNA_READER'
        Path = '.codex/agents/luna-reader.toml'
        ExpectedName = 'luna_reader'
        Sandbox = 'read-only'
    },
    @{
        Name = 'LUNA_WRITER'
        Path = '.codex/agents/luna-writer.toml'
        ExpectedName = 'luna_writer'
        Sandbox = 'workspace-write'
    }
)

foreach ($agentCheck in $agentChecks) {
    $agentPath = Join-Path $resolvedRoot $agentCheck.Path
    if (-not (Test-Path -LiteralPath $agentPath)) {
        Add-Check $agentCheck.Name $false "Missing: $agentPath"
        continue
    }

    $agentText = Get-Content -LiteralPath $agentPath -Raw
    $namePattern = '(?m)^\s*name\s*=\s*"' + [regex]::Escape($agentCheck.ExpectedName) + '"\s*$'
    $sandboxPattern = '(?m)^\s*sandbox_mode\s*=\s*"' + [regex]::Escape($agentCheck.Sandbox) + '"\s*$'

    $ok = $true
    $ok = $ok -and (Test-Regex $agentText $namePattern)
    $ok = $ok -and (Test-Regex $agentText '(?m)^\s*model\s*=\s*"gpt-5\.6-luna"\s*$')
    $ok = $ok -and (Test-Regex $agentText '(?m)^\s*model_reasoning_effort\s*=\s*"max"\s*$')
    $ok = $ok -and (Test-Regex $agentText $sandboxPattern)
    Add-Check $agentCheck.Name $ok "$($agentCheck.ExpectedName), sandbox=$($agentCheck.Sandbox)"
}

$agentsInstructions = Join-Path $resolvedRoot 'AGENTS.md'
$agentsExists = Test-Path -LiteralPath $agentsInstructions
$agentsDetail = if ($agentsExists) { $agentsInstructions } else { 'AGENTS.md missing' }
Add-Check 'AGENTS_MD' $agentsExists $agentsDetail

if ($LiveProbe) {
    if ($null -eq $codex) {
        Add-Check 'LIVE_WORKER_PROBE' $false 'Skipped because codex command is unavailable'
    } else {
        Write-Host ''
        Write-Host 'Running live Luna worker probe. This consumes model tokens...' -ForegroundColor Yellow

        $oldLocation = Get-Location
        try {
            Set-Location -LiteralPath $resolvedRoot
            $probePrompt = @'
Use exactly one project custom agent named luna_reader.
Ask that subagent to perform only a read-only repository check using `git status --short` and then return the marker WORKER_PROBE_OK.
Do not modify files. Do not spawn any additional subagents.
After the subagent returns, reply with exactly WORKER_PROBE_OK.
'@
            $probeOutput = (& codex exec --json $probePrompt 2>&1) | ForEach-Object { $_.ToString() }
            $exitCode = $LASTEXITCODE
            $joined = $probeOutput -join "`n"
            $markerFound = $joined -match 'WORKER_PROBE_OK'
            Add-Check 'LIVE_WORKER_PROBE' ($exitCode -eq 0 -and $markerFound) "exit=$exitCode marker=$markerFound"
        } catch {
            Add-Check 'LIVE_WORKER_PROBE' $false $_.Exception.Message
        } finally {
            Set-Location $oldLocation
        }
    }
} else {
    Add-Check 'LIVE_WORKER_PROBE' $true 'Not requested. Use -LiveProbe for a real spawn test; it consumes tokens.' $false
}

Write-Host ''
$results | Format-Table -AutoSize

$criticalFailures = @($results | Where-Object { $_.Critical -and $_.Status -eq 'FAIL' })
Write-Host ''
if ($criticalFailures.Count -eq 0) {
    Write-Host 'READY=YES' -ForegroundColor Green
    exit 0
}

Write-Host 'READY=NO' -ForegroundColor Red
Write-Host ('FAILED_CHECKS=' + (($criticalFailures.Check) -join ','))
exit 1

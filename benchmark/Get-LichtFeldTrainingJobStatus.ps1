[CmdletBinding()]
param(
    [string]$JobId,

    [string]$JobsRoot,

    [switch]$Latest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-TrainingFailureReason {
    param(
        [string]$TrainLogPath,
        [string]$StdErrPath
    )

    $parts = @()
    foreach ($path in @($TrainLogPath, $StdErrPath)) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            $parts += [System.IO.File]::ReadAllText($path)
        }
    }

    if ($parts.Count -eq 0) {
        return $null
    }

    $combined = ($parts -join "`n")
    if ($combined -match 'Training error:\s*(?<reason>.+)') {
        return $Matches['reason'].Trim()
    }
    if ($combined -match 'Insufficient GPU memory for arena initialization') {
        return 'Insufficient GPU memory for training startup.'
    }

    return $null
}

function Find-LatestCheckpoint {
    param([string]$OutputPath)

    return Find-360GSLatestNumberedFile -Directory (Join-Path $OutputPath 'checkpoints') -Prefix 'checkpoint' -Extension '.resume'
}

function Find-LatestSplat {
    param([string]$OutputPath)

    return Find-360GSLatestNumberedFile -Directory $OutputPath -Prefix 'splat' -Extension '.ply'
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'lib\Benchmark.Common.ps1')
$projectRoot = Resolve-360GSProjectRoot -ScriptPath $MyInvocation.MyCommand.Path
if (-not $JobsRoot) {
    $JobsRoot = Resolve-360GSExistingBenchmarkPath -ProjectRoot $projectRoot -ChildPath 'jobs'
}

if (-not (Test-Path -LiteralPath $JobsRoot)) {
    throw "Jobs root not found: $JobsRoot"
}

if ($Latest -or -not $JobId) {
    $jobDir = Get-ChildItem -Path $JobsRoot -Directory | Where-Object { $_.Name -like 'lichtfeld-*' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $jobDir) {
        throw "No LichtFeld jobs found under $JobsRoot"
    }
}
else {
    $jobDir = Get-Item -LiteralPath (Join-Path $JobsRoot $JobId)
}

$jobMetaPath = Join-Path $jobDir.FullName 'job.json'
if (-not (Test-Path -LiteralPath $jobMetaPath)) {
    throw "Job metadata not found: $jobMetaPath"
}

$job = Read-360GSJsonFile -Path $jobMetaPath
$runRoot = [string]$job.run_root
$statePath = Join-Path $runRoot 'train_state.json'
$reportPath = Join-Path $runRoot 'training_report.json'
$outputPath = Join-Path $runRoot 'training_output'
$trainLogPath = Join-Path $runRoot 'logs\train.log'
$stderrPath = [string]$job.stderr_log
$metricsPath = Join-Path $outputPath 'metrics.csv'
$latestCheckpoint = Find-LatestCheckpoint -OutputPath $outputPath
$latestSplat = Find-LatestSplat -OutputPath $outputPath
$failureReason = Get-TrainingFailureReason -TrainLogPath $trainLogPath -StdErrPath $stderrPath
$stderrHasContent = $false
if ($stderrPath -and (Test-Path -LiteralPath $stderrPath)) {
    $stderrHasContent = ((Get-Item -LiteralPath $stderrPath).Length -gt 0)
}

$processRunning = $false
try {
    $proc = Get-Process -Id ([int]$job.process_id) -ErrorAction Stop
    if ($proc) {
        $processRunning = $true
    }
}
catch { }

$state = if (Test-Path -LiteralPath $statePath) { Read-360GSJsonFile -Path $statePath } else { $null }
$report = if (Test-Path -LiteralPath $reportPath) { Read-360GSJsonFile -Path $reportPath } else { $null }
$memoryFallback = if ($state -and $state.PSObject.Properties.Name -contains 'memory_fallback') { $state.memory_fallback } else { $null }

$status = if ($report) {
    'completed'
}
elseif ($processRunning) {
    'running'
}
elseif ($latestCheckpoint) {
    'stopped-needs-resume'
}
elseif ($failureReason -or $stderrHasContent) {
    'failed'
}
elseif ($state) {
    'stopped-needs-resume'
}
else {
    'unknown'
}

$result = [ordered]@{
    status = $status
    job_id = $job.job_id
    process_id = $job.process_id
    process_running = $processRunning
    job_root = $jobDir.FullName
    run_root = $runRoot
    output_path = $outputPath
    state_path = $statePath
    report_path = $reportPath
    train_log = if (Test-Path -LiteralPath $trainLogPath) { $trainLogPath } else { $null }
    metrics_csv = if (Test-Path -LiteralPath $metricsPath) { $metricsPath } else { $null }
    latest_checkpoint = if ($latestCheckpoint) { $latestCheckpoint.path } else { $null }
    latest_checkpoint_iteration = if ($latestCheckpoint) { $latestCheckpoint.iteration } else { $null }
    latest_splat = if ($latestSplat) { $latestSplat.path } else { $null }
    latest_splat_iteration = if ($latestSplat) { $latestSplat.iteration } else { $null }
    completed_stages = if ($state) { @($state.completed_stages) } else { @() }
    error_message = $failureReason
    memory_fallback = $memoryFallback
    memory_fallback_active = if ($memoryFallback) { [bool]$memoryFallback.active } else { $false }
    memory_fallback_used = if ($memoryFallback) { [bool]$memoryFallback.used } else { $false }
    memory_fallback_completed = if ($memoryFallback) { [bool]$memoryFallback.completed_with_fallback } else { $false }
    memory_fallback_tile_mode = if ($memoryFallback) { $memoryFallback.current_tile_mode } else { $null }
    memory_fallback_message = if ($memoryFallback) { [string]$memoryFallback.message } else { $null }
    stdout_log = $job.stdout_log
    stderr_log = $job.stderr_log
}

$result | ConvertTo-Json -Depth 8

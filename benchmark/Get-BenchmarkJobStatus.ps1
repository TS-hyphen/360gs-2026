[CmdletBinding()]
param(
    [string]$JobId,

    [string]$JobsRoot,

    [switch]$Latest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
    $jobDir = Get-ChildItem -Path $JobsRoot -Directory | Where-Object { $_.Name -like 'glomap-*' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $jobDir) {
        throw "No benchmark jobs found under $JobsRoot"
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
$statePath = Join-Path $runRoot 'run_state.json'
$reportPath = Join-Path $runRoot 'benchmark_report.json'

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

$status = if ($report) {
    'completed'
}
elseif ($processRunning) {
    'running'
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
    state_path = $statePath
    report_path = $reportPath
    completed_stages = if ($state) { @($state.completed_stages) } else { @() }
    stdout_log = $job.stdout_log
    stderr_log = $job.stderr_log
}

$result | ConvertTo-Json -Depth 8

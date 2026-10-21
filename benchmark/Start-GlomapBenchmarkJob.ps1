[CmdletBinding()]
param(
    [string]$StagedDatasetPath,

    [string]$DatasetId,

    [string]$InstallRoot,

    [string]$JobsRoot,

    [ValidateSet('sequential', 'vocab_tree')]
    [string]$Matcher = 'sequential',

    [string]$VocabTreePath,

    [switch]$UseGpu,

    [switch]$SingleCamera = $true,

    [int]$SiftMaxImageSize = 2400,

    [int]$RandomSeed = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'lib\Benchmark.Common.ps1')
$projectRoot = Resolve-360GSProjectRoot -ScriptPath $MyInvocation.MyCommand.Path
if (-not $JobsRoot) {
    $JobsRoot = Get-360GSPreferredBenchmarkPath -ProjectRoot $projectRoot -ChildPath 'jobs'
}
if (-not $InstallRoot) {
    $InstallRoot = Get-360GSDefaultInstallRoot
}

Ensure-360GSDirectory -Path $JobsRoot
$jobId = 'glomap-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
$jobRoot = Join-Path $JobsRoot $jobId
$runRoot = Join-Path $jobRoot 'run'
$stdoutPath = Join-Path $jobRoot 'stdout.log'
$stderrPath = Join-Path $jobRoot 'stderr.log'
$jobMetaPath = Join-Path $jobRoot 'job.json'
New-Item -ItemType Directory -Path $jobRoot -Force | Out-Null

$runner = Join-Path $scriptDir 'Run-GlomapBenchmark.ps1'
if (-not (Test-Path -LiteralPath $runner)) {
    throw "Runner script not found: $runner"
}

$powershellExe = Get-360GSPreferredPowerShellExe
if (-not (Test-Path -LiteralPath $powershellExe)) {
    throw "PowerShell executable not found: $powershellExe"
}

$argList = @(
    '-ExecutionPolicy', 'Bypass',
    '-File', $runner,
    '-InstallRoot', $InstallRoot,
    '-RunRoot', $runRoot,
    '-Resume'
)

if ($StagedDatasetPath) {
    $argList += @('-StagedDatasetPath', $StagedDatasetPath)
}
if ($DatasetId) {
    $argList += @('-DatasetId', $DatasetId)
}
if ($Matcher) {
    $argList += @('-Matcher', $Matcher)
}
if ($VocabTreePath) {
    $argList += @('-VocabTreePath', $VocabTreePath)
}
if ($UseGpu) {
    $argList += '-UseGpu'
}
if ($SingleCamera) {
    $argList += '-SingleCamera'
}
$argList += @('-SiftMaxImageSize', [string]$SiftMaxImageSize, '-RandomSeed', [string]$RandomSeed)

$proc = Start-Process -FilePath $powershellExe -ArgumentList $argList -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru -WindowStyle Hidden

$jobMeta = [ordered]@{
    job_id = $jobId
    backend = 'glomap-standalone'
    created_at = (Get-Date).ToString('o')
    process_id = $proc.Id
    process_name = $powershellExe
    runner = $runner
    run_root = $runRoot
    stdout_log = $stdoutPath
    stderr_log = $stderrPath
    staged_dataset_path = $StagedDatasetPath
    dataset_id = $DatasetId
    matcher = $Matcher
    use_gpu = [bool]$UseGpu
    install_root = $InstallRoot
}
Save-360GSJsonFile -Path $jobMetaPath -Value $jobMeta

Write-Host 'Benchmark job started.'
Write-Host "Job id: $jobId"
Write-Host "PID: $($proc.Id)"
Write-Host "Job root: $jobRoot"
Write-Host "Run root: $runRoot"

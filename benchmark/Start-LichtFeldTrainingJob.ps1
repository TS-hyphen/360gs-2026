[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$StagedDatasetPath,

    [Parameter(Mandatory = $true)]
    [string]$SparseModelPath,

    [string]$InstallRoot,

    [string]$JobsRoot,

    [string]$ImagesFolderName = 'images',

    [ValidateSet('junction', 'copy')]
    [string]$ImagesMode = 'junction',

    [ValidateSet('mcmc', 'adc')]
    [string]$Strategy = 'mcmc',

    [int]$Iterations = 1000,

    [string]$ConfigPath,

    [switch]$Eval,

    [switch]$SaveEvalImages,

    [switch]$EnableMip,

    [switch]$Undistort
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
$jobId = 'lichtfeld-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
$jobRoot = Join-Path $JobsRoot $jobId
$runRoot = Join-Path $jobRoot 'run'
$stdoutPath = Join-Path $jobRoot 'stdout.log'
$stderrPath = Join-Path $jobRoot 'stderr.log'
$jobMetaPath = Join-Path $jobRoot 'job.json'
New-Item -ItemType Directory -Path $jobRoot -Force | Out-Null

$runner = Join-Path $scriptDir 'Run-LichtFeldTraining.ps1'
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
    '-StagedDatasetPath', $StagedDatasetPath,
    '-SparseModelPath', $SparseModelPath,
    '-ImagesFolderName', $ImagesFolderName,
    '-ImagesMode', $ImagesMode,
    '-Strategy', $Strategy,
    '-Iterations', [string]$Iterations,
    '-Resume'
)
if ($ConfigPath) {
    $argList += @('-ConfigPath', $ConfigPath)
}
if ($Eval) {
    $argList += '-Eval'
}
if ($SaveEvalImages) {
    $argList += '-SaveEvalImages'
}
if ($EnableMip) {
    $argList += '-EnableMip'
}
if ($Undistort) {
    $argList += '-Undistort'
}

$proc = Start-Process -FilePath $powershellExe -ArgumentList $argList -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru -WindowStyle Hidden

$jobMeta = [ordered]@{
    job_id = $jobId
    backend = 'lichtfeld-studio'
    created_at = (Get-Date).ToString('o')
    process_id = $proc.Id
    process_name = $powershellExe
    runner = $runner
    run_root = $runRoot
    stdout_log = $stdoutPath
    stderr_log = $stderrPath
    staged_dataset_path = $StagedDatasetPath
    sparse_model_path = $SparseModelPath
    images_folder_name = $ImagesFolderName
    images_mode = $ImagesMode
    strategy = $Strategy
    iterations = $Iterations
    install_root = $InstallRoot
}
Save-360GSJsonFile -Path $jobMetaPath -Value $jobMeta

Write-Host 'LichtFeld training job started.'
Write-Host "Job id: $jobId"
Write-Host "PID: $($proc.Id)"
Write-Host "Job root: $jobRoot"
Write-Host "Run root: $runRoot"

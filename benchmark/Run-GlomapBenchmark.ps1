[CmdletBinding()]
param(
    [string]$StagedDatasetPath,

    [string]$DatasetId,

    [string]$RegistryPath,

    [string]$StagedRoot,

    [string]$InstallRoot,

    [string]$OutputRoot,

    [string]$RunRoot,

    [ValidateSet('sequential', 'vocab_tree')]
    [string]$Matcher = 'sequential',

    [string]$VocabTreePath,

    [switch]$UseGpu,

    [switch]$SingleCamera = $true,

    [int]$SiftMaxImageSize = 2400,

    [int]$RandomSeed = 0,

    [switch]$Resume
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'lib\Benchmark.Common.ps1')
$projectRoot = Resolve-360GSProjectRoot -ScriptPath $MyInvocation.MyCommand.Path
if (-not $RegistryPath) {
    $RegistryPath = Resolve-360GSDatasetRegistryPath -ProjectRoot $projectRoot
}
if (-not $StagedRoot) {
    $StagedRoot = Resolve-360GSExistingBenchmarkPath -ProjectRoot $projectRoot -ChildPath 'staged'
}
if (-not $OutputRoot) {
    $OutputRoot = Get-360GSPreferredBenchmarkPath -ProjectRoot $projectRoot -ChildPath 'results'
}
if (-not $InstallRoot) {
    $InstallRoot = Get-360GSDefaultInstallRoot
}

function New-BenchmarkError {
    param([string]$Message)
    throw $Message
}

function Resolve-StagedDatasetPath {
    param(
        [string]$DirectPath,
        [string]$RequestedDatasetId,
        [string]$StageRoot
    )

    if ($DirectPath) {
        return $DirectPath
    }

    if (-not $RequestedDatasetId) {
        New-BenchmarkError 'Provide either -StagedDatasetPath or -DatasetId.'
    }

    if (-not (Test-Path -LiteralPath $StageRoot)) {
        New-BenchmarkError "Staged dataset root not found: $StageRoot"
    }

    $candidates = @(Get-ChildItem -Path $StageRoot -Directory | Where-Object { $_.Name -like "$RequestedDatasetId*" } | Sort-Object LastWriteTime -Descending)
    if ($candidates.Count -eq 0) {
        New-BenchmarkError "No staged dataset found for dataset id '$RequestedDatasetId' under $StageRoot"
    }

    return $candidates[0].FullName
}

function Resolve-ColmapExe {
    param([string]$Root)

    $exe = Join-Path $Root 'packs\colmap-global\bin\colmap.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        New-BenchmarkError "Managed COLMAP executable not found: $exe"
    }

    return $exe
}

function Resolve-GlomapExe {
    param([string]$Root)

    $exe = Join-Path $Root 'packs\glomap-standalone\bin\glomap.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        New-BenchmarkError "Managed GLOMAP executable not found: $exe"
    }

    return $exe
}

$stagedPath = Resolve-StagedDatasetPath -DirectPath $StagedDatasetPath -RequestedDatasetId $DatasetId -StageRoot $StagedRoot
if (-not (Test-Path -LiteralPath $stagedPath)) {
    New-BenchmarkError "Staged dataset path does not exist: $stagedPath"
}

$imagePath = Join-Path $stagedPath 'images'
if (-not (Test-Path -LiteralPath $imagePath)) {
    New-BenchmarkError "Staged dataset does not contain images folder: $imagePath"
}

$stageManifestPath = Join-Path $stagedPath 'stage_manifest.json'
$stageManifest = if (Test-Path -LiteralPath $stageManifestPath) { Read-360GSJsonFile -Path $stageManifestPath } else { $null }
$datasetLabel = if ($stageManifest) { [string]$stageManifest.dataset_id } else { Split-Path -Path $stagedPath -Leaf }

$colmapExe = Resolve-ColmapExe -Root $InstallRoot
$glomapExe = Resolve-GlomapExe -Root $InstallRoot

$runRoot = if ($RunRoot) {
    $RunRoot
}
else {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Join-Path $OutputRoot ("{0}_glomap_{1}" -f $datasetLabel, $timestamp)
}
$dbPath = Join-Path $runRoot 'database.db'
$sparsePath = Join-Path $runRoot 'sparse'
$logsPath = Join-Path $runRoot 'logs'
Ensure-360GSDirectory -Path $runRoot
Ensure-360GSDirectory -Path $sparsePath
Ensure-360GSDirectory -Path $logsPath
$statePath = Join-Path $runRoot 'run_state.json'
$state = Get-360GSOrCreateState -Path $statePath -Backend 'glomap-standalone' -ResolvedRunRoot $runRoot

$useGpuInt = if ($UseGpu) { '1' } else { '0' }
$singleCameraInt = if ($SingleCamera) { '1' } else { '0' }
$stageResults = @()

$featureArgs = @(
    'feature_extractor',
    '--default_random_seed', [string]$RandomSeed,
    '--database_path', $dbPath,
    '--image_path', $imagePath,
    '--ImageReader.single_camera', $singleCameraInt,
    '--FeatureExtraction.use_gpu', $useGpuInt,
    '--SiftExtraction.max_image_size', [string]$SiftMaxImageSize
)
$stageResults += Invoke-360GSStageWithResume -StatePath $statePath -State $state -StageName 'feature_extractor' -ResumeEnabled:$Resume -Action {
    Invoke-360GSLoggedProcess -ExePath $colmapExe -StageName 'feature_extractor' -Arguments $featureArgs -LogPath (Join-Path $logsPath 'feature_extractor.log')
}

switch ($Matcher) {
    'sequential' {
        $matcherArgs = @(
            'sequential_matcher',
            '--default_random_seed', [string]$RandomSeed,
            '--database_path', $dbPath,
            '--FeatureMatching.use_gpu', $useGpuInt
        )
    }
    'vocab_tree' {
        if (-not $VocabTreePath) {
            New-BenchmarkError 'Matcher=vocab_tree requires -VocabTreePath.'
        }
        if (-not (Test-Path -LiteralPath $VocabTreePath)) {
            New-BenchmarkError "Vocab tree file not found: $VocabTreePath"
        }
        $matcherArgs = @(
            'vocab_tree_matcher',
            '--default_random_seed', [string]$RandomSeed,
            '--database_path', $dbPath,
            '--FeatureMatching.use_gpu', $useGpuInt,
            '--VocabTreeMatching.vocab_tree_path', $VocabTreePath
        )
    }
}
$stageResults += Invoke-360GSStageWithResume -StatePath $statePath -State $state -StageName "$Matcher`_matcher" -ResumeEnabled:$Resume -Action {
    Invoke-360GSLoggedProcess -ExePath $colmapExe -StageName "$Matcher`_matcher" -Arguments $matcherArgs -LogPath (Join-Path $logsPath "$Matcher`_matcher.log")
}

$glomapArgs = @(
    'mapper',
    '--database_path', $dbPath,
    '--image_path', $imagePath,
    '--output_path', $sparsePath,
    '--GlobalPositioning.use_gpu', $useGpuInt,
    '--BundleAdjustment.use_gpu', $useGpuInt
)
$stageResults += Invoke-360GSStageWithResume -StatePath $statePath -State $state -StageName 'glomap_mapper' -ResumeEnabled:$Resume -Action {
    Invoke-360GSLoggedProcess -ExePath $glomapExe -StageName 'glomap_mapper' -Arguments $glomapArgs -LogPath (Join-Path $logsPath 'glomap_mapper.log')
}

$report = [ordered]@{
    backend = 'glomap-standalone'
    dataset_id = $datasetLabel
    staged_dataset_path = $stagedPath
    staged_manifest_path = $stageManifestPath
    image_path = $imagePath
    install_root = $InstallRoot
    colmap_executable = $colmapExe
    glomap_executable = $glomapExe
    matcher = $Matcher
    used_gpu = [bool]$UseGpu
    single_camera = [bool]$SingleCamera
    sift_max_image_size = $SiftMaxImageSize
    random_seed = $RandomSeed
    run_root = $runRoot
    database_path = $dbPath
    sparse_output_path = $sparsePath
    sparse_output_entries = @(Get-ChildItem -Path $sparsePath -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    state_path = $statePath
    resumed_run = [bool]$Resume
    stages = $stageResults
    generated_at = (Get-Date).ToString('o')
}

$reportPath = Join-Path $runRoot 'benchmark_report.json'
Save-360GSJsonFile -Path $reportPath -Value $report

Write-Host 'GLOMAP benchmark complete.'
Write-Host "Run root: $runRoot"
Write-Host "Report: $reportPath"

[CmdletBinding()]
param(
    [string]$StagedDatasetPath,

    [string]$DatasetId,

    [string]$RegistryPath,

    [string]$StagedRoot,

    [string]$InstallRoot,

    [string]$OutputRoot,

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

if (-not (Test-Path -LiteralPath $RegistryPath)) {
    New-BenchmarkError "Dataset registry not found: $RegistryPath"
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

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runRoot = Join-Path $OutputRoot ("{0}_colmap-global_{1}" -f $datasetLabel, $timestamp)
$dbPath = Join-Path $runRoot 'database.db'
$sparsePath = Join-Path $runRoot 'sparse'
$logsPath = Join-Path $runRoot 'logs'
Ensure-360GSDirectory -Path $runRoot
Ensure-360GSDirectory -Path $sparsePath
Ensure-360GSDirectory -Path $logsPath

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
$stageResults += Invoke-360GSLoggedProcess -ExePath $colmapExe -StageName 'feature_extractor' -Arguments $featureArgs -LogPath (Join-Path $logsPath 'feature_extractor.log') -FailurePrefix 'COLMAP stage'

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
$stageResults += Invoke-360GSLoggedProcess -ExePath $colmapExe -StageName "$Matcher`_matcher" -Arguments $matcherArgs -LogPath (Join-Path $logsPath "$Matcher`_matcher.log") -FailurePrefix 'COLMAP stage'

$globalArgs = @(
    'global_mapper',
    '--default_random_seed', [string]$RandomSeed,
    '--database_path', $dbPath,
    '--image_path', $imagePath,
    '--output_path', $sparsePath
)
$stageResults += Invoke-360GSLoggedProcess -ExePath $colmapExe -StageName 'global_mapper' -Arguments $globalArgs -LogPath (Join-Path $logsPath 'global_mapper.log') -FailurePrefix 'COLMAP stage'

$modelDirs = @(Get-ChildItem -Path $sparsePath -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
$report = [ordered]@{
    backend = 'colmap-global'
    dataset_id = $datasetLabel
    staged_dataset_path = $stagedPath
    staged_manifest_path = $stageManifestPath
    image_path = $imagePath
    install_root = $InstallRoot
    colmap_executable = $colmapExe
    matcher = $Matcher
    used_gpu = [bool]$UseGpu
    single_camera = [bool]$SingleCamera
    sift_max_image_size = $SiftMaxImageSize
    random_seed = $RandomSeed
    run_root = $runRoot
    database_path = $dbPath
    sparse_output_path = $sparsePath
    sparse_model_directories = $modelDirs
    stages = $stageResults
    generated_at = (Get-Date).ToString('o')
}

$reportPath = Join-Path $runRoot 'benchmark_report.json'
Save-360GSJsonFile -Path $reportPath -Value $report

Write-Host 'COLMAP global benchmark complete.'
Write-Host "Run root: $runRoot"
Write-Host "Report: $reportPath"
Write-Host "Sparse model directories: $($modelDirs.Count)"

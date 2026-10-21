[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DatasetId,

    [string]$DatasetPath,

    [string]$RegistryPath,

    [string]$InstallRoot,

    [string]$OutputRoot,

    [switch]$UseCheckpointCache,

    [switch]$AllowRecursiveImages
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'lib\Benchmark.Common.ps1')
$projectRoot = Resolve-360GSProjectRoot -ScriptPath $MyInvocation.MyCommand.Path
if (-not $RegistryPath) {
    $RegistryPath = Resolve-360GSDatasetRegistryPath -ProjectRoot $projectRoot
}
if (-not $OutputRoot) {
    $OutputRoot = Get-360GSPreferredBenchmarkPath -ProjectRoot $projectRoot -ChildPath 'results'
}
if (-not $InstallRoot) {
    $InstallRoot = Get-360GSDefaultInstallRoot
}

function Read-Registry {
    param([string]$Path)
    return Read-360GSJsonFile -Path $Path
}

function New-RunError {
    param([string]$Message)
    throw $Message
}

function Get-ImageFiles {
    param(
        [string]$Root,
        [switch]$Recursive
    )

    $patterns = @('*.jpg', '*.jpeg', '*.png', '*.webp', '*.bmp')
    $files = @()
    foreach ($pattern in $patterns) {
        if ($Recursive) {
            $files += Get-ChildItem -Path $Root -Recurse -File -Filter $pattern -ErrorAction SilentlyContinue
        } else {
            $files += Get-ChildItem -Path $Root -File -Filter $pattern -ErrorAction SilentlyContinue
        }
    }
    return @($files | Sort-Object FullName -Unique)
}

function New-IsolatedInputFolder {
    param(
        [string]$DatasetRoot,
        [string]$WorkRoot,
        [switch]$Recursive
    )

    $inputDir = Join-Path $WorkRoot 'input'
    Ensure-360GSDirectory -Path $inputDir

    $images = @(Get-ImageFiles -Root $DatasetRoot -Recursive:$Recursive)
    if ($images.Count -eq 0) {
        New-RunError "No supported image files found in dataset root: $DatasetRoot"
    }

    foreach ($img in $images) {
        Copy-Item -Path $img.FullName -Destination (Join-Path $inputDir $img.Name) -Force
    }

    return @{
        InputDir = $inputDir
        ImageCount = $images.Count
        ImageNames = @($images | ForEach-Object { $_.Name })
    }
}

function Invoke-SharpBenchmark {
    param(
        [string]$InstallPath,
        [string]$InputDir,
        [string]$OutputDir,
        [switch]$UseCheckpoint
    )

    $sharp = Join-Path $InstallPath 'runtime\python311\Scripts\sharp.exe'
    if (-not (Test-Path -LiteralPath $sharp)) {
        New-RunError "Managed SHARP CLI not found: $sharp"
    }

    $argList = @('predict', '-i', $InputDir, '-o', $OutputDir)
    if ($UseCheckpoint) {
        $ckpt = Join-Path $env:USERPROFILE '.cache\torch\hub\checkpoints\sharp_2572gikvuh.pt'
        if (Test-Path -LiteralPath $ckpt) {
            $argList += @('-c', $ckpt)
        }
    }

    $start = Get-Date
    $proc = Start-Process -FilePath $sharp -ArgumentList $argList -Wait -PassThru -NoNewWindow
    $end = Get-Date

    if ($proc.ExitCode -ne 0) {
        New-RunError "SHARP benchmark run failed with exit code $($proc.ExitCode)."
    }

    return @{
        started_at = $start.ToString('o')
        completed_at = $end.ToString('o')
        duration_seconds = [Math]::Round(($end - $start).TotalSeconds, 2)
    }
}

if (-not (Test-Path -LiteralPath $RegistryPath)) {
    New-RunError "Dataset registry not found: $RegistryPath"
}

if (-not (Test-Path -LiteralPath $InstallRoot)) {
    New-RunError "Managed install root not found: $InstallRoot"
}

$registry = Read-Registry -Path $RegistryPath
$dataset = $registry.datasets | Where-Object { $_.id -eq $DatasetId } | Select-Object -First 1
if (-not $dataset) {
    New-RunError "Dataset id '$DatasetId' not found in registry."
}

$resolvedDatasetPath = if ($DatasetPath) { $DatasetPath } elseif ($dataset.local_path) { Resolve-360GSRegistryLocalPath -Value ([string]$dataset.local_path) -RegistryPath $RegistryPath } else { '' }
if (-not $resolvedDatasetPath) {
    New-RunError "No dataset path provided for '$DatasetId'. Set local_path in registry or pass -DatasetPath."
}

if (-not (Test-Path -LiteralPath $resolvedDatasetPath)) {
    New-RunError "Dataset path does not exist: $resolvedDatasetPath"
}

Ensure-360GSDirectory -Path $OutputRoot
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$runRoot = Join-Path $OutputRoot ("{0}_{1}" -f $DatasetId, $ts)
Ensure-360GSDirectory -Path $runRoot
$pipelineOut = Join-Path $runRoot 'pipeline_output'
Ensure-360GSDirectory -Path $pipelineOut

$isolated = New-IsolatedInputFolder -DatasetRoot $resolvedDatasetPath -WorkRoot $runRoot -Recursive:$AllowRecursiveImages
$timing = Invoke-SharpBenchmark -InstallPath $InstallRoot -InputDir $isolated.InputDir -OutputDir $pipelineOut -UseCheckpoint:$UseCheckpointCache

$plyFiles = @(Get-ChildItem -Path $pipelineOut -File -Filter '*.ply' -ErrorAction SilentlyContinue)
$report = [ordered]@{
    dataset_id = $dataset.id
    dataset_name = $dataset.name
    dataset_task = $dataset.task
    dataset_path = $resolvedDatasetPath
    input_image_count = $isolated.ImageCount
    input_images = $isolated.ImageNames
    output_root = $runRoot
    output_ply_count = @($plyFiles).Count
    output_ply_files = @($plyFiles | ForEach-Object { $_.Name })
    run = $timing
}

$reportPath = Join-Path $runRoot 'benchmark_report.json'
Save-360GSJsonFile -Path $reportPath -Value $report

Write-Host "Benchmark complete."
Write-Host "Run root: $runRoot"
Write-Host "Input images: $($isolated.ImageCount)"
Write-Host "Output PLY files: $(@($plyFiles).Count)"
Write-Host "Report: $reportPath"

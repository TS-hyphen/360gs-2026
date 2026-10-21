[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$StagedDatasetPath,

    [Parameter(Mandatory = $true)]
    [string]$SparseModelPath,

    [Parameter(Mandatory = $true)]
    [string]$OutputRoot,

    [string]$ImagesFolderName = 'images',

    [ValidateSet('junction', 'copy')]
    [string]$ImagesMode = 'junction',

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'lib\Benchmark.Common.ps1')

function Resolve-SparseModelDir {
    param([string]$Path)

    $candidate = $Path
    if (-not (Test-Path -LiteralPath $candidate)) {
        throw "Sparse model path not found: $candidate"
    }

    if (Test-Path -LiteralPath (Join-Path $candidate 'cameras.bin')) {
        return $candidate
    }

    if (Test-Path -LiteralPath (Join-Path $candidate 'sparse\0\cameras.bin')) {
        return (Join-Path $candidate 'sparse\0')
    }

    if (Test-Path -LiteralPath (Join-Path $candidate '0\cameras.bin')) {
        return (Join-Path $candidate '0')
    }

    throw "Could not resolve sparse model directory from path: $candidate"
}

function New-ImageLinkOrCopy {
    param(
        [string]$SourcePath,
        [string]$TargetPath,
        [string]$Mode
    )

    if ($Mode -eq 'junction') {
        $parent = Split-Path -Parent $TargetPath
        Ensure-360GSDirectory -Path $parent

        cmd.exe /c "mklink /J `"$TargetPath`" `"$SourcePath`"" | Out-Null
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $TargetPath)) {
            return 'junction'
        }
    }

    Ensure-360GSDirectory -Path $TargetPath
    Copy-Item -Path (Join-Path $SourcePath '*') -Destination $TargetPath -Recurse -Force
    return 'copy'
}

$stagedDatasetPath = (Resolve-Path -LiteralPath $StagedDatasetPath).Path
$sparseModelDir = Resolve-SparseModelDir -Path $SparseModelPath
$outputRoot = $OutputRoot

$sourceImagesPath = Join-Path $stagedDatasetPath $ImagesFolderName
if (-not (Test-Path -LiteralPath $sourceImagesPath)) {
    throw "Images folder not found in staged dataset: $sourceImagesPath"
}

if ((Test-Path -LiteralPath $outputRoot) -and -not $Force) {
    $existing = Get-ChildItem -LiteralPath $outputRoot -Force -ErrorAction SilentlyContinue
    if ($existing) {
        throw "Output root already exists and is not empty: $outputRoot. Re-run with -Force to replace it."
    }
}

Ensure-360GSDirectory -Path $outputRoot
$targetImagesPath = Join-Path $outputRoot $ImagesFolderName
$targetSparseDir = Join-Path $outputRoot 'sparse\0'

foreach ($path in @($targetImagesPath, $targetSparseDir)) {
    if (Test-Path -LiteralPath $path) {
        Assert-360GSChildPath -ChildPath $path -ParentPath $outputRoot -Label 'Prepared dataset path'
        Remove-Item -LiteralPath $path -Recurse -Force
    }
}

Ensure-360GSDirectory -Path $targetSparseDir
Copy-Item -Path (Join-Path $sparseModelDir '*') -Destination $targetSparseDir -Force
$effectiveImagesMode = New-ImageLinkOrCopy -SourcePath $sourceImagesPath -TargetPath $targetImagesPath -Mode $ImagesMode

$stageManifestPath = Join-Path $stagedDatasetPath 'stage_manifest.json'
$stageManifest = if (Test-Path -LiteralPath $stageManifestPath) { Read-360GSJsonFile -Path $stageManifestPath } else { $null }

$manifest = [ordered]@{
    prepared_at = (Get-Date).ToString('o')
    staged_dataset_path = $stagedDatasetPath
    sparse_model_source = $sparseModelDir
    output_root = $outputRoot
    images_folder_name = $ImagesFolderName
    requested_images_mode = $ImagesMode
    effective_images_mode = $effectiveImagesMode
    dataset_id = if ($stageManifest) { [string]$stageManifest.dataset_id } else { Split-Path -Path $stagedDatasetPath -Leaf }
    source_image_count = @(Get-ChildItem -Path $sourceImagesPath -File).Count
    sparse_files = @(Get-ChildItem -Path $targetSparseDir -File | Select-Object -ExpandProperty Name)
}
$manifestPath = Join-Path $outputRoot 'prep_manifest.json'
Save-360GSJsonFile -Path $manifestPath -Value $manifest

Write-Host 'LichtFeld dataset prepared.'
Write-Host "Prepared dataset root: $outputRoot"
Write-Host "Images mode: $effectiveImagesMode"
Write-Host "Sparse model source: $sparseModelDir"
Write-Host "Manifest: $manifestPath"

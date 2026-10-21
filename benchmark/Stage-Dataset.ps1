[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DatasetId,

    [string]$RegistryPath,

    [string]$OutputRoot,

    [string]$Variant,

    [int]$MaxImages = 0,

    [int]$Stride = 1,

    [int]$StartIndex = 0
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
    $OutputRoot = Get-360GSPreferredBenchmarkPath -ProjectRoot $projectRoot -ChildPath 'staged'
}

function New-StageError {
    param([string]$Message)
    throw $Message
}

function Read-Registry {
    param([string]$Path)
    Read-360GSJsonFile -Path $Path
}

function Resolve-VariantPath {
    param(
        [string]$DatasetRoot,
        [string]$VariantName
    )

    if (-not $VariantName) {
        return $DatasetRoot
    }

    $candidate = Join-Path $DatasetRoot $VariantName
    if (Test-Path -LiteralPath $candidate) {
        return $candidate
    }

    New-StageError "Variant path not found: $candidate"
}

function Get-StageImageFiles {
    param([string]$Root)

    $patterns = @('*.jpg', '*.jpeg', '*.png', '*.webp', '*.bmp')
    $files = @()
    foreach ($pattern in $patterns) {
        $files += Get-ChildItem -Path $Root -File -Filter $pattern -ErrorAction SilentlyContinue
    }

    return @($files | Sort-Object Name -Unique)
}

if ($Stride -lt 1) {
    New-StageError 'Stride must be >= 1.'
}

if ($StartIndex -lt 0) {
    New-StageError 'StartIndex must be >= 0.'
}

if (-not (Test-Path -LiteralPath $RegistryPath)) {
    New-StageError "Dataset registry not found: $RegistryPath"
}

$registry = Read-Registry -Path $RegistryPath
$dataset = $registry.datasets | Where-Object { $_.id -eq $DatasetId } | Select-Object -First 1
if (-not $dataset) {
    New-StageError "Dataset id '$DatasetId' not found in registry."
}

if (-not $dataset.local_path) {
    New-StageError "Dataset '$DatasetId' does not have a local_path configured."
}

$datasetRoot = Resolve-360GSRegistryLocalPath -Value ([string]$dataset.local_path) -RegistryPath $RegistryPath
if (-not (Test-Path -LiteralPath $datasetRoot)) {
    New-StageError "Dataset path does not exist: $datasetRoot"
}

$resolvedVariant = if ($Variant) { $Variant } elseif ($dataset.recommended_entry) { [string]$dataset.recommended_entry } else { '' }
$sourceRoot = Resolve-VariantPath -DatasetRoot $datasetRoot -VariantName $resolvedVariant
$allImages = @(Get-StageImageFiles -Root $sourceRoot)
if ($allImages.Count -eq 0) {
    New-StageError "No supported image files found in: $sourceRoot"
}

$selected = New-Object System.Collections.Generic.List[object]
for ($i = $StartIndex; $i -lt $allImages.Count; $i += $Stride) {
    $selected.Add($allImages[$i])
    if ($MaxImages -gt 0 -and $selected.Count -ge $MaxImages) {
        break
    }
}

if ($selected.Count -eq 0) {
    New-StageError 'Selection filters produced zero images.'
}

Ensure-360GSDirectory -Path $OutputRoot
$stageName = if ($resolvedVariant) {
    "{0}_{1}_n{2}_s{3}_o{4}" -f $DatasetId, $resolvedVariant, $selected.Count, $Stride, $StartIndex
} else {
    "{0}_root_n{1}_s{2}_o{3}" -f $DatasetId, $selected.Count, $Stride, $StartIndex
}
$stageRoot = Join-Path $OutputRoot $stageName
$imageRoot = Join-Path $stageRoot 'images'
New-Item -ItemType Directory -Path $imageRoot -Force | Out-Null

foreach ($img in $selected) {
    Copy-Item -Path $img.FullName -Destination (Join-Path $imageRoot $img.Name) -Force
}

$manifest = [ordered]@{
    dataset_id = $dataset.id
    dataset_name = $dataset.name
    dataset_task = $dataset.task
    dataset_homepage = $dataset.homepage
    source_dataset_root = $datasetRoot
    source_variant = $resolvedVariant
    source_variant_path = $sourceRoot
    total_source_images = $allImages.Count
    selected_image_count = $selected.Count
    stride = $Stride
    start_index = $StartIndex
    max_images = $MaxImages
    staged_root = $stageRoot
    staged_images_path = $imageRoot
    selected_images = @($selected | ForEach-Object { $_.Name })
    generated_at = (Get-Date).ToString('o')
}

$manifestPath = Join-Path $stageRoot 'stage_manifest.json'
Save-360GSJsonFile -Path $manifestPath -Value $manifest

Write-Host "Dataset staged."
Write-Host "Stage root: $stageRoot"
Write-Host "Source variant: $resolvedVariant"
Write-Host "Selected images: $($selected.Count) / $($allImages.Count)"
Write-Host "Manifest: $manifestPath"

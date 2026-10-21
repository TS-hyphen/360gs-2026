[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [Parameter(Mandatory = $true)]
    [ValidateSet('standard_video', 'video_360_equirect')]
    [string]$SourceKind,

    [ValidateSet('fast-preview', 'medium', 'high')]
    [string]$Quality = 'medium',

    [string]$OutputRoot,

    [double]$ExtractionFps = 1.0,

    [int]$TargetFrames = 0,

    [int]$TargetTimestamps = 0,

    [int]$MaxOutputWidth = 0,

    [string]$VirtualViewMode = '',

    [int]$ViewWidth = 0,

    [int]$ViewHeight = 0,

    [switch]$UseSceneDetectRequested
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'lib\Benchmark.Common.ps1')
$projectRoot = Resolve-360GSProjectRoot -ScriptPath $MyInvocation.MyCommand.Path
if (-not $OutputRoot) {
    $OutputRoot = Get-360GSPreferredBenchmarkPath -ProjectRoot $projectRoot -ChildPath 'staged'
}

function New-MediaStageError {
    param([string]$Message)
    throw $Message
}

function ConvertTo-360GSSlug {
    param([string]$Value)

    $slug = [regex]::Replace($Value.ToLowerInvariant(), '[^a-z0-9]+', '-').Trim('-')
    if (-not $slug) {
        return 'video'
    }
    return $slug
}

function ConvertTo-360GSFraction {
    param([string]$Value)

    if (-not $Value) {
        return 0.0
    }

    if ($Value -match '/') {
        $parts = $Value -split '/', 2
        if ([double]$parts[1] -eq 0) {
            return 0.0
        }
        return [double]$parts[0] / [double]$parts[1]
    }

    return [double]$Value
}

function Get-VideoProbeData {
    param(
        [string]$FfprobeExe,
        [string]$VideoPath
    )

    $probeJson = & $FfprobeExe -v error -show_streams -show_format -print_format json $VideoPath
    if ($LASTEXITCODE -ne 0) {
        New-MediaStageError "ffprobe could not inspect: $VideoPath"
    }

    $probe = $probeJson | ConvertFrom-Json
    $stream = @($probe.streams | Where-Object { $_.codec_type -eq 'video' }) | Select-Object -First 1
    if (-not $stream) {
        New-MediaStageError "No video stream was found in: $VideoPath"
    }

    $rotation = 0
    if ($stream.tags -and $stream.tags.PSObject.Properties.Name -contains 'rotate' -and $stream.tags.rotate) {
        $rotation = [int]$stream.tags.rotate
    }

    return [ordered]@{
        width = [int]($stream.width | ForEach-Object { $_ })
        height = [int]($stream.height | ForEach-Object { $_ })
        codec_name = [string]$stream.codec_name
        format_name = [string]$probe.format.format_name
        duration_seconds = [double]$probe.format.duration
        source_fps = ConvertTo-360GSFraction -Value ([string]$stream.avg_frame_rate)
        bit_rate = [string]$probe.format.bit_rate
        rotation = $rotation
    }
}

function Test-PySceneDetectAvailability {
    param([string]$ProjectRoot)

    try {
        $pythonExe = Get-360GSPythonExe -ProjectRoot $ProjectRoot
        $output = & $pythonExe -c "import importlib.util; print('yes' if importlib.util.find_spec('scenedetect') else 'no')"
        if ($LASTEXITCODE -ne 0) {
            return $false
        }
        return ($output -join '').Trim() -eq 'yes'
    }
    catch {
        return $false
    }
}

$sourceItem = Get-Item -LiteralPath $SourcePath -ErrorAction Stop
if ($sourceItem.PSIsContainer) {
    New-MediaStageError 'Prepare-MediaDataset expects a single video file path.'
}

$ffmpegExe = Get-360GSFFmpegExe -ProjectRoot $projectRoot
$ffprobeExe = Get-360GSFFprobeExe -ProjectRoot $projectRoot
$resolvedSource = Get-360GSFullPath -Path $sourceItem.FullName
$probe = Get-VideoProbeData -FfprobeExe $ffprobeExe -VideoPath $resolvedSource

if ($ExtractionFps -le 0) {
    New-MediaStageError 'ExtractionFps must be > 0.'
}

Ensure-360GSDirectory -Path $OutputRoot
$stageName = "adhoc-{0}-{1}" -f (ConvertTo-360GSSlug -Value $sourceItem.BaseName), (Get-Date -Format 'yyyyMMdd-HHmmss')
$stageRoot = Join-Path $OutputRoot $stageName
$imageRoot = Join-Path $stageRoot 'images'
New-Item -ItemType Directory -Path $imageRoot -Force | Out-Null

$ffmpegPlan = @()

if ($SourceKind -eq 'standard_video') {
    if ($MaxOutputWidth -le 0) {
        $MaxOutputWidth = [Math]::Max(640, [int]$probe.width)
    }
    $filter = "fps=$([string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:0.###}', $ExtractionFps)),scale=${MaxOutputWidth}:-2:force_original_aspect_ratio=decrease,mpdecimate"
    $outputPattern = Join-Path $imageRoot 'frame_t%06d.jpg'
    $arguments = @(
        '-y',
        '-hide_banner',
        '-loglevel', 'error',
        '-i', $resolvedSource,
        '-vf', $filter,
        '-vsync', 'vfr',
        '-qscale:v', '2',
        $outputPattern
    )
    $null = & $ffmpegExe @arguments
    if ($LASTEXITCODE -ne 0) {
        New-MediaStageError "FFmpeg extraction failed for: $resolvedSource"
    }
    $ffmpegPlan += [ordered]@{
        output = $outputPattern
        filter = $filter
    }
}
elseif ($SourceKind -eq 'video_360_equirect') {
    if ($ViewWidth -le 0 -or $ViewHeight -le 0) {
        New-MediaStageError 'ViewWidth and ViewHeight are required for 360 video extraction.'
    }
    $views = @(
        @{ name = 'front'; yaw = 0 },
        @{ name = 'right'; yaw = 90 },
        @{ name = 'back'; yaw = 180 },
        @{ name = 'left'; yaw = -90 }
    )
    foreach ($view in $views) {
        $filter = "fps=$([string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:0.###}', $ExtractionFps)),v360=input=equirect:output=flat:yaw=$($view.yaw):pitch=0:h_fov=100:v_fov=75:w=${ViewWidth}:h=${ViewHeight}:interp=lanczos"
        $outputPattern = Join-Path $imageRoot ("{0}_t%06d.jpg" -f $view.name)
        $arguments = @(
            '-y',
            '-hide_banner',
            '-loglevel', 'error',
            '-i', $resolvedSource,
            '-vf', $filter,
            '-vsync', 'vfr',
            '-qscale:v', '2',
            $outputPattern
        )
        $null = & $ffmpegExe @arguments
        if ($LASTEXITCODE -ne 0) {
            New-MediaStageError "FFmpeg 360 extraction failed for view '$($view.name)' from: $resolvedSource"
        }
        $ffmpegPlan += [ordered]@{
            view = $view.name
            yaw = $view.yaw
            output = $outputPattern
            filter = $filter
        }
    }
}

$selectedImages = @(Get-ChildItem -Path $imageRoot -File -Filter '*.jpg' | Sort-Object Name)
if ($selectedImages.Count -eq 0) {
    New-MediaStageError 'Media preparation produced zero images.'
}

$pyscenedetectAvailable = $false
$pyscenedetectUsed = $false
if ($UseSceneDetectRequested) {
    $pyscenedetectAvailable = Test-PySceneDetectAvailability -ProjectRoot $projectRoot
}

$manifest = [ordered]@{
    dataset_id = "adhoc-{0}" -f (ConvertTo-360GSSlug -Value $sourceItem.BaseName)
    dataset_name = $sourceItem.BaseName
    dataset_task = 'custom-video'
    dataset_homepage = ''
    source_dataset_root = Split-Path -Parent $resolvedSource
    source_variant = ''
    source_variant_path = $resolvedSource
    total_source_images = 0
    selected_image_count = $selectedImages.Count
    stride = 1
    start_index = 0
    max_images = 0
    staged_root = $stageRoot
    staged_images_path = $imageRoot
    selected_images = @($selectedImages | ForEach-Object { $_.Name })
    generated_at = (Get-Date).ToString('o')
    quality_mode = $Quality
    source_kind = $SourceKind
    source_files = @($resolvedSource)
    media_analysis = [ordered]@{
        duration_seconds = $probe.duration_seconds
        source_fps = $probe.source_fps
        width = $probe.width
        height = $probe.height
        codec_name = $probe.codec_name
        format_name = $probe.format_name
        bit_rate = $probe.bit_rate
        rotation = $probe.rotation
    }
    extraction_profile = [ordered]@{
        quality = $Quality
        extraction_fps = $ExtractionFps
        target_frames = $TargetFrames
        target_timestamps = $TargetTimestamps
        max_output_width = $MaxOutputWidth
        virtual_view_mode = $VirtualViewMode
        view_width = $ViewWidth
        view_height = $ViewHeight
    }
    derived_frame_count = $selectedImages.Count
    virtual_view_mode = $VirtualViewMode
    ffmpeg_plan = @($ffmpegPlan)
    pyscenedetect_requested = [bool]$UseSceneDetectRequested
    pyscenedetect_available = $pyscenedetectAvailable
    pyscenedetect_used = $pyscenedetectUsed
}

$manifestPath = Join-Path $stageRoot 'stage_manifest.json'
Save-360GSJsonFile -Path $manifestPath -Value $manifest

Write-Host "Media prepared."
Write-Host "Stage root: $stageRoot"
Write-Host "Selected images: $($selectedImages.Count)"
Write-Host "Manifest: $manifestPath"
Write-Host "Source kind: $SourceKind"

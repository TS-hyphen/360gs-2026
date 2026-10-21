[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InstallRoot,

    [string]$LogPath,

    [switch]$CheckSharpPreview,

    [switch]$CheckColmapGlobal,

    [switch]$CheckGlomapStandalone,

    [switch]$CheckLichtFeldStudio
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-WindowsPlatformInfo {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $build = [int]$os.BuildNumber
    $currentVersion = $null
    try {
        $currentVersion = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    }
    catch {
        $currentVersion = $null
    }

    $displayVersion = if ($currentVersion -and $currentVersion.PSObject.Properties.Name -contains 'DisplayVersion') { [string]$currentVersion.DisplayVersion } else { $null }
    $productName = if ($currentVersion -and $currentVersion.PSObject.Properties.Name -contains 'ProductName') { [string]$currentVersion.ProductName } else { [string]$os.Caption }
    $family = 'unsupported'
    $supportLabel = 'Unsupported Windows'

    if ($build -ge 22000) {
        $family = 'windows-11'
        $supportLabel = 'Windows 11'
    }
    elseif ($build -ge 19045) {
        $family = 'windows-10'
        $supportLabel = 'Windows 10 22H2+'
    }

    return [ordered]@{
        family = $family
        support_label = $supportLabel
        product_name = $productName
        version = [string]$os.Version
        build = $build
        display_version = $displayVersion
        architecture = [string]$os.OSArchitecture
        is_supported = ($family -ne 'unsupported')
    }
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Save-Json {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $Value | ConvertTo-Json -Depth 10 | Set-Content -Path $Path
}

function Write-Event {
    param(
        [string]$Level,
        [string]$Event,
        [object]$Detail = $null
    )

    $msg = "[SELFTEST][$Level] $Event"
    Write-Host $msg

    if ($LogPath) {
        $entry = [ordered]@{
            timestamp = (Get-Date).ToString('o')
            stage = 'selftest'
            level = $Level
            event = $Event
            detail = $Detail
        }
        Add-Content -Path $LogPath -Value ($entry | ConvertTo-Json -Compress -Depth 6)
    }
}

function New-SelfTestRoot {
    param([Parameter(Mandatory = $true)][string]$InstallPath)

    $baseRoot = if ($LogPath) {
        Split-Path -Parent $LogPath
    }
    else {
        Join-Path $InstallPath 'logs'
    }

    Ensure-Directory -Path $baseRoot
    $root = Join-Path $baseRoot ('selftest-sharp-preview-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Ensure-Directory -Path $root
    return $root
}

function New-SmokeImage {
    param([Parameter(Mandatory = $true)][string]$Path)

    Add-Type -AssemblyName System.Drawing

    $width = 192
    $height = 192
    $bitmap = New-Object System.Drawing.Bitmap($width, $height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)

    try {
        $graphics.Clear([System.Drawing.Color]::FromArgb(236, 241, 248))

        $skyBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
            (New-Object System.Drawing.Point(0, 0)),
            (New-Object System.Drawing.Point(0, $height)),
            ([System.Drawing.Color]::FromArgb(84, 153, 255)),
            ([System.Drawing.Color]::FromArgb(245, 248, 252))
        )
        $graphics.FillRectangle($skyBrush, 0, 0, $width, $height)
        $skyBrush.Dispose()

        $groundBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(142, 166, 110))
        $graphics.FillRectangle($groundBrush, 0, 118, $width, 74)
        $groundBrush.Dispose()

        $shapeBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(204, 96, 44))
        $graphics.FillEllipse($shapeBrush, 42, 46, 108, 68)
        $graphics.FillRectangle($shapeBrush, 72, 86, 48, 52)
        $shapeBrush.Dispose()

        $detailPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 248, 220), 4)
        $graphics.DrawLine($detailPen, 54, 134, 138, 134)
        $graphics.DrawLine($detailPen, 72, 48, 122, 102)
        $graphics.DrawLine($detailPen, 122, 48, 72, 102)
        $detailPen.Dispose()

        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Jpeg)
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Invoke-SharpPreviewSmoke {
    param(
        [Parameter(Mandatory = $true)][string]$SharpCli,
        [Parameter(Mandatory = $true)][string]$InstallPath,
        [Parameter(Mandatory = $true)][string]$TorchCudaFlag
    )

    $selfTestRoot = New-SelfTestRoot -InstallPath $InstallPath
    $inputRoot = Join-Path $selfTestRoot 'input'
    $outputRoot = Join-Path $selfTestRoot 'preview_output'
    $stdoutPath = Join-Path $selfTestRoot 'sharp.stdout.log'
    $stderrPath = Join-Path $selfTestRoot 'sharp.stderr.log'
    $cullManifestPath = Join-Path $selfTestRoot 'cull_manifest.json'
    $qcReportPath = Join-Path $selfTestRoot 'preview_qc_report.json'
    Ensure-Directory -Path $inputRoot
    Ensure-Directory -Path $outputRoot

    $sampleImagePath = Join-Path $inputRoot 'selftest-scene.jpg'
    New-SmokeImage -Path $sampleImagePath

    $checkpointPath = Join-Path $env:USERPROFILE '.cache\torch\hub\checkpoints\sharp_2572gikvuh.pt'
    $checkpointMode = if (Test-Path -LiteralPath $checkpointPath) { 'cached-default' } else { 'auto-download-default' }
    if ($checkpointMode -eq 'auto-download-default') {
        Write-Event -Level 'WARN' -Event 'SHARP checkpoint cache not found. The real preview smoke may download the default checkpoint during self-test.'
    }

    $device = if ($TorchCudaFlag -eq '1') { 'cuda' } else { 'cpu' }
    $args = @(
        'predict',
        '-i', $inputRoot,
        '-o', $outputRoot,
        '--device', $device
    )
    if ($checkpointMode -eq 'cached-default') {
        $args += @('-c', $checkpointPath)
    }

    $start = Get-Date
    $proc = Start-Process -FilePath $SharpCli -ArgumentList $args -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -Wait -PassThru -NoNewWindow
    $end = Get-Date

    if ($proc.ExitCode -ne 0) {
        $stderrText = if (Test-Path -LiteralPath $stderrPath) { Get-Content -Raw -Path $stderrPath } else { '' }
        throw "SHARP preview smoke failed with exit code $($proc.ExitCode). $stderrText"
    }

    $plyFiles = @(Get-ChildItem -Path $outputRoot -Filter '*.ply' -File -Recurse -ErrorAction SilentlyContinue)
    if ($plyFiles.Count -eq 0) {
        throw "SHARP preview smoke finished without producing a .ply artifact in $outputRoot"
    }

    $cullManifest = [ordered]@{
        generated_at = (Get-Date).ToString('o')
        mode = 'selftest'
        kept = @(
            [ordered]@{
                relative_path = 'input\selftest-scene.jpg'
                reason = 'bundled self-test sample'
            }
        )
        rejected = @()
    }
    Save-Json -Path $cullManifestPath -Value $cullManifest

    $qcReport = [ordered]@{
        generated_at = (Get-Date).ToString('o')
        status = 'pass'
        runner = 'sharp-preview-selftest'
        device = $device
        checkpoint_mode = $checkpointMode
        duration_seconds = [Math]::Round(($end - $start).TotalSeconds, 2)
        input_image_count = 1
        output_ply_count = $plyFiles.Count
        output_ply_files = @($plyFiles | ForEach-Object { $_.FullName })
        stdout_log = $stdoutPath
        stderr_log = $stderrPath
    }
    Save-Json -Path $qcReportPath -Value $qcReport

    return [ordered]@{
        root = $selfTestRoot
        cull_manifest = $cullManifestPath
        preview_qc_report = $qcReportPath
        output_root = $outputRoot
        output_ply_count = $plyFiles.Count
        duration_seconds = [Math]::Round(($end - $start).TotalSeconds, 2)
    }
}

$warnings = 0
$windowsInfo = Get-WindowsPlatformInfo
Write-Event -Level 'INFO' -Event "Detected OS: $($windowsInfo.product_name) build $($windowsInfo.build) display $($windowsInfo.display_version) arch $($windowsInfo.architecture)"
if (-not $windowsInfo.is_supported) {
    Write-Event -Level 'ERROR' -Event "Unsupported Windows platform detected. Require Windows 10 22H2+ or Windows 11."
    exit 2
}

if (-not (Test-Path -LiteralPath $InstallRoot)) {
    Write-Event -Level 'ERROR' -Event "Install root missing: $InstallRoot"
    exit 2
}

$runtimePython = Join-Path $InstallRoot 'runtime\python311\python.exe'
if (-not (Test-Path -LiteralPath $runtimePython)) {
    Write-Event -Level 'ERROR' -Event "Python runtime missing: $runtimePython"
    exit 2
}
Write-Event -Level 'INFO' -Event 'Python runtime found.'

$wrapperPs = Join-Path $InstallRoot 'run360gs.ps1'
$wrapperCmd = Join-Path $InstallRoot 'run360gs.cmd'
foreach ($path in @($wrapperPs, $wrapperCmd)) {
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Event -Level 'ERROR' -Event "Launcher missing: $path"
        exit 2
    }
}
Write-Event -Level 'INFO' -Event 'Launch wrappers found.'

$ffmpegPath = Get-ChildItem -Path (Join-Path $InstallRoot 'tools') -Recurse -Filter ffmpeg.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
if (-not $ffmpegPath) {
    Write-Event -Level 'WARN' -Event 'FFmpeg executable not found under tools/. Media ingest features may fail.'
    $warnings++
}
else {
    Write-Event -Level 'INFO' -Event "FFmpeg found at $ffmpegPath"
}

$appEntrypoint = Join-Path $InstallRoot 'app\main.py'
if (-not (Test-Path -LiteralPath $appEntrypoint)) {
    Write-Event -Level 'ERROR' -Event 'Pipeline app entrypoint is missing (app/main.py).'
    exit 2
}
else {
    Write-Event -Level 'INFO' -Event 'Pipeline app entrypoint found.'
    & $runtimePython $appEntrypoint --self-test | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Event -Level 'ERROR' -Event 'Pipeline app self-test failed.'
        exit 2
    }
    else {
        Write-Event -Level 'INFO' -Event 'Pipeline app self-test passed.'
    }
}

if ($CheckSharpPreview) {
    $torchCheck = & $runtimePython -c "import torch; print(int(torch.cuda.is_available()))" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Event -Level 'ERROR' -Event 'Torch import check failed for sharp-preview pack.'
        exit 2
    }
    else {
        Write-Event -Level 'INFO' -Event "Torch CUDA available flag: $torchCheck"
        if ($torchCheck -ne '1') {
            Write-Event -Level 'WARN' -Event 'Torch installed but CUDA not available in runtime.'
            $warnings++
        }
    }

    $sharpCli = Join-Path $InstallRoot 'runtime\python311\Scripts\sharp.exe'
    if (-not (Test-Path -LiteralPath $sharpCli)) {
        Write-Event -Level 'ERROR' -Event 'SHARP CLI executable not found in managed runtime.'
        exit 2
    }
    else {
        & $sharpCli --help | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Event -Level 'ERROR' -Event 'SHARP CLI exists but failed --help check.'
            exit 2
        }
        else {
            Write-Event -Level 'INFO' -Event 'SHARP CLI check passed.'
            try {
                $smoke = Invoke-SharpPreviewSmoke -SharpCli $sharpCli -InstallPath $InstallRoot -TorchCudaFlag $torchCheck
                Write-Event -Level 'INFO' -Event "SHARP preview smoke passed. Artifacts written to $($smoke.root)" -Detail $smoke
            }
            catch {
                Write-Event -Level 'ERROR' -Event $_.Exception.Message
                exit 2
            }
        }
    }
}

if ($CheckColmapGlobal) {
    $colmapExe = Join-Path $InstallRoot 'packs\colmap-global\bin\colmap.exe'
    if (-not (Test-Path -LiteralPath $colmapExe)) {
        Write-Event -Level 'WARN' -Event 'COLMAP executable not found in managed colmap-global pack.'
        $warnings++
    }
    else {
        & $colmapExe help | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Event -Level 'WARN' -Event 'COLMAP executable exists but failed help check.'
            $warnings++
        }
        else {
            Write-Event -Level 'INFO' -Event 'COLMAP CLI check passed.'
        }
    }
}

if ($CheckGlomapStandalone) {
    $glomapExe = Join-Path $InstallRoot 'packs\glomap-standalone\bin\glomap.exe'
    if (-not (Test-Path -LiteralPath $glomapExe)) {
        Write-Event -Level 'WARN' -Event 'GLOMAP executable not found in managed glomap-standalone pack.'
        $warnings++
    }
    else {
        & $glomapExe -h | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Event -Level 'WARN' -Event 'GLOMAP executable exists but failed help check.'
            $warnings++
        }
        else {
            Write-Event -Level 'INFO' -Event 'GLOMAP CLI check passed.'
        }
    }
}

if ($CheckLichtFeldStudio) {
    $lichtfeldExe = Join-Path $InstallRoot 'packs\lichtfeld-studio\bin\LichtFeld-Studio.exe'
    if (-not (Test-Path -LiteralPath $lichtfeldExe)) {
        Write-Event -Level 'WARN' -Event 'LichtFeld Studio executable not found in managed lichtfeld-studio pack.'
        $warnings++
    }
    else {
        Write-Event -Level 'INFO' -Event 'LichtFeld Studio executable found.'
    }

    $startMenuShortcut = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\360GS LichtFeld Studio.lnk'
    if (-not (Test-Path -LiteralPath $startMenuShortcut)) {
        Write-Event -Level 'WARN' -Event "LichtFeld Studio Start Menu shortcut not found: $startMenuShortcut"
        $warnings++
    }
    else {
        Write-Event -Level 'INFO' -Event "LichtFeld Studio Start Menu shortcut found at $startMenuShortcut"
    }
}

if ($warnings -gt 0) {
    Write-Event -Level 'WARN' -Event "Self-test completed with $warnings warning(s)."
    exit 1
}

Write-Event -Level 'INFO' -Event 'Self-test PASS.'
exit 0

[CmdletBinding()]
param(
    [ValidateSet('standard', 'portable')]
    [string]$Mode = 'portable',

    [ValidateSet('preview-min', 'research-full', 'offline-preview')]
    [string]$Profile = 'research-full',

    [string]$InstallDir,

    [string]$ManifestPath,

    [string]$SchemaPath,

    [string]$OfflineBundle,

    [string]$LogDir,

    [string]$ProxyUrl,

    [string[]]$AddPack = @(),

    [ValidateSet('reuse', 'upgrade', 'replace')]
    [string]$ExistingInstallPolicy = 'upgrade',

    [switch]$Repair,

    [switch]$UninstallManaged,

    [switch]$SkipSelfTest,

    [switch]$AcceptEula,

    [switch]$AllowUnverifiedArtifacts,

    [switch]$WhatIfInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ManagedInstallMarkerName = 'install-root.json'
$script:ApprovedDownloadHosts = @(
    'bootstrap.pypa.io',
    'download.pytorch.org',
    'github.com',
    'python.org',
    'www.python.org'
)
$script:GetPipSha256 = 'feba1c697df45be1b539b40d93c102c9ee9dde1d966303323b830b06f3fbca3c'
$script:SharpRepoUrl = 'git+https://github.com/apple/ml-sharp.git@1eaa046834b81852261262b41b0919f5c1efdd2e'

function Parse-JsonFileAsHashtable {
    param([Parameter(Mandatory = $true)][string]$Path)

    Add-Type -AssemblyName 'System.Web.Extensions'
    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $serializer.MaxJsonLength = 104857600
    $json = Get-Content -Raw -Path $Path
    return $serializer.DeserializeObject($json)
}

function ConvertTo-Array {
    param([Parameter(ValueFromPipeline = $true)]$InputObject)

    if ($null -eq $InputObject) {
        Write-Output -NoEnumerate @()
        return
    }

    if (($InputObject -is [System.Collections.IEnumerable]) -and -not ($InputObject -is [string])) {
        $arr = @($InputObject)
        Write-Output -NoEnumerate $arr
        return
    }

    Write-Output -NoEnumerate @($InputObject)
}

function New-InstallError {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Code = 'INSTALL_FAILED'
    )

    throw "[$Code] $Message"
}

function Get-DefaultInstallDir {
    param([string]$ResolvedMode)

    if ($ResolvedMode -eq 'standard') {
        return Join-Path $env:ProgramFiles '360GS'
    }

    return Join-Path $env:LOCALAPPDATA '360GS'
}

function Get-DefaultPacksForProfile {
    param([Parameter(Mandatory = $true)][string]$SelectedProfile)

    switch ($SelectedProfile) {
        'research-full' {
            return @('core', 'colmap-global', 'glomap-standalone', 'lichtfeld-studio')
        }
        default {
            return @('core')
        }
    }
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-ManagedInstallMarkerPath {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    return Join-Path (Join-Path $InstallRoot '.state') $script:ManagedInstallMarkerName
}

function Get-InstallRootStatus {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    $exists = Test-Path -LiteralPath $InstallRoot
    $entries = @()
    if ($exists) {
        $entries = @(Get-ChildItem -LiteralPath $InstallRoot -Force -ErrorAction SilentlyContinue)
    }

    $markerPath = Get-ManagedInstallMarkerPath -InstallRoot $InstallRoot
    $marker = $null
    if (Test-Path -LiteralPath $markerPath) {
        try {
            $marker = Parse-JsonFileAsHashtable -Path $markerPath
        }
        catch {
            $marker = $null
        }
    }

    return [ordered]@{
        exists = $exists
        is_empty = ($entries.Count -eq 0)
        marker_path = $markerPath
        has_marker = [bool]$marker
        marker = $marker
    }
}

function Assert-SafeInstallRoot {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    $fullPath = [System.IO.Path]::GetFullPath($InstallRoot)
    $rootPath = [System.IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.TrimEnd('\') -eq $rootPath.TrimEnd('\')) {
        New-InstallError -Message "Install root cannot be a drive root: $fullPath" -Code 'INSTALL_ROOT_UNSAFE'
    }
}

function Assert-InstallRootNotSourceProjectRoot {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$InstallerRoot
    )

    $fullInstallPath = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
    $sourceProjectRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $InstallerRoot)).TrimEnd('\')
    if ($fullInstallPath -eq $sourceProjectRoot) {
        New-InstallError -Message "Install root cannot be the same folder as the 360GS installer package source. Choose a different install folder." -Code 'INSTALL_ROOT_SOURCE_CONFLICT'
    }
}

function Assert-ManagedInstallRootForDestructiveAction {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$ActionName
    )

    Assert-SafeInstallRoot -InstallRoot $InstallRoot
    $status = Get-InstallRootStatus -InstallRoot $InstallRoot
    if (-not $status.exists -or $status.is_empty) {
        return
    }

    if (-not $status.has_marker) {
        New-InstallError -Message "$ActionName was requested for $InstallRoot, but that folder is not marked as a 360GS-managed install root. Re-run an upgrade install first to create the marker, or choose a different install directory." -Code 'INSTALL_ROOT_NOT_MANAGED'
    }
}

function Save-ManagedInstallMarker {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$ModeValue,
        [Parameter(Mandatory = $true)][string]$ProfileValue
    )

    $stateDir = Join-Path $InstallRoot '.state'
    Ensure-Directory -Path $stateDir
    $markerPath = Get-ManagedInstallMarkerPath -InstallRoot $InstallRoot
    $marker = [ordered]@{
        managed_by = '360gs-installer'
        install_root = [System.IO.Path]::GetFullPath($InstallRoot)
        mode = $ModeValue
        profile = $ProfileValue
        updated_at = (Get-Date).ToString('o')
    }
    $marker | ConvertTo-Json -Depth 8 | Set-Content -Path $markerPath
}

function Test-ApprovedHttpsUri {
    param([Parameter(Mandatory = $true)][string]$UriText)

    $uri = $null
    if (-not [System.Uri]::TryCreate($UriText, [System.UriKind]::Absolute, [ref]$uri)) {
        New-InstallError -Message "Invalid download URI: $UriText" -Code 'DOWNLOAD_URI_INVALID'
    }

    if ($uri.Scheme -ne 'https') {
        New-InstallError -Message "Only HTTPS downloads are allowed. Rejected URI: $UriText" -Code 'DOWNLOAD_URI_INSECURE'
    }

    if ($script:ApprovedDownloadHosts -notcontains $uri.Host.ToLowerInvariant()) {
        New-InstallError -Message "Download host '$($uri.Host)' is not on the approved installer allow-list." -Code 'DOWNLOAD_HOST_BLOCKED'
    }
}

function Remove-ManagedInstallArtifacts {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    Assert-ManagedInstallRootForDestructiveAction -InstallRoot $InstallRoot -ActionName 'Managed uninstall/replace'

    $managedPaths = @(
        'app',
        'benchmark',
        'runtime',
        'tools',
        'packs',
        '.state',
        '.cache',
        'viewer',
        'view360gs.ps1',
        'view360gs.cmd',
        'openlichtfeld.ps1',
        'openlichtfeld.cmd',
        'run360gs.ps1',
        'run360gs.cmd'
    )

    foreach ($rel in $managedPaths) {
        $target = Join-Path $InstallRoot $rel
        if (Test-Path -LiteralPath $target) {
            Remove-Item -Path $target -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Remove-DeprecatedViewerArtifacts {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [switch]$WhatIf
    )

    $rootStatus = Get-InstallRootStatus -InstallRoot $InstallRoot
    if (-not $rootStatus.has_marker) {
        return
    }

    foreach ($rel in @('viewer', 'view360gs.ps1', 'view360gs.cmd')) {
        $target = Join-Path $InstallRoot $rel
        if (-not (Test-Path -LiteralPath $target)) {
            continue
        }

        Write-InstallLog -Stage 'cleanup' -Event "Removing deprecated viewer artifact: $target"
        if (-not $WhatIf) {
            Remove-Item -Path $target -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-ExternalCommandChecked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$ErrorCode,
        [string]$FriendlyName = $FilePath
    )

    $proc = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) {
        New-InstallError -Message "$FriendlyName failed with exit code $($proc.ExitCode)." -Code $ErrorCode
    }
}

function Install-SharpPreviewPack {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$CacheDir,
        [string]$Proxy,
        [switch]$AllowUnverified,
        [switch]$WhatIf,
        [switch]$ForceReinstall
    )

    $packRoot = Join-Path $InstallRoot 'packs\sharp-preview'
    $marker = Join-Path $packRoot 'installed.txt'
    Ensure-Directory -Path $packRoot

    if ((-not $ForceReinstall) -and (Test-Path -LiteralPath $marker)) {
        Write-InstallLog -Stage 'pack' -Event "sharp-preview pack already installed; skipping."
        return
    }

    $python = Join-Path $InstallRoot 'runtime\python311\python.exe'
    if (-not (Test-Path -LiteralPath $python)) {
        New-InstallError -Message "Managed Python runtime missing for sharp-preview pack: $python" -Code 'PYTHON_RUNTIME_MISSING'
    }

    $pthPath = Join-Path $InstallRoot 'runtime\python311\python311._pth'
    if (Test-Path -LiteralPath $pthPath) {
        $pthRaw = Get-Content -Raw -Path $pthPath
        if ($pthRaw -match '#\s*import site') {
            $pthRaw = $pthRaw -replace '#\s*import site', 'import site'
            Set-Content -Path $pthPath -Value $pthRaw
            Write-InstallLog -Stage 'pack' -Event 'Enabled import site in embedded Python ._pth file for pip compatibility.'
        }
    }

    if ($WhatIf) {
        Write-InstallLog -Stage 'pack' -Event 'WhatIf mode active; skipped sharp-preview package installation.' -Level 'WARN'
        return
    }

    if (-not $AllowUnverified) {
        New-InstallError -Message 'sharp-preview installation currently relies on Python package bootstrap and pip-installed dependencies that are not fully manifest-hash-locked. Re-run with -AllowUnverifiedArtifacts to permit this research-only install path.' -Code 'UNVERIFIED_SHARP_PREVIEW'
    }

    $getPipPy = Join-Path $CacheDir 'get-pip.py'
    Invoke-DownloadWithResume -Uri 'https://bootstrap.pypa.io/get-pip.py' -OutFile $getPipPy -Proxy $Proxy
    Test-Sha256 -Path $getPipPy -ExpectedSha256 $script:GetPipSha256

    # Bootstrap pip in embedded Python runtime.
    Invoke-ExternalCommandChecked -FilePath $python -ArgumentList @($getPipPy) -Stage 'pack' -ErrorCode 'PIP_BOOTSTRAP_FAILED' -FriendlyName 'pip bootstrap'
    Invoke-ExternalCommandChecked -FilePath $python -ArgumentList @('-m', 'pip', 'install', '--upgrade', 'pip') -Stage 'pack' -ErrorCode 'PIP_UPGRADE_FAILED' -FriendlyName 'pip upgrade'

    # Install CUDA-enabled Torch wheels. cu121 is chosen for broad wheel availability on Windows.
    Invoke-ExternalCommandChecked -FilePath $python -ArgumentList @('-m', 'pip', 'install', 'torch==2.5.1', 'torchvision==0.20.1', 'torchaudio==2.5.1', '--index-url', 'https://download.pytorch.org/whl/cu121') -Stage 'pack' -ErrorCode 'TORCH_INSTALL_FAILED' -FriendlyName 'torch install'

    # Install SHARP CLI from Apple repository.
    Invoke-ExternalCommandChecked -FilePath $python -ArgumentList @('-m', 'pip', 'install', $script:SharpRepoUrl) -Stage 'pack' -ErrorCode 'SHARP_INSTALL_FAILED' -FriendlyName 'ml-sharp install'

    $installedAt = (Get-Date).ToString('o')
@" 
installed_at=$installedAt
torch=2.5.1
torchvision=0.20.1
torchaudio=2.5.1
sharp_source=$($script:SharpRepoUrl)
security_note=sharp-preview uses research-only pip bootstrap and network package resolution
"@ | Set-Content -Path $marker

    Write-InstallLog -Stage 'pack' -Event 'sharp-preview pack installation completed.'
    Write-InstallLog -Stage 'pack' -Event 'sharp-preview was installed through a research-only Python package path. Keep using -AllowUnverifiedArtifacts until this pack is fully manifest-pinned.' -Level 'WARN' -ErrorCode 'UNVERIFIED_SHARP_PREVIEW'
}

function Get-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PreferredPowerShellExe {
    $candidates = @()

    $pwsh = Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pwsh -and $pwsh.Source) {
        $candidates += $pwsh.Source
    }

    $pwshFallback = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (Test-Path -LiteralPath $pwshFallback) {
        $candidates += $pwshFallback
    }

    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $windowsPowerShell) {
        $candidates += $windowsPowerShell
    }

    $resolved = @($candidates | Where-Object { $_ } | Select-Object -Unique)
    if ($resolved.Count -eq 0) {
        New-InstallError -Message 'No supported PowerShell executable was found for installer/runtime operations.' -Code 'POWERSHELL_NOT_FOUND'
    }

    return $resolved[0]
}

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
        caption = [string]$os.Caption
        version = [string]$os.Version
        build = $build
        display_version = $displayVersion
        architecture = [string]$os.OSArchitecture
        preferred_shell = Get-PreferredPowerShellExe
        is_supported = ($family -ne 'unsupported')
    }
}

function ConvertTo-VersionOrNull {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    try {
        return [version]$Value
    }
    catch {
        return $null
    }
}

function Get-DetectedCommandInfo {
    param(
        [Parameter(Mandatory = $true)][string]$CommandName,
        [string[]]$VersionArguments = @('--version')
    )

    $cmd = Get-Command $CommandName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) {
        return [ordered]@{
            name = $CommandName
            present = $false
            source = $null
            version_text = $null
        }
    }

    $versionText = $null
    try {
        $output = & $cmd.Source @VersionArguments 2>&1 | Select-Object -First 1
        if ($output) {
            $versionText = [string]$output
        }
    }
    catch {
        $versionText = $null
    }

    return [ordered]@{
        name = $CommandName
        present = $true
        source = $cmd.Source
        version_text = $versionText
    }
}

function Get-SystemDependencyInventory {
    $windowsInfo = Get-WindowsPlatformInfo
    $pythonInfo = Get-DetectedCommandInfo -CommandName 'python' -VersionArguments @('--version')
    $ffmpegInfo = Get-DetectedCommandInfo -CommandName 'ffmpeg' -VersionArguments @('-version')

    $controllers = @(Get-CimInstance -ClassName Win32_VideoController | Select-Object Name,DriverVersion,DriverDate,AdapterRAM)
    $nvidiaControllers = @($controllers | Where-Object { $_.Name -match 'NVIDIA' })

    $nvidiaSmi = Get-Command 'nvidia-smi' -ErrorAction SilentlyContinue | Select-Object -First 1
    $nvidiaQueryRaw = $null
    $nvidiaSummaryRaw = $null
    $displayDriverVersion = $null
    $cudaRuntimeVersion = $null
    $vramMb = $null

    if ($nvidiaSmi) {
        try {
            $nvidiaQueryRaw = & $nvidiaSmi.Source --query-gpu=name,driver_version,memory.total --format=csv,noheader,nounits 2>$null
            if ($LASTEXITCODE -eq 0 -and $nvidiaQueryRaw) {
                $firstRow = [string]($nvidiaQueryRaw | Select-Object -First 1)
                $parts = @($firstRow -split '\s*,\s*')
                if ($parts.Count -ge 3) {
                    $displayDriverVersion = $parts[1]
                    $parsedMemory = 0
                    if ([int]::TryParse($parts[2], [ref]$parsedMemory)) {
                        $vramMb = $parsedMemory
                    }
                }
            }
        }
        catch { }

        try {
            $nvidiaSummaryRaw = & $nvidiaSmi.Source 2>$null
            if ($LASTEXITCODE -eq 0 -and $nvidiaSummaryRaw) {
                foreach ($line in @($nvidiaSummaryRaw)) {
                    if ($line -match 'CUDA Version:\s*([0-9.]+)') {
                        $cudaRuntimeVersion = $Matches[1]
                        break
                    }
                }
            }
        }
        catch { }
    }

    if (-not $vramMb -and $nvidiaControllers.Count -gt 0) {
        $adapterRamBytes = [double]($nvidiaControllers[0].AdapterRAM)
        if ($adapterRamBytes -gt 0) {
            $vramMb = [int][Math]::Round($adapterRamBytes / 1MB, 0)
        }
    }

    $gpuTier = 'cpu-only'
    if ($nvidiaControllers.Count -gt 0) {
        $gpuTier = 'preview-only'
        if ($vramMb -ge 8192) {
            $gpuTier = 'production-lite'
        }
        if ($vramMb -ge 12288) {
            $gpuTier = 'production-target'
        }
    }

    return [ordered]@{
        windows = $windowsInfo
        system_python = $pythonInfo
        system_ffmpeg = $ffmpegInfo
        gpu = [ordered]@{
            controllers = @($controllers | ForEach-Object {
                [ordered]@{
                    name = $_.Name
                    driver_version = $_.DriverVersion
                    driver_date = if ($_.DriverDate) { ([datetime]$_.DriverDate).ToString('yyyy-MM-dd') } else { $null }
                    adapter_ram_mb = if ($_.AdapterRAM) { [int][Math]::Round(([double]$_.AdapterRAM) / 1MB, 0) } else { $null }
                }
            })
            has_nvidia = ($nvidiaControllers.Count -gt 0)
            nvidia_gpu_names = @($nvidiaControllers | ForEach-Object { $_.Name })
            nvidia_smi_present = [bool]$nvidiaSmi
            nvidia_smi_path = if ($nvidiaSmi) { $nvidiaSmi.Source } else { $null }
            display_driver_version = $displayDriverVersion
            display_driver_version_parsed = if ($displayDriverVersion) { $displayDriverVersion } else { $null }
            cuda_runtime_version = $cudaRuntimeVersion
            estimated_vram_mb = $vramMb
            capability_tier = $gpuTier
        }
    }
}

function Write-SystemInventoryReport {
    param(
        [Parameter(Mandatory = $true)]$Inventory,
        [string[]]$RequestedPacks
    )

    Write-InstallReportLine ''
    Write-InstallReportLine 'Detected System Software'
    Write-InstallReportLine "Windows OS: $($Inventory.windows.product_name) | build $($Inventory.windows.build) | version $($Inventory.windows.version) | display $($Inventory.windows.display_version) | arch $($Inventory.windows.architecture)"
    Write-InstallReportLine "Windows Support Status: $($Inventory.windows.support_label)"
    Write-InstallReportLine "Preferred PowerShell: $($Inventory.windows.preferred_shell)"

    if ($Inventory.system_python.present) {
        Write-InstallReportLine "System Python: detected at $($Inventory.system_python.source)"
        if ($Inventory.system_python.version_text) {
            Write-InstallReportLine "System Python Version: $($Inventory.system_python.version_text)"
        }
        Write-InstallReportLine 'System Python Decision: ignored for install isolation; managed embedded Python will be used.'
    }
    else {
        Write-InstallReportLine 'System Python: not detected'
        Write-InstallReportLine 'System Python Decision: managed embedded Python will be installed or reused.'
    }

    if ($Inventory.system_ffmpeg.present) {
        Write-InstallReportLine "System FFmpeg: detected at $($Inventory.system_ffmpeg.source)"
        if ($Inventory.system_ffmpeg.version_text) {
            Write-InstallReportLine "System FFmpeg Version: $($Inventory.system_ffmpeg.version_text)"
        }
        Write-InstallReportLine 'System FFmpeg Decision: ignored for install isolation; managed FFmpeg will be used.'
    }
    else {
        Write-InstallReportLine 'System FFmpeg: not detected'
        Write-InstallReportLine 'System FFmpeg Decision: managed FFmpeg will be installed or reused.'
    }

    if ($Inventory.gpu.controllers.Count -gt 0) {
        Write-InstallReportLine 'Detected Video Controllers:'
        foreach ($gpu in @($Inventory.gpu.controllers)) {
            $ramText = if ($gpu.adapter_ram_mb) { "$($gpu.adapter_ram_mb) MB" } else { 'unknown RAM' }
            $driverDateText = if ($gpu.driver_date) { $gpu.driver_date } else { 'unknown date' }
            Write-InstallReportLine "  - $($gpu.name) | driver $($gpu.driver_version) | date $driverDateText | RAM $ramText"
        }
    }
    else {
        Write-InstallReportLine 'Detected Video Controllers: none'
    }

    if ($Inventory.gpu.has_nvidia) {
        $driverText = if ($Inventory.gpu.display_driver_version) { $Inventory.gpu.display_driver_version } else { 'unknown' }
        $cudaText = if ($Inventory.gpu.cuda_runtime_version) { $Inventory.gpu.cuda_runtime_version } else { 'unknown' }
        $vramText = if ($Inventory.gpu.estimated_vram_mb) { "$($Inventory.gpu.estimated_vram_mb) MB" } else { 'unknown' }
        Write-InstallReportLine "NVIDIA GPU State: detected | driver $driverText | CUDA runtime $cudaText | VRAM $vramText | tier $($Inventory.gpu.capability_tier)"
        Write-InstallReportLine 'NVIDIA Driver Decision: system dependency only; installer will not modify or uninstall GPU drivers.'
    }
    else {
        Write-InstallReportLine 'NVIDIA GPU State: not detected'
        Write-InstallReportLine 'NVIDIA Driver Decision: no system GPU driver change performed by installer.'
    }

    Write-InstallReportLine "Requested Packs: $($RequestedPacks -join ', ')"
}

function Get-CompatibilityFindings {
    param(
        [Parameter(Mandatory = $true)]$Inventory,
        [Parameter(Mandatory = $true)][string]$SelectedProfile,
        [string[]]$RequestedPacks
    )

    $requestedPacksArr = ConvertTo-Array -InputObject $RequestedPacks
    $gpuPacks = @('colmap-global', 'glomap-standalone', 'vggsfm', 'vggt', 'lichtfeld-studio')
    $selectedGpuPacks = @($requestedPacksArr | Where-Object { $gpuPacks -contains $_ })
    $findings = @()

    if (-not $Inventory.gpu.has_nvidia) {
        $findings += [pscustomobject][ordered]@{
            severity = if ($selectedGpuPacks.Count -gt 0) { 'error' } else { 'warn' }
            event = 'NVIDIA GPU not detected.'
            error_code = 'GPU_NOT_DETECTED'
            report_line = if ($selectedGpuPacks.Count -gt 0) {
                "Compatibility: FAIL - selected packs ($($selectedGpuPacks -join ', ')) expect an NVIDIA GPU, but none was detected."
            }
            else {
                'Compatibility: WARN - no NVIDIA GPU detected. Preview-only CPU workflows may still work.'
            }
            remediation = if ($selectedGpuPacks.Count -gt 0) {
                'Remediation: use a machine with an NVIDIA discrete GPU for these packs, or re-run the installer with preview-only packs.'
            }
            else {
                'Remediation: none required for preview-only installs. For production packs, use an NVIDIA-equipped machine.'
            }
        }
        return @($findings)
    }

    if ($requestedPacksArr -contains 'lichtfeld-studio') {
        $driverVersion = ConvertTo-VersionOrNull -Value $Inventory.gpu.display_driver_version
        $cudaVersion = ConvertTo-VersionOrNull -Value $Inventory.gpu.cuda_runtime_version

        if (-not $driverVersion) {
            $findings += [pscustomobject][ordered]@{
                severity = 'warn'
                event = 'Could not verify NVIDIA display driver version for LichtFeld Studio.'
                error_code = 'DRIVER_VERSION_UNKNOWN'
                report_line = 'Compatibility: WARN - LichtFeld Studio pack selected, but the NVIDIA display driver version could not be verified.'
                remediation = 'Remediation: run nvidia-smi manually. If it is unavailable, install or repair the NVIDIA driver, then re-run the installer.'
            }
        }
        elseif ($driverVersion -lt ([version]'570.0')) {
            $findings += [pscustomobject][ordered]@{
                severity = 'error'
                event = "NVIDIA driver $driverVersion is below the LichtFeld Studio expectation of 570.0."
                error_code = 'NVIDIA_DRIVER_TOO_OLD'
                report_line = "Compatibility: FAIL - LichtFeld Studio expects NVIDIA driver 570.0 or newer. Detected: $driverVersion."
                remediation = 'Remediation: update the NVIDIA driver to a current production driver that provides at least version 570.x, reboot, confirm with nvidia-smi, then re-run the installer.'
            }
        }
        else {
            $findings += [pscustomobject][ordered]@{
                severity = 'info'
                event = "NVIDIA driver $driverVersion meets the LichtFeld Studio expectation."
                error_code = ''
                report_line = "Compatibility: PASS - NVIDIA driver $driverVersion meets the LichtFeld Studio minimum expectation."
                remediation = $null
            }
        }

        if (-not $cudaVersion) {
            $findings += [pscustomobject][ordered]@{
                severity = 'warn'
                event = 'Could not verify CUDA runtime version reported by nvidia-smi.'
                error_code = 'CUDA_VERSION_UNKNOWN'
                report_line = 'Compatibility: WARN - CUDA runtime version could not be verified for LichtFeld Studio.'
                remediation = 'Remediation: run nvidia-smi and confirm the reported CUDA Version is 12.8 or newer. Update the NVIDIA driver if needed, then re-run the installer.'
            }
        }
        elseif ($cudaVersion -lt ([version]'12.8')) {
            $findings += [pscustomobject][ordered]@{
                severity = 'error'
                event = "CUDA runtime $cudaVersion is below the LichtFeld Studio expectation of 12.8."
                error_code = 'CUDA_RUNTIME_TOO_OLD'
                report_line = "Compatibility: FAIL - LichtFeld Studio expects CUDA runtime 12.8 or newer. Detected: $cudaVersion."
                remediation = 'Remediation: update the NVIDIA driver until nvidia-smi reports CUDA Version 12.8 or newer, reboot, and re-run the installer.'
            }
        }
        else {
            $findings += [pscustomobject][ordered]@{
                severity = 'info'
                event = "CUDA runtime $cudaVersion meets the LichtFeld Studio expectation."
                error_code = ''
                report_line = "Compatibility: PASS - CUDA runtime $cudaVersion meets the LichtFeld Studio minimum expectation."
                remediation = $null
            }
        }
    }

    if ($Inventory.gpu.estimated_vram_mb) {
        if ($Inventory.gpu.estimated_vram_mb -lt 8192) {
            $findings += [pscustomobject][ordered]@{
                severity = 'warn'
                event = "Estimated NVIDIA VRAM $($Inventory.gpu.estimated_vram_mb) MB is below the production-lite target."
                error_code = 'VRAM_BELOW_TARGET'
                report_line = "Compatibility: WARN - GPU VRAM is about $($Inventory.gpu.estimated_vram_mb) MB, below the 8 GB production-lite target."
                remediation = 'Remediation: preview and light research runs can proceed. For heavier production jobs, use a machine with at least 8 GB VRAM, preferably 12 GB or more.'
            }
        }
        else {
            $findings += [pscustomobject][ordered]@{
                severity = 'info'
                event = "Estimated NVIDIA VRAM $($Inventory.gpu.estimated_vram_mb) MB is at or above the production-lite target."
                error_code = ''
                report_line = "Compatibility: PASS - GPU VRAM is about $($Inventory.gpu.estimated_vram_mb) MB."
                remediation = $null
            }
        }
    }

    return @($findings)
}

$global:LogFile = $null
$global:InstallReport = $null

function Write-InstallLog {
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$Event,
        [string]$Level = 'INFO',
        [string]$ErrorCode = '',
        [object]$Detail = $null
    )

    $entry = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        stage = $Stage
        level = $Level
        event = $Event
        error_code = $ErrorCode
        detail = $Detail
    }

    $json = $entry | ConvertTo-Json -Compress -Depth 8
    Add-Content -Path $global:LogFile -Value $json

    $prefix = "[$Level][$Stage]"
    Write-Host "$prefix $Event"
}

function Write-InstallReportLine {
    param([AllowEmptyString()][string]$Line = '')

    Add-Content -Path $global:InstallReport -Value $Line
}

function Test-Sha256 {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256,
        [switch]$AllowUnverified
    )

    $normalizedExpected = $ExpectedSha256.Trim().ToLowerInvariant()

    if ($normalizedExpected -eq ('0' * 64)) {
        if ($AllowUnverified) {
            Write-InstallLog -Stage 'verify' -Event "Skipping checksum for $Path because placeholder hash was used and AllowUnverifiedArtifacts is enabled." -Level 'WARN' -ErrorCode 'UNVERIFIED_ARTIFACT'
            return
        }

        New-InstallError -Message "Artifact at $Path has placeholder checksum. Update install-manifest.lock.json with real SHA-256 or run with -AllowUnverifiedArtifacts for research-only use." -Code 'CHECKSUM_PLACEHOLDER'
    }

    $actualHash = (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLowerInvariant()
    if ($actualHash -ne $normalizedExpected) {
        New-InstallError -Message "Checksum mismatch for $Path. Expected $normalizedExpected, got $actualHash." -Code 'CHECKSUM_MISMATCH'
    }
}

function Invoke-DownloadWithResume {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [string]$Proxy
    )

    Ensure-Directory -Path (Split-Path -Path $OutFile -Parent)
    Test-ApprovedHttpsUri -UriText $Uri

    if (Test-Path -LiteralPath $OutFile) {
        Write-InstallLog -Stage 'download' -Event "Using existing cached artifact: $OutFile"
        return
    }

    Write-InstallLog -Stage 'download' -Event "Downloading $Uri"

    $invokeParams = @{
        Uri = $Uri
        OutFile = $OutFile
        UseBasicParsing = $true
    }

    if ($Proxy) {
        $invokeParams['Proxy'] = $Proxy
    }

    $maxAttempts = 4
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            Invoke-WebRequest @invokeParams
            return
        }
        catch {
            if ($attempt -eq $maxAttempts) {
                New-InstallError -Message "Failed downloading $Uri after $maxAttempts attempts. Last error: $($_.Exception.Message)" -Code 'DOWNLOAD_FAILED'
            }

            $delay = [Math]::Pow(2, $attempt)
            Write-InstallLog -Stage 'download' -Event "Download retry $attempt failed for $Uri. Retrying in $delay seconds." -Level 'WARN' -ErrorCode 'DOWNLOAD_RETRY'
            Start-Sleep -Seconds $delay
        }
    }
}

function Expand-TarGz {
    param(
        [Parameter(Mandatory = $true)][string]$TarGzPath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    Ensure-Directory -Path $DestinationPath
    & tar -xzf $TarGzPath -C $DestinationPath
    if ($LASTEXITCODE -ne 0) {
        New-InstallError -Message "Failed extracting tar.gz artifact: $TarGzPath" -Code 'EXTRACT_FAILED'
    }
}

function Expand-ZipNested {
    param(
        [Parameter(Mandatory = $true)][string]$OuterZipPath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][string]$NestedZipPattern
    )

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("360gs-nestedzip-" + [guid]::NewGuid().ToString('N'))
    Ensure-Directory -Path $tempRoot

    try {
        Expand-Archive -Path $OuterZipPath -DestinationPath $tempRoot -Force
        $nestedZip = Get-ChildItem -Path $tempRoot -Recurse -File | Where-Object { $_.Name -like $NestedZipPattern } | Select-Object -First 1
        if (-not $nestedZip) {
            New-InstallError -Message "Nested zip matching '$NestedZipPattern' not found inside $OuterZipPath" -Code 'NESTED_ZIP_MISSING'
        }

        Expand-Archive -Path $nestedZip.FullName -DestinationPath $DestinationPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Install-Artifact {
    param(
        [Parameter(Mandatory = $true)]$Artifact,
        [Parameter(Mandatory = $true)][string]$SourceFile,
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [switch]$AllowUnverified,
        [switch]$WhatIf
    )

    $id = $Artifact.id
    $method = $Artifact.install.method
    $targetSubdir = $Artifact.install.targetSubdir
    $targetDir = Join-Path $InstallRoot $targetSubdir

    Write-InstallLog -Stage 'install' -Event "Installing artifact '$id' using method '$method'."

    if ($WhatIf) {
        Write-InstallLog -Stage 'install' -Event "WhatIf mode active; skipped install actions for $id" -Level 'WARN'
        return
    }

    Ensure-Directory -Path $targetDir

    switch ($method) {
        'extract-zip' {
            Expand-Archive -Path $SourceFile -DestinationPath $targetDir -Force
        }
        'extract-zip-nested' {
            $nestedZipPattern = $Artifact.install.nestedZipPattern
            if (-not $nestedZipPattern) {
                New-InstallError -Message "Artifact '$id' uses extract-zip-nested but no nestedZipPattern was provided." -Code 'INVALID_INSTALL_METHOD'
            }
            Expand-ZipNested -OuterZipPath $SourceFile -DestinationPath $targetDir -NestedZipPattern $nestedZipPattern
        }
        'extract-tar-gz' {
            Expand-TarGz -TarGzPath $SourceFile -DestinationPath $targetDir
        }
        'copy-file' {
            $destFile = Join-Path $targetDir (Split-Path -Path $SourceFile -Leaf)
            Copy-Item -Path $SourceFile -Destination $destFile -Force
        }
        'run-installer' {
            $args = $Artifact.install.installerArgs
            $proc = Start-Process -FilePath $SourceFile -ArgumentList $args -Wait -PassThru
            if ($proc.ExitCode -ne 0) {
                New-InstallError -Message "Installer for artifact '$id' exited with code $($proc.ExitCode)." -Code 'INSTALLER_EXIT_NONZERO'
            }
        }
        default {
            New-InstallError -Message "Unsupported install method '$method' for artifact '$id'." -Code 'INVALID_INSTALL_METHOD'
        }
    }

    if ($Artifact.install.expectedRelativePath) {
        $expectedPath = Join-Path $targetDir $Artifact.install.expectedRelativePath
        if (-not (Test-Path -LiteralPath $expectedPath)) {
            New-InstallError -Message "Artifact '$id' expected file not found after install: $expectedPath" -Code 'INSTALL_VALIDATION_FAILED'
        }
    }
}

function Load-InstallState {
    param([string]$StatePath)

    if (-not (Test-Path -LiteralPath $StatePath)) {
        return @{
            completedArtifacts = @()
        }
    }

    return Parse-JsonFileAsHashtable -Path $StatePath
}

function Save-InstallState {
    param(
        [string]$StatePath,
        [hashtable]$State
    )

    $State | ConvertTo-Json -Depth 10 | Set-Content -Path $StatePath
}

function Validate-ManifestContract {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [string]$SelectedProfile,
        [string[]]$RequestedPacks
    )

    $requiredTopLevel = @('manifestVersion', 'generatedAtUtc', 'profiles', 'packs', 'artifacts')
    foreach ($key in $requiredTopLevel) {
        if (-not $Manifest.ContainsKey($key)) {
            New-InstallError -Message "Manifest missing required key '$key'." -Code 'MANIFEST_INVALID'
        }
    }

    if ($Manifest.profiles -notcontains $SelectedProfile) {
        New-InstallError -Message "Profile '$SelectedProfile' is not defined in manifest profiles." -Code 'PROFILE_UNSUPPORTED'
    }

    foreach ($pack in $RequestedPacks) {
        if ($Manifest.packs -notcontains $pack) {
            New-InstallError -Message "Requested add-pack '$pack' is not declared in manifest packs." -Code 'PACK_UNSUPPORTED'
        }
    }

    foreach ($artifact in $Manifest.artifacts) {
        foreach ($required in @('id', 'version', 'profiles', 'packs', 'source', 'sha256', 'install')) {
            if (-not $artifact.ContainsKey($required)) {
                New-InstallError -Message "Artifact is missing required key '$required'." -Code 'MANIFEST_INVALID'
            }
        }

        if (-not $artifact.source.ContainsKey('type') -or -not $artifact.source.ContainsKey('path')) {
            New-InstallError -Message "Artifact '$($artifact.id)' has invalid source definition." -Code 'MANIFEST_INVALID'
        }

        if (-not $artifact.install.ContainsKey('method') -or -not $artifact.install.ContainsKey('targetSubdir')) {
            New-InstallError -Message "Artifact '$($artifact.id)' has invalid install definition." -Code 'MANIFEST_INVALID'
        }
    }
}

function Select-Artifacts {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [string]$SelectedProfile,
        [string[]]$RequestedPacks
    )

    $selected = @()

    foreach ($artifact in (ConvertTo-Array -InputObject $Manifest.artifacts)) {
        $profileMatch = $artifact.profiles -contains $SelectedProfile
        $packMatch = $false
        $artifactPacks = ConvertTo-Array -InputObject $artifact.packs

        if ($artifactPacks.Count -eq 0) {
            $packMatch = $true
        }
        else {
            foreach ($p in $RequestedPacks) {
                if ($artifactPacks -contains $p) {
                    $packMatch = $true
                    break
                }
            }
        }

        if ($profileMatch -and $packMatch) {
            $selected += $artifact
        }
    }

    if ($selected.Count -eq 0) {
        New-InstallError -Message "No artifacts selected for profile '$SelectedProfile' and packs '$($RequestedPacks -join ',')'." -Code 'NO_ARTIFACTS_SELECTED'
    }

    return $selected
}

function Invoke-Preflight {
    param(
        [string]$ResolvedMode,
        [string]$TargetInstallDir,
        [string]$SelectedProfile,
        [string]$BundlePath,
        [string[]]$RequestedPacks
    )

    Write-InstallLog -Stage 'preflight' -Event "Running preflight checks for mode=$ResolvedMode profile=$SelectedProfile"
    Assert-SafeInstallRoot -InstallRoot $TargetInstallDir
    Assert-InstallRootNotSourceProjectRoot -InstallRoot $TargetInstallDir -InstallerRoot $PSScriptRoot

    $windowsInfo = Get-WindowsPlatformInfo
    Write-InstallLog -Stage 'preflight' -Event 'Detected Windows platform.' -Detail $windowsInfo
    if (-not $windowsInfo.is_supported) {
        New-InstallError -Message "Unsupported Windows platform '$($windowsInfo.product_name)' build $($windowsInfo.build). Require Windows 10 22H2+ or Windows 11." -Code 'OS_UNSUPPORTED'
    }

    if ($ResolvedMode -eq 'standard' -and -not (Get-IsAdmin)) {
        New-InstallError -Message 'Standard mode requires administrative privileges. Re-run in elevated shell or use portable mode.' -Code 'ADMIN_REQUIRED'
    }

    Ensure-Directory -Path $TargetInstallDir

    try {
        $testFile = Join-Path $TargetInstallDir '.write-test'
        'ok' | Set-Content -Path $testFile
        Remove-Item -Path $testFile -Force
    }
    catch {
        New-InstallError -Message "Install directory is not writable: $TargetInstallDir" -Code 'INSTALL_DIR_NOT_WRITABLE'
    }

    $drive = Get-PSDrive -Name ((Split-Path -Path $TargetInstallDir -Qualifier).TrimEnd(':'))
    $requestedPacksArr = ConvertTo-Array -InputObject $RequestedPacks
    $requiredGb = 20
    if ($SelectedProfile -eq 'research-full') {
        $requiredGb = 25
        foreach ($heavyPack in @('sharp-preview', 'vggsfm', 'vggt')) {
            if ($requestedPacksArr -contains $heavyPack) {
                $requiredGb = 40
                break
            }
        }
    }
    $freeGb = [Math]::Round($drive.Free / 1GB, 2)
    if ($freeGb -lt $requiredGb) {
        New-InstallError -Message "Insufficient disk space. Need ${requiredGb}GB, found ${freeGb}GB." -Code 'DISK_SPACE_LOW'
    }

    $inventory = Get-SystemDependencyInventory
    Write-InstallLog -Stage 'preflight' -Event 'Collected system dependency inventory.' -Detail $inventory

    $compatibilityFindings = @(Get-CompatibilityFindings -Inventory $inventory -SelectedProfile $SelectedProfile -RequestedPacks $requestedPacksArr)
    foreach ($finding in $compatibilityFindings) {
        $level = switch ($finding.severity) {
            'error' { 'ERROR' }
            'warn' { 'WARN' }
            default { 'INFO' }
        }
        Write-InstallLog -Stage 'preflight' -Event $finding.event -Level $level -ErrorCode $finding.error_code
        if ($finding.remediation) {
            Write-InstallLog -Stage 'preflight' -Event $finding.remediation -Level $level -ErrorCode $finding.error_code
        }
    }

    $blockingFinding = $compatibilityFindings | Where-Object { $_.severity -eq 'error' } | Select-Object -First 1
    if ($blockingFinding) {
        New-InstallError -Message "$($blockingFinding.report_line) $($blockingFinding.remediation)" -Code $blockingFinding.error_code
    }

    if ($SelectedProfile -eq 'offline-preview') {
        if (-not $BundlePath) {
            New-InstallError -Message 'offline-preview profile requires -OfflineBundle.' -Code 'OFFLINE_BUNDLE_REQUIRED'
        }

        if (-not (Test-Path -LiteralPath $BundlePath)) {
            New-InstallError -Message "Offline bundle not found: $BundlePath" -Code 'OFFLINE_BUNDLE_MISSING'
        }
    }

    return [ordered]@{
        windows = $windowsInfo
        inventory = $inventory
        compatibility_findings = $compatibilityFindings
    }
}

function Resolve-ArtifactToLocalPath {
    param(
        [Parameter(Mandatory = $true)]$Artifact,
        [Parameter(Mandatory = $true)][string]$CacheDir,
        [string]$BundleExtractRoot,
        [string]$Proxy,
        [switch]$WhatIf
    )

    $srcType = $Artifact.source.type
    $srcPath = $Artifact.source.path

    switch ($srcType) {
        'offline' {
            if (-not $BundleExtractRoot) {
                New-InstallError -Message "Artifact '$($Artifact.id)' requires offline bundle source but no bundle was provided." -Code 'OFFLINE_SOURCE_MISSING'
            }

            $offlinePath = Join-Path $BundleExtractRoot $srcPath
            if (-not (Test-Path -LiteralPath $offlinePath)) {
                New-InstallError -Message "Offline artifact '$($Artifact.id)' missing in bundle: $offlinePath" -Code 'OFFLINE_ARTIFACT_MISSING'
            }

            return $offlinePath
        }
        'url' {
            $leaf = Split-Path -Path $srcPath -Leaf
            $dest = Join-Path $CacheDir $leaf

            if (-not $WhatIf) {
                Invoke-DownloadWithResume -Uri $srcPath -OutFile $dest -Proxy $Proxy
            }

            return $dest
        }
        default {
            New-InstallError -Message "Unsupported source type '$srcType' for artifact '$($Artifact.id)'" -Code 'SOURCE_TYPE_UNSUPPORTED'
        }
    }
}

function Write-AppPayload {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$InstallerRoot
    )

    $sourceProjectRoot = Split-Path -Parent $InstallerRoot
    $sourceAppDir = Join-Path $sourceProjectRoot 'app'
    $sourceBenchmarkDir = Join-Path $sourceProjectRoot 'benchmark'
    $sourceConfigDir = Join-Path $sourceProjectRoot 'config'

    if (-not (Test-Path -LiteralPath $sourceAppDir)) {
        New-InstallError -Message "App payload source directory missing: $sourceAppDir" -Code 'APP_PAYLOAD_MISSING'
    }
    if (-not (Test-Path -LiteralPath $sourceBenchmarkDir)) {
        New-InstallError -Message "Benchmark support source directory missing: $sourceBenchmarkDir" -Code 'BENCHMARK_PAYLOAD_MISSING'
    }

    $targetAppDir = Join-Path $Root 'app'
    $targetBenchmarkDir = Join-Path $Root 'benchmark'
    foreach ($dir in @($targetAppDir, $targetBenchmarkDir)) {
        if (Test-Path -LiteralPath $dir) {
            Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Copy-Item -Path $sourceAppDir -Destination $targetAppDir -Recurse -Force
    Ensure-Directory -Path $targetBenchmarkDir
    Get-ChildItem -Path $sourceBenchmarkDir -File -Filter '*.ps1' | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination (Join-Path $targetBenchmarkDir $_.Name) -Force
    }
    foreach ($supportFile in @('README.md', 'datasets.standard.json')) {
        $sourceFile = Join-Path $sourceBenchmarkDir $supportFile
        if (Test-Path -LiteralPath $sourceFile) {
            Copy-Item -Path $sourceFile -Destination (Join-Path $targetBenchmarkDir $supportFile) -Force
        }
    }

    $sourceLibDir = Join-Path $sourceBenchmarkDir 'lib'
    $targetLibDir = Join-Path $targetBenchmarkDir 'lib'
    if (Test-Path -LiteralPath $sourceLibDir) {
        Copy-Item -Path $sourceLibDir -Destination $targetLibDir -Recurse -Force
    }

    $targetConfigDir = Join-Path $Root 'config'
    Ensure-Directory -Path $targetConfigDir
    $exampleConfigSource = Join-Path $sourceConfigDir 'datasets.example.json'
    $exampleConfigTarget = Join-Path $targetConfigDir 'datasets.example.json'
    if (Test-Path -LiteralPath $exampleConfigSource) {
        Copy-Item -Path $exampleConfigSource -Destination $exampleConfigTarget -Force
    }

    $localConfigTarget = Join-Path $targetConfigDir 'datasets.local.json'
    if (-not (Test-Path -LiteralPath $localConfigTarget)) {
        $localConfigSource = Join-Path $sourceConfigDir 'datasets.local.json'
        if (Test-Path -LiteralPath $localConfigSource) {
            Copy-Item -Path $localConfigSource -Destination $localConfigTarget -Force
        }
        elseif (Test-Path -LiteralPath $exampleConfigSource) {
            Copy-Item -Path $exampleConfigSource -Destination $localConfigTarget -Force
        }
    }

    Write-InstallLog -Stage 'payload' -Event 'App payload, benchmark support scripts, and config templates installed.'
}

function Write-WrapperScripts {
    param([string]$Root)

    $runPs1 = Join-Path $Root 'run360gs.ps1'
    $runCmd = Join-Path $Root 'run360gs.cmd'

    @"
param(
    [Parameter(ValueFromRemainingArguments = `$true)]
    [string[]]`$Args
)

`$runtimePython = Join-Path `$PSScriptRoot 'runtime\python311\python.exe'
`$pipelineEntry = Join-Path `$PSScriptRoot 'app\main.py'

if (-not (Test-Path -LiteralPath `$runtimePython)) {
    Write-Error "Python runtime not found at `$runtimePython"
    exit 2
}

if (-not (Test-Path -LiteralPath `$pipelineEntry)) {
    Write-Warning "Pipeline entrypoint not found at `$pipelineEntry. Installer is valid, but app payload may not yet be installed."
    exit 3
}

& `$runtimePython `$pipelineEntry @Args
exit `$LASTEXITCODE
"@ | Set-Content -Path $runPs1

@" 
@echo off
set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if exist "%PWSH%" (
  "%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0run360gs.ps1" %*
) else (
  %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run360gs.ps1" %*
)
"@ | Set-Content -Path $runCmd
}

function Write-LichtFeldLaunchers {
    param([Parameter(Mandatory = $true)][string]$Root)

    $lichtfeldExe = Join-Path $Root 'packs\lichtfeld-studio\bin\LichtFeld-Studio.exe'
    if (-not (Test-Path -LiteralPath $lichtfeldExe)) {
        return
    }

    $launchPs1 = Join-Path $Root 'openlichtfeld.ps1'
    $launchCmd = Join-Path $Root 'openlichtfeld.cmd'

    @"
param(
    [Parameter(ValueFromRemainingArguments = `$true)]
    [string[]]`$Args
)

`$lichtfeld = Join-Path `$PSScriptRoot 'packs\lichtfeld-studio\bin\LichtFeld-Studio.exe'
if (-not (Test-Path -LiteralPath `$lichtfeld)) {
    Write-Error "LichtFeld Studio executable not found: `$lichtfeld"
    exit 2
}

Start-Process -FilePath `$lichtfeld -ArgumentList `$Args | Out-Null
"@ | Set-Content -Path $launchPs1

@" 
@echo off
set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if exist "%PWSH%" (
  "%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0openlichtfeld.ps1" %*
) else (
  %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0openlichtfeld.ps1" %*
)
"@ | Set-Content -Path $launchCmd

    Write-InstallLog -Stage 'launcher' -Event 'LichtFeld Studio launchers installed.'
}


function Write-StartMenuShortcuts {
    param([Parameter(Mandatory = $true)][string]$Root)

    $launcherCmd = Join-Path $Root 'openlichtfeld.cmd'
    $lichtfeldExe = Join-Path $Root 'packs\lichtfeld-studio\bin\LichtFeld-Studio.exe'
    if (-not (Test-Path -LiteralPath $launcherCmd)) {
        return
    }

    $programsDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    Ensure-Directory -Path $programsDir
    $shortcutPath = Join-Path $programsDir '360GS LichtFeld Studio.lnk'

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $launcherCmd
    $shortcut.WorkingDirectory = $Root
    if (Test-Path -LiteralPath $lichtfeldExe) {
        $shortcut.IconLocation = "$lichtfeldExe,0"
    }
    $shortcut.Description = 'Launch managed LichtFeld Studio from the 360GS runtime'
    $shortcut.Save()

    Write-InstallLog -Stage 'shortcut' -Event 'Start Menu shortcut for LichtFeld Studio installed.'
}try {
    if (-not $AcceptEula) {
        New-InstallError -Message 'You must pass -AcceptEula to run installer automation.' -Code 'EULA_REQUIRED'
    }

    $AddPack = ConvertTo-Array -InputObject $AddPack
    if ($AddPack.Count -eq 0) {
        $AddPack = Get-DefaultPacksForProfile -SelectedProfile $Profile
    }

    $resolvedInstallDir = if ($InstallDir) { $InstallDir } else { Get-DefaultInstallDir -ResolvedMode $Mode }

    $resolvedManifestPath = if ($ManifestPath) { $ManifestPath } else { Join-Path $PSScriptRoot 'install-manifest.lock.json' }
    $resolvedSchemaPath = if ($SchemaPath) { $SchemaPath } else { Join-Path $PSScriptRoot 'install-manifest.lock.schema.json' }

    $resolvedLogDir = if ($LogDir) { $LogDir } else {
        if ($Mode -eq 'standard') {
            Join-Path $env:ProgramData '360GS\logs'
        }
        else {
            Join-Path $resolvedInstallDir 'logs'
        }
    }

    Ensure-Directory -Path $resolvedLogDir
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $global:LogFile = Join-Path $resolvedLogDir "install-$timestamp.jsonl"
    $global:InstallReport = Join-Path $resolvedLogDir "install-report-$timestamp.txt"

    Write-InstallLog -Stage 'init' -Event 'Installer starting'
    Write-InstallReportLine "360GS install report - $((Get-Date).ToString('u'))"
    Write-InstallReportLine "Mode: $Mode"
    Write-InstallReportLine "Profile: $Profile"
    Write-InstallReportLine "InstallDir: $resolvedInstallDir"
    Write-InstallReportLine "ExistingInstallPolicy: $ExistingInstallPolicy"
    Write-InstallReportLine "AddPack: $($AddPack -join ', ')"
    Write-InstallReportLine "Repair: $Repair"
    Write-InstallReportLine "UninstallManaged: $UninstallManaged"
    Write-InstallReportLine "AllowUnverifiedArtifacts: $AllowUnverifiedArtifacts"

    if (-not (Test-Path -LiteralPath $resolvedManifestPath)) {
        New-InstallError -Message "Manifest file not found: $resolvedManifestPath" -Code 'MANIFEST_MISSING'
    }

    if (-not (Test-Path -LiteralPath $resolvedSchemaPath)) {
        Write-InstallLog -Stage 'init' -Event "Schema file not found at $resolvedSchemaPath. Continuing with built-in manifest validation only." -Level 'WARN' -ErrorCode 'SCHEMA_MISSING'
    }

    $preflight = Invoke-Preflight -ResolvedMode $Mode -TargetInstallDir $resolvedInstallDir -SelectedProfile $Profile -BundlePath $OfflineBundle -RequestedPacks $AddPack
    Write-SystemInventoryReport -Inventory $preflight.inventory -RequestedPacks $AddPack
    if ($preflight.compatibility_findings.Count -gt 0) {
        Write-InstallReportLine ''
        Write-InstallReportLine 'Compatibility Assessment'
        foreach ($finding in @($preflight.compatibility_findings)) {
            Write-InstallReportLine $finding.report_line
            if ($finding.remediation) {
                Write-InstallReportLine $finding.remediation
            }
        }
    }

    if ($UninstallManaged) {
        Write-InstallLog -Stage 'uninstall' -Event "Removing managed 360GS artifacts from $resolvedInstallDir"
        Remove-ManagedInstallArtifacts -InstallRoot $resolvedInstallDir
        Write-InstallLog -Stage 'complete' -Event 'Managed uninstall completed successfully.'
        Write-InstallReportLine 'Status: PASS'
        Write-InstallReportLine 'Action: uninstall-managed'
        exit 0
    }

    $manifest = Parse-JsonFileAsHashtable -Path $resolvedManifestPath
    Validate-ManifestContract -Manifest $manifest -SelectedProfile $Profile -RequestedPacks $AddPack

    $selectedArtifacts = Select-Artifacts -Manifest $manifest -SelectedProfile $Profile -RequestedPacks $AddPack
    $selectedArtifacts = ConvertTo-Array -InputObject $selectedArtifacts
    Write-InstallLog -Stage 'plan' -Event "Selected $($selectedArtifacts.Count) artifacts."

    Ensure-Directory -Path $resolvedInstallDir
    $cacheDir = Join-Path $resolvedInstallDir '.cache'
    $stateDir = Join-Path $resolvedInstallDir '.state'
    Ensure-Directory -Path $cacheDir
    Ensure-Directory -Path $stateDir
    Remove-DeprecatedViewerArtifacts -InstallRoot $resolvedInstallDir -WhatIf:$WhatIfInstall

    $statePath = Join-Path $stateDir 'install-state.json'
    $installState = Load-InstallState -StatePath $statePath

    if ($ExistingInstallPolicy -eq 'replace') {
        Write-InstallLog -Stage 'policy' -Event "Existing install policy is 'replace'. Removing managed artifacts in $resolvedInstallDir."
        Remove-ManagedInstallArtifacts -InstallRoot $resolvedInstallDir
        Ensure-Directory -Path $cacheDir
        Ensure-Directory -Path $stateDir
        $installState = @{ completedArtifacts = @() }
    }
    elseif ($Repair) {
        Write-InstallLog -Stage 'policy' -Event "Repair mode enabled. Re-validating managed artifacts and reinstalling selected artifacts."
        $installState = @{ completedArtifacts = @() }
    }
    elseif ($ExistingInstallPolicy -eq 'reuse') {
        Write-InstallLog -Stage 'policy' -Event "Existing install policy is 'reuse'. Installer will keep compatible managed components and install only missing artifacts."
    }
    else {
        Write-InstallLog -Stage 'policy' -Event "Existing install policy is 'upgrade'. Installer will enforce pinned managed artifact versions."
    }

    $bundleExtractRoot = $null
    if ($OfflineBundle) {
        $bundleExtractRoot = Join-Path $cacheDir 'offline-bundle'
        Ensure-Directory -Path $bundleExtractRoot
        if (-not $WhatIfInstall) {
            Write-InstallLog -Stage 'bundle' -Event "Extracting offline bundle $OfflineBundle"
            Expand-Archive -Path $OfflineBundle -DestinationPath $bundleExtractRoot -Force
        }
    }

    foreach ($artifact in $selectedArtifacts) {
        if ($installState.completedArtifacts -contains $artifact.id) {
            Write-InstallLog -Stage 'resume' -Event "Skipping already installed artifact: $($artifact.id)"
            continue
        }

        try {
            $localPath = Resolve-ArtifactToLocalPath -Artifact $artifact -CacheDir $cacheDir -BundleExtractRoot $bundleExtractRoot -Proxy $ProxyUrl -WhatIf:$WhatIfInstall

            if (-not $WhatIfInstall) {
                Test-Sha256 -Path $localPath -ExpectedSha256 $artifact.sha256 -AllowUnverified:$AllowUnverifiedArtifacts
            }

            Install-Artifact -Artifact $artifact -SourceFile $localPath -InstallRoot $resolvedInstallDir -AllowUnverified:$AllowUnverifiedArtifacts -WhatIf:$WhatIfInstall

            if (-not $WhatIfInstall) {
                $installState.completedArtifacts += $artifact.id
                Save-InstallState -StatePath $statePath -State $installState
            }
            Write-InstallLog -Stage 'install' -Event "Completed artifact: $($artifact.id)"
        }
        catch {
            if ($artifact.ContainsKey('optional') -and $artifact.optional) {
                Write-InstallLog -Stage 'install' -Event "Optional artifact failed: $($artifact.id). Error: $($_.Exception.Message)" -Level 'WARN' -ErrorCode 'OPTIONAL_ARTIFACT_FAILED'
                continue
            }

            throw
        }
    }

    $enableSharpPreview = $AddPack -contains 'sharp-preview'
    $enableColmapGlobal = $AddPack -contains 'colmap-global'
    $enableGlomapStandalone = $AddPack -contains 'glomap-standalone'
    $enableLichtFeldStudio = $AddPack -contains 'lichtfeld-studio'
    if ($enableSharpPreview) {
        Install-SharpPreviewPack -InstallRoot $resolvedInstallDir -CacheDir $cacheDir -Proxy $ProxyUrl -AllowUnverified:$AllowUnverifiedArtifacts -WhatIf:$WhatIfInstall -ForceReinstall:$Repair
    }

    Write-AppPayload -Root $resolvedInstallDir -InstallerRoot $PSScriptRoot
    Write-WrapperScripts -Root $resolvedInstallDir
    Write-LichtFeldLaunchers -Root $resolvedInstallDir
    Write-StartMenuShortcuts -Root $resolvedInstallDir

    if (-not $SkipSelfTest -and -not $WhatIfInstall) {
        $selfTestScript = Join-Path $PSScriptRoot 'SelfTest-360GS.ps1'
        if (Test-Path -LiteralPath $selfTestScript) {
            Write-InstallLog -Stage 'selftest' -Event 'Running post-install self-test.'
            $selfTestArgs = @(
                '-InstallRoot', $resolvedInstallDir,
                '-LogPath', $global:LogFile
            )
            if ($enableSharpPreview) {
                $selfTestArgs += '-CheckSharpPreview'
            }
            if ($enableColmapGlobal) {
                $selfTestArgs += '-CheckColmapGlobal'
            }
            if ($enableGlomapStandalone) {
                $selfTestArgs += '-CheckGlomapStandalone'
            }
            if ($enableLichtFeldStudio) {
                $selfTestArgs += '-CheckLichtFeldStudio'
            }
            $argList = @('-ExecutionPolicy', 'Bypass', '-File', $selfTestScript) + $selfTestArgs
            $proc = Start-Process -FilePath (Get-PreferredPowerShellExe) -ArgumentList $argList -Wait -PassThru
            if ($proc.ExitCode -gt 1) {
                New-InstallError -Message "Self-test failed with exit code $($proc.ExitCode)." -Code 'SELFTEST_FAILED'
            }
        }
        else {
            Write-InstallLog -Stage 'selftest' -Event 'Self-test script missing; skipping self-test.' -Level 'WARN' -ErrorCode 'SELFTEST_SCRIPT_MISSING'
        }
    }
    else {
        Write-InstallLog -Stage 'selftest' -Event 'Self-test skipped by request.' -Level 'WARN' -ErrorCode 'SELFTEST_SKIPPED'
    }

    if (-not $WhatIfInstall) {
        Save-ManagedInstallMarker -InstallRoot $resolvedInstallDir -ModeValue $Mode -ProfileValue $Profile
    }

    Write-InstallLog -Stage 'complete' -Event 'Install completed successfully.'
    Write-InstallReportLine 'Status: PASS'
    Write-InstallReportLine "Log: $global:LogFile"
    Write-InstallReportLine "Run launcher: $(Join-Path $resolvedInstallDir 'run360gs.cmd')"

    Write-Host "Install complete. Report: $global:InstallReport"
    exit 0
}
catch {
    if ($global:LogFile) {
        Write-InstallLog -Stage 'fatal' -Event $_.Exception.Message -Level 'ERROR' -ErrorCode 'INSTALL_ABORTED'
    }

    if ($global:InstallReport) {
        Write-InstallReportLine "Status: FAIL"
        Write-InstallReportLine "Error: $($_.Exception.Message)"
    }

    Write-Error $_.Exception.Message
    exit 1
}

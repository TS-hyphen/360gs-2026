Set-StrictMode -Version Latest

function Resolve-360GSProjectRoot {
    param([Parameter(Mandatory = $true)][string]$ScriptPath)

    $scriptDir = Split-Path -Parent $ScriptPath
    $projectRoot = Split-Path -Parent $scriptDir
    return (Resolve-Path -LiteralPath $projectRoot).Path
}

function Get-360GSDefaultInstallRoot {
    return Join-Path $env:LOCALAPPDATA '360GS'
}

function Resolve-360GSToolsRoot {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $candidates = @(
        (Join-Path $ProjectRoot 'tools'),
        (Join-Path (Get-360GSDefaultInstallRoot) 'tools')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    throw "360GS tools root not found. Checked: $($candidates -join ', ')"
}

function Find-360GSManagedTool {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$ExecutableName
    )

    $toolsRoot = Resolve-360GSToolsRoot -ProjectRoot $ProjectRoot
    $match = Get-ChildItem -Path $toolsRoot -Recurse -Filter $ExecutableName -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $match) {
        throw "Managed tool not found: $ExecutableName"
    }

    return $match.FullName
}

function Get-360GSFFmpegExe {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    return Find-360GSManagedTool -ProjectRoot $ProjectRoot -ExecutableName 'ffmpeg.exe'
}

function Get-360GSFFprobeExe {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    return Find-360GSManagedTool -ProjectRoot $ProjectRoot -ExecutableName 'ffprobe.exe'
}

function Get-360GSPythonExe {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $candidates = @(
        (Join-Path $ProjectRoot 'runtime\python311\python.exe'),
        (Join-Path (Get-360GSDefaultInstallRoot) 'runtime\python311\python.exe')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    throw "Managed Python runtime not found. Checked: $($candidates -join ', ')"
}

function Get-360GSPreferredPowerShellExe {
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
        throw 'No supported PowerShell executable was found for 360GS runtime operations.'
    }

    return $resolved[0]
}

function Get-360GSWindowsPlatformInfo {
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
        preferred_shell = Get-360GSPreferredPowerShellExe
        is_supported = ($family -ne 'unsupported')
    }
}

function Get-360GSPreferredBenchmarkArtifactsRoot {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    return Join-Path (Join-Path $ProjectRoot 'artifacts') 'benchmark'
}

function Get-360GSPreferredBenchmarkPath {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$ChildPath
    )

    return Join-Path (Get-360GSPreferredBenchmarkArtifactsRoot -ProjectRoot $ProjectRoot) $ChildPath
}

function Resolve-360GSExistingBenchmarkPath {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$ChildPath
    )

    $preferred = Get-360GSPreferredBenchmarkPath -ProjectRoot $ProjectRoot -ChildPath $ChildPath
    if (Test-Path -LiteralPath $preferred) {
        return $preferred
    }

    $legacy = Join-Path (Join-Path $ProjectRoot 'benchmark') $ChildPath
    if (Test-Path -LiteralPath $legacy) {
        return $legacy
    }

    return $preferred
}

function Resolve-360GSDatasetRegistryPath {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [string]$RequestedPath
    )

    if ($RequestedPath) {
        return $RequestedPath
    }

    $candidates = @(
        (Join-Path $ProjectRoot 'config\datasets.local.json'),
        (Join-Path $ProjectRoot 'config\datasets.example.json'),
        (Join-Path $ProjectRoot 'benchmark\datasets.standard.json')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    throw "Dataset registry not found. Checked: $($candidates -join ', ')"
}

function Resolve-360GSRegistryLocalPath {
    param(
        [string]$Value,
        [Parameter(Mandatory = $true)][string]$RegistryPath
    )

    # Relative dataset paths resolve against the project/install root (the parent of config\ or benchmark\).
    if (-not $Value) {
        return ''
    }
    if ([System.IO.Path]::IsPathRooted($Value)) {
        return $Value
    }
    $registryDir = Split-Path -Parent (Resolve-Path -LiteralPath $RegistryPath).Path
    $rootDir = Split-Path -Parent $registryDir
    return [System.IO.Path]::GetFullPath((Join-Path $rootDir $Value))
}

function Ensure-360GSDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Read-360GSJsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    return Get-Content -Raw -Path $Path | ConvertFrom-Json
}

function Save-360GSJsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $Value | ConvertTo-Json -Depth 10 | Set-Content -Path $Path
}

function Get-360GSOrCreateState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Backend,
        [Parameter(Mandatory = $true)][string]$ResolvedRunRoot
    )

    if (Test-Path -LiteralPath $Path) {
        return Read-360GSJsonFile -Path $Path
    }

    $state = [ordered]@{
        backend = $Backend
        run_root = $ResolvedRunRoot
        created_at = (Get-Date).ToString('o')
        updated_at = (Get-Date).ToString('o')
        completed_stages = @()
        stage_results = @{}
    }
    Save-360GSJsonFile -Path $Path -Value $state
    return Read-360GSJsonFile -Path $Path
}

function Save-360GSState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$State
    )

    $State.updated_at = (Get-Date).ToString('o')
    Save-360GSJsonFile -Path $Path -Value $State
}

function Invoke-360GSStageWithResume {
    param(
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$StageName,
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [switch]$ResumeEnabled
    )

    $completed = @($State.completed_stages)
    if ($ResumeEnabled -and ($completed -contains $StageName) -and $State.stage_results.PSObject.Properties.Name -contains $StageName) {
        return $State.stage_results.$StageName
    }

    $result = & $Action

    $completedList = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($State.completed_stages)) {
        [void]$completedList.Add([string]$item)
    }
    if (-not $completedList.Contains($StageName)) {
        [void]$completedList.Add($StageName)
    }
    $State.completed_stages = @($completedList.ToArray())
    $State.stage_results | Add-Member -NotePropertyName $StageName -NotePropertyValue $result -Force
    Save-360GSState -Path $StatePath -State $State
    return $result
}

function Invoke-360GSLoggedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$ExePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$LogPath,
        [Parameter(Mandatory = $true)][string]$StageName,
        [string]$FailurePrefix = 'Stage'
    )

    $start = Get-Date
    "COMMAND: `"$ExePath`" $($Arguments -join ' ')" | Set-Content -Path $LogPath

    $stdoutPath = "$LogPath.stdout.tmp"
    $stderrPath = "$LogPath.stderr.tmp"
    if (Test-Path -LiteralPath $stdoutPath) { Remove-Item -Path $stdoutPath -Force }
    if (Test-Path -LiteralPath $stderrPath) { Remove-Item -Path $stderrPath -Force }

    $proc = Start-Process -FilePath $ExePath -ArgumentList $Arguments -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -Wait -PassThru -NoNewWindow
    $exitCode = $proc.ExitCode
    $end = Get-Date

    if (Test-Path -LiteralPath $stdoutPath) {
        Add-Content -Path $LogPath -Value (Get-Content -Raw -Path $stdoutPath)
        Remove-Item -Path $stdoutPath -Force
    }
    if (Test-Path -LiteralPath $stderrPath) {
        Add-Content -Path $LogPath -Value (Get-Content -Raw -Path $stderrPath)
        Remove-Item -Path $stderrPath -Force
    }

    if ($exitCode -ne 0) {
        throw "$FailurePrefix '$StageName' failed with exit code $exitCode. See log: $LogPath"
    }

    return [ordered]@{
        stage = $StageName
        started_at = $start.ToString('o')
        completed_at = $end.ToString('o')
        duration_seconds = [Math]::Round(($end - $start).TotalSeconds, 2)
        log_path = $LogPath
        exit_code = $exitCode
    }
}

function Find-360GSLatestNumberedFile {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)][string]$Extension
    )

    if (-not (Test-Path -LiteralPath $Directory)) {
        return $null
    }

    $cleanExtension = $Extension.TrimStart('.')
    $pattern = "{0}_*.{1}" -f $Prefix, $cleanExtension
    $regex = '^{0}_(\d+)$' -f [regex]::Escape($Prefix)
    $items = @(Get-ChildItem -Path $Directory -Filter $pattern -File -ErrorAction SilentlyContinue | ForEach-Object {
        $iteration = -1
        if ($_.BaseName -match $regex) {
            $iteration = [int]$Matches[1]
        }
        [pscustomobject]@{
            iteration = $iteration
            path = $_.FullName
            last_write_time = $_.LastWriteTime
        }
    })

    if ($items.Count -eq 0) {
        return $null
    }

    return ($items | Sort-Object iteration, last_write_time -Descending | Select-Object -First 1)
}

function Get-360GSFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Test-Path -LiteralPath $Path) {
        return [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Path).Path)
    }

    return [System.IO.Path]::GetFullPath($Path)
}

function Assert-360GSChildPath {
    param(
        [Parameter(Mandatory = $true)][string]$ChildPath,
        [Parameter(Mandatory = $true)][string]$ParentPath,
        [string]$Label = 'path'
    )

    $resolvedParent = Get-360GSFullPath -Path $ParentPath
    $resolvedChild = Get-360GSFullPath -Path $ChildPath
    $requiredPrefix = $resolvedParent.TrimEnd('\') + '\'

    if ($resolvedChild -ne $resolvedParent -and -not $resolvedChild.StartsWith($requiredPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must stay under $resolvedParent. Resolved path: $resolvedChild"
    }
}

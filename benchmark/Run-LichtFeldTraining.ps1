[CmdletBinding()]
param(
    [string]$PreparedDatasetPath,

    [string]$StagedDatasetPath,

    [string]$SparseModelPath,

    [string]$InstallRoot,

    [string]$RunRoot,

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

    [switch]$Undistort,

    [switch]$Resume,

    [switch]$EnableLowMemoryFallback = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'lib\Benchmark.Common.ps1')
$projectRoot = Resolve-360GSProjectRoot -ScriptPath $MyInvocation.MyCommand.Path
if (-not $InstallRoot) {
    $InstallRoot = Get-360GSDefaultInstallRoot
}

function Resolve-LichtFeldExe {
    param([string]$Root)

    $exe = Join-Path $Root 'packs\lichtfeld-studio\bin\LichtFeld-Studio.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        throw "Managed LichtFeld Studio executable not found: $exe"
    }

    return $exe
}

function Find-LatestCheckpoint {
    param([string]$OutputPath)

    return Find-360GSLatestNumberedFile -Directory (Join-Path $OutputPath 'checkpoints') -Prefix 'checkpoint' -Extension '.resume'
}

function Find-LatestSplat {
    param([string]$OutputPath)

    return Find-360GSLatestNumberedFile -Directory $OutputPath -Prefix 'splat' -Extension '.ply'
}

function Test-LichtFeldGpuMemoryFailure {
    param([string]$LogPath)

    if (-not (Test-Path -LiteralPath $LogPath)) {
        return $false
    }

    $content = Get-Content -Raw -Path $LogPath -ErrorAction SilentlyContinue
    if (-not $content) {
        return $false
    }

    return ($content -match 'Insufficient GPU memory for arena initialization')
}

function Update-LowMemoryFallbackState {
    param(
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][bool]$Enabled,
        [Parameter(Mandatory = $true)][bool]$Active,
        [Parameter(Mandatory = $true)][bool]$Used,
        [Parameter(Mandatory = $true)][bool]$CompletedWithFallback,
        [Parameter(Mandatory = $true)][int]$CurrentTileMode,
        [string]$Message,
        [object[]]$Attempts = @()
    )

    $fallback = [ordered]@{
        enabled = $Enabled
        active = $Active
        used = $Used
        completed_with_fallback = $CompletedWithFallback
        current_tile_mode = $CurrentTileMode
        message = $Message
        attempts = @($Attempts)
    }

    if ($State.PSObject.Properties.Name -contains 'memory_fallback') {
        $State.memory_fallback = $fallback
    }
    else {
        $State | Add-Member -NotePropertyName 'memory_fallback' -NotePropertyValue $fallback -Force
    }

    Save-360GSState -Path $StatePath -State $State
}

function Add-CombinedAttemptLog {
    param(
        [Parameter(Mandatory = $true)][string]$CombinedLogPath,
        [Parameter(Mandatory = $true)][int]$AttemptIndex,
        [Parameter(Mandatory = $true)][int]$TileMode,
        [Parameter(Mandatory = $true)][string]$AttemptLogPath
    )

    $header = @(
        '',
        ('=' * 72),
        "ATTEMPT $AttemptIndex | tile-mode=$TileMode",
        ('=' * 72),
        ''
    )
    Add-Content -Path $CombinedLogPath -Value $header
    if (Test-Path -LiteralPath $AttemptLogPath) {
        Add-Content -Path $CombinedLogPath -Value (Get-Content -Raw -Path $AttemptLogPath)
    }
}

if (-not $RunRoot) {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $resultsRoot = Get-360GSPreferredBenchmarkPath -ProjectRoot $projectRoot -ChildPath 'results'
    $RunRoot = Join-Path $resultsRoot ("lichtfeld_{0}" -f $timestamp)
}

Ensure-360GSDirectory -Path $RunRoot
$logsRoot = Join-Path $RunRoot 'logs'
$datasetRoot = if ($PreparedDatasetPath) { $PreparedDatasetPath } else { Join-Path $RunRoot 'dataset' }
$outputPath = Join-Path $RunRoot 'training_output'
$statePath = Join-Path $RunRoot 'train_state.json'
$reportPath = Join-Path $RunRoot 'training_report.json'
Ensure-360GSDirectory -Path $logsRoot
Ensure-360GSDirectory -Path $outputPath

$state = Get-360GSOrCreateState -Path $statePath -Backend 'lichtfeld-studio' -ResolvedRunRoot $RunRoot
$lichtfeldExe = Resolve-LichtFeldExe -Root $InstallRoot
Update-LowMemoryFallbackState -StatePath $statePath -State $state -Enabled ([bool]$EnableLowMemoryFallback) -Active $false -Used $false -CompletedWithFallback $false -CurrentTileMode 1 -Message '' -Attempts @()

if (-not $PreparedDatasetPath) {
    if (-not $StagedDatasetPath) { throw 'Provide either -PreparedDatasetPath or -StagedDatasetPath.' }
    if (-not $SparseModelPath) { throw 'Provide -SparseModelPath when using -StagedDatasetPath.' }

    $prepRunner = Join-Path $scriptDir 'Prepare-LichtFeldDataset.ps1'
    if (-not (Test-Path -LiteralPath $prepRunner)) {
        throw "Prep script not found: $prepRunner"
    }

    Invoke-360GSStageWithResume -StatePath $statePath -State $state -StageName 'prepare_dataset' -ResumeEnabled:$Resume -Action {
        $prepLog = Join-Path $logsRoot 'prepare_dataset.log'
        $prepArgs = @(
            '-ExecutionPolicy', 'Bypass',
            '-File', $prepRunner,
            '-StagedDatasetPath', $StagedDatasetPath,
            '-SparseModelPath', $SparseModelPath,
            '-OutputRoot', $datasetRoot,
            '-ImagesFolderName', $ImagesFolderName,
            '-ImagesMode', $ImagesMode,
            '-Force'
        )
        Invoke-360GSLoggedProcess -ExePath (Get-360GSPreferredPowerShellExe) -Arguments $prepArgs -LogPath $prepLog -StageName 'prepare_dataset'
    } | Out-Null
}

$latestCheckpoint = Find-LatestCheckpoint -OutputPath $outputPath
$trainLog = Join-Path $logsRoot 'train.log'
if (Test-Path -LiteralPath $trainLog) {
    Remove-Item -Path $trainLog -Force
}
$trainResult = Invoke-360GSStageWithResume -StatePath $statePath -State $state -StageName 'train' -ResumeEnabled:$Resume -Action {
    $attemptSpecs = @(
        [ordered]@{
            tile_mode = 1
            mode_label = 'standard'
            retry_label = 'Standard mode'
            is_fallback = $false
        }
    )
    if ($EnableLowMemoryFallback) {
        $attemptSpecs += @(
            [ordered]@{
                tile_mode = 2
                mode_label = 'low-memory 2x2'
                retry_label = 'Lower-memory tile mode (2x2)'
                is_fallback = $true
            },
            [ordered]@{
                tile_mode = 4
                mode_label = 'low-memory 4x4'
                retry_label = 'Lower-memory tile mode (4x4)'
                is_fallback = $true
            }
        )
    }

    $attemptHistory = [System.Collections.Generic.List[object]]::new()
    for ($attemptIndex = 0; $attemptIndex -lt $attemptSpecs.Count; $attemptIndex++) {
        $spec = $attemptSpecs[$attemptIndex]
        $tileMode = [int]$spec.tile_mode
        $attemptNumber = $attemptIndex + 1
        $attemptLog = Join-Path $logsRoot ("train-attempt-{0:00}-tile{1}.log" -f $attemptNumber, $tileMode)

        $fallbackMessage = if ($spec.is_fallback) {
            "Low-memory fallback active: retrying LichtFeld with tile mode $tileMode. This can run slower and may slightly change result quality."
        }
        else {
            ''
        }
        Update-LowMemoryFallbackState -StatePath $statePath -State $state -Enabled ([bool]$EnableLowMemoryFallback) -Active ([bool]$spec.is_fallback) -Used ([bool]($attemptHistory.Count -gt 0)) -CompletedWithFallback $false -CurrentTileMode $tileMode -Message $fallbackMessage -Attempts @($attemptHistory.ToArray())

        $args = @('--output-path', $outputPath, '--iter', [string]$Iterations, '--strategy', $Strategy, '--images', $ImagesFolderName, '--headless', '--train', '--no-splash', '--log-level', 'info', '--undistort')

        if ($tileMode -gt 1) {
            $args += @('--tile-mode', [string]$tileMode)
        }
        if ($ConfigPath) {
            $args += @('--config', $ConfigPath)
        }
        if ($Eval) {
            $args += '--eval'
        }
        if ($SaveEvalImages) {
            $args += '--save-eval-images'
        }
        if ($EnableMip) {
            $args += '--enable-mip'
        }
        $resumeCheckpoint = if ($Resume) { Find-LatestCheckpoint -OutputPath $outputPath } else { $null }
        if ($resumeCheckpoint) {
            $args = @('--resume', $resumeCheckpoint.path) + $args
        }
        else {
            $args = @('--data-path', $datasetRoot) + $args
        }

        $attemptStart = Get-Date
        try {
            $attemptResult = Invoke-360GSLoggedProcess -ExePath $lichtfeldExe -Arguments $args -LogPath $attemptLog -StageName 'train'
            Add-CombinedAttemptLog -CombinedLogPath $trainLog -AttemptIndex $attemptNumber -TileMode $tileMode -AttemptLogPath $attemptLog

            [void]$attemptHistory.Add([pscustomobject]@{
                attempt_index = $attemptNumber
                tile_mode = $tileMode
                mode_label = $spec.mode_label
                status = 'completed'
                log_path = $attemptLog
                started_at = $attemptStart.ToString('o')
                completed_at = (Get-Date).ToString('o')
            })

            Update-LowMemoryFallbackState -StatePath $statePath -State $state -Enabled ([bool]$EnableLowMemoryFallback) -Active $false -Used ([bool]($attemptHistory.Count -gt 1 -or $spec.is_fallback)) -CompletedWithFallback ([bool]$spec.is_fallback) -CurrentTileMode $tileMode -Message $fallbackMessage -Attempts @($attemptHistory.ToArray())

            $attemptResult['tile_mode'] = $tileMode
            $attemptResult['low_memory_fallback_used'] = [bool]$spec.is_fallback
            $attemptResult['fallback_attempt_count'] = $attemptHistory.Count
            return $attemptResult
        }
        catch {
            Add-CombinedAttemptLog -CombinedLogPath $trainLog -AttemptIndex $attemptNumber -TileMode $tileMode -AttemptLogPath $attemptLog

            $failedForLowMemory = Test-LichtFeldGpuMemoryFailure -LogPath $attemptLog
            [void]$attemptHistory.Add([pscustomobject]@{
                attempt_index = $attemptNumber
                tile_mode = $tileMode
                mode_label = $spec.mode_label
                status = if ($failedForLowMemory) { 'failed-low-memory' } else { 'failed' }
                log_path = $attemptLog
                started_at = $attemptStart.ToString('o')
                completed_at = (Get-Date).ToString('o')
                error = $_.Exception.Message
            })

            $nextSpec = if (($attemptIndex + 1) -lt $attemptSpecs.Count) { $attemptSpecs[$attemptIndex + 1] } else { $null }
            if ($failedForLowMemory -and $nextSpec) {
                $nextTileMode = [int]$nextSpec.tile_mode
                Update-LowMemoryFallbackState -StatePath $statePath -State $state -Enabled ([bool]$EnableLowMemoryFallback) -Active $true -Used $true -CompletedWithFallback $false -CurrentTileMode $nextTileMode -Message "GPU memory was exhausted. Retrying with lower-memory tile mode $nextTileMode. This can run slower and may slightly change result quality." -Attempts @($attemptHistory.ToArray())
                continue
            }

            Update-LowMemoryFallbackState -StatePath $statePath -State $state -Enabled ([bool]$EnableLowMemoryFallback) -Active $false -Used ([bool]($attemptHistory.Count -gt 1)) -CompletedWithFallback $false -CurrentTileMode $tileMode -Message '' -Attempts @($attemptHistory.ToArray())
            throw
        }
    }
}

$latestCheckpoint = Find-LatestCheckpoint -OutputPath $outputPath
$latestSplat = Find-LatestSplat -OutputPath $outputPath
$metricsPath = Join-Path $outputPath 'metrics.csv'
$report = [ordered]@{
    backend = 'lichtfeld-studio'
    generated_at = (Get-Date).ToString('o')
    run_root = $RunRoot
    dataset_root = $datasetRoot
    training_output_path = $outputPath
    prepared_dataset_path = $datasetRoot
    staged_dataset_path = $StagedDatasetPath
    sparse_model_path = $SparseModelPath
    images_folder_name = $ImagesFolderName
    images_mode = $ImagesMode
    strategy = $Strategy
    iterations_requested = $Iterations
    eval_enabled = [bool]$Eval
    latest_checkpoint = if ($latestCheckpoint) { $latestCheckpoint.path } else { $null }
    latest_checkpoint_iteration = if ($latestCheckpoint) { $latestCheckpoint.iteration } else { $null }
    latest_splat = if ($latestSplat) { $latestSplat.path } else { $null }
    latest_splat_iteration = if ($latestSplat) { $latestSplat.iteration } else { $null }
    metrics_csv = if (Test-Path -LiteralPath $metricsPath) { $metricsPath } else { $null }
    completed_stages = @($state.completed_stages)
    train_stage = $trainResult
    low_memory_fallback = $state.memory_fallback
}
Save-360GSJsonFile -Path $reportPath -Value $report

Write-Host 'LichtFeld training run completed.'
Write-Host "Run root: $RunRoot"
Write-Host "Training output: $outputPath"
if ($latestSplat) {
    Write-Host "Latest splat: $($latestSplat.path)"
}
if ($latestCheckpoint) {
    Write-Host "Latest checkpoint: $($latestCheckpoint.path)"
}
Write-Host "Training report: $reportPath"

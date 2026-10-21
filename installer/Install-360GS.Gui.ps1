[CmdletBinding()]
param(
    [string]$InitialInstallDir,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Get-PreferredPowerShellExe {
    $pwsh = Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pwsh -and $pwsh.Source) {
        return $pwsh.Source
    }

    $pwshFallback = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (Test-Path -LiteralPath $pwshFallback) {
        return $pwshFallback
    }

    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $windowsPowerShell) {
        return $windowsPowerShell
    }

    throw 'No supported PowerShell executable was found.'
}

function Get-DefaultInstallDir {
    return Join-Path $env:LOCALAPPDATA '360GS'
}

function Resolve-InitialInstallDir {
    param([string]$RequestedPath)

    if ($RequestedPath) {
        return [System.IO.Path]::GetFullPath($RequestedPath)
    }

    return [System.IO.Path]::GetFullPath((Get-DefaultInstallDir))
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-NewContentLines {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ref]$SeenCount
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    $allLines = @(Get-Content -Path $Path -ErrorAction SilentlyContinue)
    if ($SeenCount.Value -ge $allLines.Count) {
        return @()
    }

    $start = [int]$SeenCount.Value
    $SeenCount.Value = $allLines.Count
    return @($allLines[$start..($allLines.Count - 1)])
}

function Get-FileText {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return ''
    }

    return [System.IO.File]::ReadAllText($Path)
}

function Get-InstallerCompletionResult {
    param(
        [Parameter(Mandatory = $true)]$Process,
        [Parameter(Mandatory = $true)][string]$StdoutPath,
        [Parameter(Mandatory = $true)][string]$StderrPath,
        [Parameter(Mandatory = $true)][string]$InstallDir
    )

    try {
        $null = $Process.WaitForExit(2000)
        $Process.Refresh()
    }
    catch {
    }

    $exitCode = $null
    try {
        $rawExitCode = $Process.ExitCode
        if ($null -ne $rawExitCode -and "$rawExitCode" -ne '') {
            $exitCode = [int]$rawExitCode
        }
    }
    catch {
    }

    $stdoutText = Get-FileText -Path $StdoutPath
    $stderrText = Get-FileText -Path $StderrPath
    $combinedOutput = @($stdoutText, $stderrText) -join [Environment]::NewLine

    $successMarker =
        $combinedOutput.Contains('Install completed successfully.') -or
        $combinedOutput.Contains('Install complete. Report:')
    $alreadyCurrentMarker =
        $combinedOutput.Contains('Skipping already installed') -or
        $combinedOutput.Contains('No updates were needed')
    $launcherPath = Join-Path $InstallDir 'run360gs.cmd'
    $launcherReady = Test-Path -LiteralPath $launcherPath

    $succeeded = (($null -ne $exitCode) -and ($exitCode -eq 0)) -or ($successMarker -and $launcherReady)
    $statusText = if ($succeeded -and $alreadyCurrentMarker) {
        '360GS is already installed and ready. No updates were needed.'
    }
    elseif ($succeeded) {
        'Install complete. 360GS is ready.'
    }
    elseif ($null -ne $exitCode) {
        "Install failed with exit code $exitCode."
    }
    else {
        'Install did not finish cleanly. Review the installer updates for details.'
    }

    return [pscustomobject]@{
        Succeeded = $succeeded
        ExitCode = $exitCode
        StatusText = $statusText
        AlreadyCurrent = ($succeeded -and $alreadyCurrentMarker)
        LauncherPath = $launcherPath
    }
}

$installerRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$installScript = Join-Path $installerRoot 'Install-360GS.ps1'
$preferredShell = Get-PreferredPowerShellExe

if ($SelfTest) {
    $result = [ordered]@{
        ok = (Test-Path -LiteralPath $installScript)
        gui_script = $MyInvocation.MyCommand.Path
        installer_script = $installScript
        installer_script_exists = (Test-Path -LiteralPath $installScript)
        preferred_shell = $preferredShell
        default_install_dir = Resolve-InitialInstallDir -RequestedPath $InitialInstallDir
        winforms_loaded = $true
    }
    $result | ConvertTo-Json -Depth 6
    exit $(if ($result.ok) { 0 } else { 2 })
}

if (-not (Test-Path -LiteralPath $installScript)) {
    [System.Windows.Forms.MessageBox]::Show(
        "Installer script not found: $installScript",
        '360GS Installer',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    exit 2
}

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:installProcess = $null
$script:installRunning = $false
$script:installSucceeded = $false
$script:stdoutPath = ''
$script:stderrPath = ''
$script:stdoutSeenCount = 0
$script:stderrSeenCount = 0
$script:selectedInstallDir = Resolve-InitialInstallDir -RequestedPath $InitialInstallDir

$form = New-Object System.Windows.Forms.Form
$form.Text = '360GS Installer'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(760, 520)
$form.MinimumSize = New-Object System.Drawing.Size(760, 520)
$form.MaximizeBox = $false

$introLabel = New-Object System.Windows.Forms.Label
$introLabel.Location = New-Object System.Drawing.Point(18, 16)
$introLabel.Size = New-Object System.Drawing.Size(700, 42)
$introLabel.Text = 'Choose where 360GS should be installed, then click Install. The default install includes the full operator tool bundle for staging, sparse reconstruction, and LichtFeld training.'
$introLabel.AutoSize = $false

$folderLabel = New-Object System.Windows.Forms.Label
$folderLabel.Location = New-Object System.Drawing.Point(18, 72)
$folderLabel.Size = New-Object System.Drawing.Size(200, 20)
$folderLabel.Text = 'Installation Folder'

$folderTextBox = New-Object System.Windows.Forms.TextBox
$folderTextBox.Location = New-Object System.Drawing.Point(18, 96)
$folderTextBox.Size = New-Object System.Drawing.Size(590, 24)
$folderTextBox.Text = $script:selectedInstallDir

$browseButton = New-Object System.Windows.Forms.Button
$browseButton.Location = New-Object System.Drawing.Point(620, 94)
$browseButton.Size = New-Object System.Drawing.Size(100, 28)
$browseButton.Text = 'Browse...'

$statusCaption = New-Object System.Windows.Forms.Label
$statusCaption.Location = New-Object System.Drawing.Point(18, 140)
$statusCaption.Size = New-Object System.Drawing.Size(200, 20)
$statusCaption.Text = 'Current Status'

$statusLine = New-Object System.Windows.Forms.TextBox
$statusLine.Location = New-Object System.Drawing.Point(18, 164)
$statusLine.Size = New-Object System.Drawing.Size(702, 24)
$statusLine.ReadOnly = $true
$statusLine.Text = 'Select an installation folder, then click Install.'

$detailCaption = New-Object System.Windows.Forms.Label
$detailCaption.Location = New-Object System.Drawing.Point(18, 206)
$detailCaption.Size = New-Object System.Drawing.Size(200, 20)
$detailCaption.Text = 'Installer Updates'

$detailBox = New-Object System.Windows.Forms.TextBox
$detailBox.Location = New-Object System.Drawing.Point(18, 230)
$detailBox.Size = New-Object System.Drawing.Size(702, 190)
$detailBox.Multiline = $true
$detailBox.ScrollBars = 'Vertical'
$detailBox.ReadOnly = $true
$detailBox.WordWrap = $true

$installButton = New-Object System.Windows.Forms.Button
$installButton.Location = New-Object System.Drawing.Point(18, 438)
$installButton.Size = New-Object System.Drawing.Size(150, 32)
$installButton.Text = 'Install 360GS'

$launchButton = New-Object System.Windows.Forms.Button
$launchButton.Location = New-Object System.Drawing.Point(180, 438)
$launchButton.Size = New-Object System.Drawing.Size(150, 32)
$launchButton.Text = 'Launch 360GS'
$launchButton.Enabled = $false

$openFolderButton = New-Object System.Windows.Forms.Button
$openFolderButton.Location = New-Object System.Drawing.Point(342, 438)
$openFolderButton.Size = New-Object System.Drawing.Size(170, 32)
$openFolderButton.Text = 'Open Install Folder'
$openFolderButton.Enabled = $false

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Location = New-Object System.Drawing.Point(570, 438)
$closeButton.Size = New-Object System.Drawing.Size(150, 32)
$closeButton.Text = 'Close'

$form.Controls.AddRange(@(
    $introLabel,
    $folderLabel,
    $folderTextBox,
    $browseButton,
    $statusCaption,
    $statusLine,
    $detailCaption,
    $detailBox,
    $installButton,
    $launchButton,
    $openFolderButton,
    $closeButton
))

function Append-InstallerLine {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [switch]$IsError
    )

    $line = $Text.Trim()
    if (-not $line) {
        return
    }

    $statusLine.Text = $line
    if ($IsError) {
        $detailBox.AppendText("[ERROR] $line$([Environment]::NewLine)")
    }
    else {
        $detailBox.AppendText("$line$([Environment]::NewLine)")
    }
    $detailBox.SelectionStart = $detailBox.TextLength
    $detailBox.ScrollToCaret()
}

function Set-InstallerUiState {
    param([ValidateSet('ready', 'installing', 'success', 'failure')][string]$State)

    switch ($State) {
        'ready' {
            $folderTextBox.ReadOnly = $false
            $browseButton.Enabled = $true
            $installButton.Enabled = $true
            $launchButton.Enabled = $false
            $openFolderButton.Enabled = Test-Path -LiteralPath $folderTextBox.Text
        }
        'installing' {
            $folderTextBox.ReadOnly = $true
            $browseButton.Enabled = $false
            $installButton.Enabled = $false
            $launchButton.Enabled = $false
            $openFolderButton.Enabled = $false
        }
        'success' {
            $folderTextBox.ReadOnly = $true
            $browseButton.Enabled = $false
            $installButton.Enabled = $false
            $launchButton.Enabled = $true
            $openFolderButton.Enabled = $true
        }
        'failure' {
            $folderTextBox.ReadOnly = $false
            $browseButton.Enabled = $true
            $installButton.Enabled = $true
            $launchButton.Enabled = $false
            $openFolderButton.Enabled = Test-Path -LiteralPath $folderTextBox.Text
        }
    }
}

function Start-InstallerProcess {
    $chosenDir = $folderTextBox.Text.Trim()
    if (-not $chosenDir) {
        [System.Windows.Forms.MessageBox]::Show(
            'Choose an installation folder first.',
            '360GS Installer',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    $resolvedInstallDir = [System.IO.Path]::GetFullPath($chosenDir)
    $sourceProjectRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $installerRoot))
    if ($resolvedInstallDir.TrimEnd('\') -eq $sourceProjectRoot.TrimEnd('\')) {
        [System.Windows.Forms.MessageBox]::Show(
            'Choose a different folder than the 360GS installer package folder. Installing into the package source folder is not supported.',
            '360GS Installer',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    $script:selectedInstallDir = $resolvedInstallDir
    $folderTextBox.Text = $resolvedInstallDir
    $detailBox.Clear()
    Append-InstallerLine -Text "Starting install into $resolvedInstallDir"
    Append-InstallerLine -Text 'This can take a little time while files are downloaded, installed, and validated.'

    $logDir = Join-Path $env:TEMP ("360GS-installer-gui-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Ensure-Directory -Path $logDir
    $script:stdoutPath = Join-Path $logDir 'stdout.log'
    $script:stderrPath = Join-Path $logDir 'stderr.log'
    $script:stdoutSeenCount = 0
    $script:stderrSeenCount = 0

    $argList = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $installScript,
        '-Mode', 'portable',
        '-Profile', 'research-full',
        '-ExistingInstallPolicy', 'upgrade',
        '-AcceptEula',
        '-InstallDir', $resolvedInstallDir
    )

    $script:installProcess = Start-Process -FilePath $preferredShell -ArgumentList $argList -RedirectStandardOutput $script:stdoutPath -RedirectStandardError $script:stderrPath -PassThru -WindowStyle Hidden
    $script:installRunning = $true
    $script:installSucceeded = $false
    Set-InstallerUiState -State 'installing'
    $pollTimer.Start()
}

$pollTimer = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = 750
$pollTimer.Add_Tick({
    foreach ($line in @(Get-NewContentLines -Path $script:stdoutPath -SeenCount ([ref]$script:stdoutSeenCount))) {
        Append-InstallerLine -Text ([string]$line)
    }
    foreach ($line in @(Get-NewContentLines -Path $script:stderrPath -SeenCount ([ref]$script:stderrSeenCount))) {
        Append-InstallerLine -Text ([string]$line) -IsError
    }

    if ($script:installProcess -and $script:installProcess.HasExited) {
        $pollTimer.Stop()
        $script:installRunning = $false

        foreach ($line in @(Get-NewContentLines -Path $script:stdoutPath -SeenCount ([ref]$script:stdoutSeenCount))) {
            Append-InstallerLine -Text ([string]$line)
        }
        foreach ($line in @(Get-NewContentLines -Path $script:stderrPath -SeenCount ([ref]$script:stderrSeenCount))) {
            Append-InstallerLine -Text ([string]$line) -IsError
        }

        $completion = Get-InstallerCompletionResult -Process $script:installProcess -StdoutPath $script:stdoutPath -StderrPath $script:stderrPath -InstallDir $script:selectedInstallDir

        if ($completion.Succeeded) {
            $script:installSucceeded = $true
            $statusLine.Text = $completion.StatusText
            Append-InstallerLine -Text $completion.StatusText
            Append-InstallerLine -Text "Launch 360GS from $($completion.LauncherPath)"
            Set-InstallerUiState -State 'success'
        }
        else {
            $statusLine.Text = $completion.StatusText
            Append-InstallerLine -Text $completion.StatusText -IsError
            Set-InstallerUiState -State 'failure'
        }
    }
})

$browseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Choose the folder where 360GS should be installed.'
    $dialog.ShowNewFolderButton = $true
    $dialog.SelectedPath = $folderTextBox.Text
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $folderTextBox.Text = [System.IO.Path]::GetFullPath($dialog.SelectedPath)
        $openFolderButton.Enabled = Test-Path -LiteralPath $folderTextBox.Text
    }
})

$installButton.Add_Click({
    if (-not $script:installRunning) {
        Start-InstallerProcess
    }
})

$launchButton.Add_Click({
    $launcher = Join-Path $script:selectedInstallDir 'run360gs.cmd'
    if (-not (Test-Path -LiteralPath $launcher)) {
        [System.Windows.Forms.MessageBox]::Show(
            "Run launcher not found: $launcher",
            '360GS Installer',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return
    }
    Start-Process -FilePath $launcher | Out-Null
})

$openFolderButton.Add_Click({
    $target = $folderTextBox.Text.Trim()
    if (-not $target) {
        return
    }
    if (-not (Test-Path -LiteralPath $target)) {
        Ensure-Directory -Path $target
    }
    Start-Process -FilePath 'explorer.exe' -ArgumentList $target | Out-Null
})

$closeButton.Add_Click({
    if ($script:installRunning) {
        [System.Windows.Forms.MessageBox]::Show(
            'Installation is still running. Please wait for it to finish.',
            '360GS Installer',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        return
    }
    $form.Close()
})

$form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($script:installRunning) {
        $eventArgs.Cancel = $true
        [System.Windows.Forms.MessageBox]::Show(
            'Installation is still running. Please wait for it to finish.',
            '360GS Installer',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
})

Set-InstallerUiState -State 'ready'
[void]$form.ShowDialog()

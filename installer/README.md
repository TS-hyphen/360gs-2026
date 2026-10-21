# 360GS Installer Package

This folder contains the installer for the 360GS pipeline.

If you are a normal operator or evaluator, do not start with the PowerShell scripts in this folder. Use the root installer file instead:

`Install-360GS.cmd` (in the repository root).

The PowerShell examples below are mainly for technical setup, validation, and troubleshooting.

## Files
- `..\Install-360GS.cmd`: double-click installer launcher that opens the Windows installer dialog.
- `Install-360GS.Gui.ps1`: native WinForms installer shell for folder selection and live install status.
- `Install-360GS.ps1`: main installer bootstrap script.
- `SelfTest-360GS.ps1`: post-install self-test harness.
- `install-manifest.lock.json`: pinned artifact manifest.
- `install-manifest.lock.schema.json`: JSON schema for manifest structure.

## Double-Click Install
- For the default install path, double-click:
```text
Install-360GS.cmd
```
- This opens a simple Windows installer dialog.
- The dialog lets the user:
  - choose the installation folder
  - click `Install 360GS`
  - watch live status updates while files are downloaded, installed, and validated
  - launch the app after install completes
- The default installer flow now installs the full operator bundle needed for image staging, sparse reconstruction, and LichtFeld training.
- If 360GS is already installed and current, the dialog now ends in a ready state instead of a failure and reports that no updates were needed.
- The installer prevents using the 360GS source-package folder itself as the install root.
- The default install folder follows the per-user pattern:
  `%LOCALAPPDATA%\360GS`

## Before You Install
- Supported operator target: Windows 10 22H2+ or Windows 11
- The full operator install expects the required GPU/driver stack for the current sparse + LichtFeld workflow
- If the machine is not ready, the installer should stop with an exact remediation message instead of completing a misleading partial install
- Most non-technical users should use the default double-click install path and avoid the manual PowerShell commands below

## Most Users
- Double-click `Install-360GS.cmd` in the repository root
- Wait for the installer dialog to finish
- Click `Launch 360GS`
- Follow `OPERATOR_WORKFLOW.md` in the repository root

## Quick Start
```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\Install-360GS.ps1 -Mode portable -Profile research-full -ExistingInstallPolicy upgrade -AcceptEula
```

## Research Mode With Packs
```powershell
.\Install-360GS.ps1 -Mode portable -Profile research-full -AddPack core,colmap-global,glomap-standalone,lichtfeld-studio -AcceptEula
```

## SHARP Preview Pack
```powershell
.\Install-360GS.ps1 -Mode portable -Profile preview-min -AddPack core,sharp-preview -ExistingInstallPolicy upgrade -AcceptEula -AllowUnverifiedArtifacts
```

## Preview-Only Install
- `preview-min` is available for specialized preview-only work, but it does not install the full sparse + training toolchain used by the operator app's `Create Splat!` workflow.
- Non-technical operator installs should use the default `research-full` path so the app is complete on first launch.

## Operator App
- After install, launch the operator console with the `Launch 360GS` button in the installer dialog or with:
```powershell
.\run360gs.cmd
```
- This starts a local-only browser app backed by the managed Python runtime and the installed benchmark support scripts.

## LichtFeld Studio
- If the `lichtfeld-studio` pack is installed, launch it with:
```powershell
.\openlichtfeld.cmd
```
- LichtFeld Studio is the supported local viewer path for generated models.
- The installer now also creates a Start Menu shortcut named `360GS LichtFeld Studio` and uses the LichtFeld app icon.

## Existing Install Handling
- `-ExistingInstallPolicy reuse`: keep existing managed components where possible.
- `-ExistingInstallPolicy upgrade` (default): enforce pinned versions for managed components.
- `-ExistingInstallPolicy replace`: remove managed components in install root and reinstall clean.
- `-Repair`: force re-validation and reinstall of selected artifacts.
- `-UninstallManaged`: remove installer-managed files only (`runtime/`, `tools/`, `packs/`, wrappers, installer state).

## Security Defaults
- Checksum verification is enforced.
- Placeholder checksums (`000...`) cause install failure by default.
- To run early research while hashes are still being finalized, pass `-AllowUnverifiedArtifacts` explicitly.
- `sharp-preview` currently uses a research-only Python package bootstrap/install path and now requires `-AllowUnverifiedArtifacts` on fresh installs.
- Installer downloads are restricted to approved HTTPS hosts only.
- The old bundled browser viewer path has been removed from the installer surface.

## Notes
- Replace placeholder SHA-256 values in `install-manifest.lock.json` before production use.
- Offline sources (`source.type = offline`) require `-OfflineBundle`.
- `run360gs.cmd` and `run360gs.ps1` are generated in the install root.
- Portable install logs now default to `<install folder>\logs`.
- `Install-360GS.cmd --self-test-gui` validates the native installer shell without opening the dialog.

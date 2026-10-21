# 360GS Installer And Bootstrap Specification (v1)

## 1. Purpose
Define a foolproof, one-shot Windows installer/bootstrap process for the 360GS preview-first pipeline on managed Windows 10/11 laptops.

The installer must reduce setup from multi-day manual configuration to a guided workflow that completes in one session.

## 2. Goals
1. One-click or few-click setup for non-technical users.
2. Deterministic environment with pinned versions.
3. Clear pass/fail diagnostics for blocked installs.
4. Immediate validation via post-install self-test.

## 3. Supported Platforms
- Windows 10 (x64)
- Windows 11 (x64)
- PowerShell 5.1+ and PowerShell 7+ compatibility (prefer PS 7 where available)
- NVIDIA GPU path required for full pipeline performance; CPU-only mode allowed for limited preview diagnostics

## 4. Installer Modes
### 4.1 Standard Mode (Admin)
- Installs runtime/tool dependencies in machine scope.
- Registers Start Menu shortcuts and file associations (optional).
- Preferred for long-term managed deployments.

### 4.2 Portable Mode (No Admin)
- Installs all components under user-writable root (default `%LOCALAPPDATA%\360GS`).
- No system PATH modifications required.
- Launches pipeline through wrapper scripts that set local environment.

## 5. Packaging Strategy
1. Primary artifact: signed bootstrap executable (`360GS-Setup.exe`) or signed PowerShell launcher (`Install-360GS.cmd` + native PowerShell dialog bootstrap).
2. Dependency manifest file: `install-manifest.lock.json` with exact versions, URLs, hashes.
3. Optional offline bundle: `360GS-offline-bundle.zip` containing all binaries/models referenced in manifest.

## 6. Required Installed Components (v1)
1. Core runtime:
- Python runtime (pinned)
- isolated venv/embedded environment
2. Media tools:
- FFmpeg (pinned)
3. Preview stack:
- Sharp Frames integration module (or equivalent local implementation)
- preview backend binaries/models (pinned)
4. Production candidate backends (selective, profile-based install):
- VGGSfM and/or COLMAP `global_mapper` and/or standalone `GLOMAP` and/or VGGT dependencies (based on chosen profile)
5. Training candidate backends (selective, profile-based install):
- LichtFeld Studio as first 3DGS training candidate after sparse reconstruction
6. Publish stack:
- Spark-compatible packaging utilities for `.spz`/`.rad` workflow

## 6.1 Dependency And Driver Inventory (Install Matrix)
1. Platform prerequisites:
- Windows 10 22H2+ or Windows 11
- PowerShell 5.1+ (PowerShell 7 preferred)
- x64 CPU
2. GPU prerequisites (for accelerated preview/production):
- NVIDIA discrete GPU (production tiers per v1 decisions)
- NVIDIA driver version compatible with selected PyTorch CUDA runtime
- CUDA Toolkit install is optional for runtime inference/training if wheels bundle CUDA runtime
3. Core managed runtime (installed by 360GS installer):
- Python embedded runtime (pinned, isolated in install root)
- Python package environment (pinned lock set)
4. Core managed tools:
- FFmpeg (pinned)
- Sharp Frames-compatible culling module (pinned)
- 360GS app launcher/wrappers
5. Optional managed backend packs:
- `vggsfm` pack
- `colmap-global` pack
- `glomap-standalone` pack
- `lichtfeld-studio` pack
- `vggt` pack
- `spark-publish` pack
6. Optional external tooling (not required for basic preview profile):
- Git (for developer workflows only)
- Node.js (only if Spark packaging workflow requires local node tooling in selected pack)

## 7. Install Profiles
### 7.1 `preview-min`
- Installs only components needed for ingest, culling, and preview output.
- Fastest install and smallest disk usage.

### 7.2 `research-full`
- Installs preview plus production backend candidates and publish tooling.
- Used for technical evaluation and benchmarking.

### 7.3 `offline-preview`
- Same as `preview-min`, but from offline bundle only.

## 8. Preflight Checks (Hard Requirements)
Installer must run checks before modifying system state:
1. OS version support.
2. Available disk space (configurable threshold, default >= 40 GB for full profile).
3. GPU presence, CUDA compatibility, and driver version.
4. Network mode detection (direct, proxy, offline).
5. Write permissions to target install path.
6. Existing conflicting install detection.
7. Existing 360GS managed install detection with policy resolution (`reuse`, `upgrade`, `replace`).
8. NVIDIA driver/runtime compatibility check for selected backend profile.

If checks fail, installer outputs actionable remediation text and log.

## 9. Dependency Resolution Rules
1. All dependencies resolved from pinned manifest.
2. Every downloaded file must pass checksum validation (SHA-256 minimum).
3. Retry policy for network failures (exponential backoff).
4. Proxy settings accepted via UI and CLI flags.
5. Install must be resumable after interruption.
6. Installer must distinguish:
- managed components (inside 360GS install root)
- external/system components (outside 360GS install root)
7. Managed components can be upgraded/replaced by installer policy.
8. External/system components are never uninstalled automatically by default.

## 9.1 Existing Software Handling Policy (Required)
1. Detection stage:
- Detect existing 360GS install roots and state files.
- Detect existing system Python, NVIDIA driver, CUDA toolkit (if present), FFmpeg on PATH.
2. Policy modes:
- `reuse`: keep existing managed components when compatible; install only missing items.
- `upgrade`: default; update managed components to pinned manifest versions.
- `replace`: remove managed components in install root and perform clean reinstall.
3. Conflict behavior:
- If system dependency is incompatible and installer cannot safely remediate, fail with actionable guidance.
- If compatible system dependency exists, installer may reuse it only when profile permits; otherwise use managed isolated runtime.
4. Safety rules:
- Never remove global/system Python automatically.
- Never remove NVIDIA drivers automatically.
- Any destructive action is limited to installer-managed directories unless explicitly approved.
5. Visibility:
- Install report must list each detected preinstalled dependency and decision (`reused`, `upgraded`, `ignored`, `blocked`).

## 10. Environment Isolation Rules
1. No reliance on global Python/PIP state.
2. No reliance on pre-existing PATH entries.
3. Tool invocation always via local wrapper (`run360gs.cmd`/`run360gs.ps1`).
4. Side-by-side versioning supported (`v1`, `v1.1`) without breaking older installs.

## 11. Post-Install Self-Test (Required)
Installer runs an automated smoke test:
1. Load tiny bundled sample dataset.
2. Run minimal pipeline: frame ingest -> cull -> preview reconstruction.
3. Verify output artifacts exist:
- `cull_manifest.json`
- preview output artifact
- `preview_qc_report.json`
4. Output result: `PASS`, `PASS_WITH_WARNINGS`, or `FAIL`.

Installer must not report success without completed self-test unless user explicitly skips with acknowledgement.

## 12. Logging And Diagnostics
1. Structured install logs written to `%PROGRAMDATA%\360GS\logs` (admin) or `%LOCALAPPDATA%\360GS\logs` (portable).
2. Log format: JSONL with timestamp, stage, event, error_code, detail.
3. Generate human-readable install report (`install-report.txt`).
4. One-click export of diagnostic bundle for support.

## 12.1 Long-Running Execution Support
1. Installed pipeline tools must support detached/background execution for benchmark and production jobs expected to run for hours.
2. Runtime jobs must write:
- durable stdout/stderr logs
- machine-readable stage state
- final report artifact
3. Runtime wrappers must support `resume` semantics so completed stages are skipped after interruption.
4. Status inspection tools must be available for support and operator use.

## 13. Rollback And Repair
1. If install fails mid-run, rollback partial state where safe.
2. Provide `Repair` mode to re-validate and restore missing/corrupted components.
3. Provide `Uninstall` mode that removes managed artifacts and leaves user project data untouched by default.
4. Provide `Replace` mode for managed components without touching system-wide dependencies.

## 14. Security Requirements
1. Installer binary/script must be code-signed.
2. TLS-only downloads for online mode.
3. Hash verification mandatory for all artifacts.
4. Optional allow-list of approved hostnames for enterprise environments.
5. No telemetry exfiltration by default.

## 15. UX Requirements
1. Default operator entry should be a native Windows dialog launched from the bootstrap wrapper.
2. Minimum dialog flow for v1:
- installation folder selection
- install action
- live status text during download/install/validation
- completion state with launch button
3. Error messages must include exact failed component and next step.
4. The installer must block obviously unsafe roots, including the installer package source folder itself.
5. Completion state includes launch button and log/report location.

## 16. CLI Requirements
Provide non-interactive automation:
```powershell
360gs-setup.exe --mode portable --profile preview-min --offline-bundle C:\Installers\360GS-offline-bundle.zip --accept-eula
```
Required flags:
- `--mode [standard|portable]`
- `--profile [preview-min|research-full|offline-preview]`
Optional flags:
- `--proxy-url`
- `--install-dir`
- `--skip-self-test` (must print risk warning)
- `--log-dir`
- `--existing-install-policy [reuse|upgrade|replace]`
- `--repair`
- `--uninstall-managed`

## 17. Acceptance Criteria
1. Clean Windows 10/11 laptop can install selected profile in one session.
2. No manual environment edits required after install.
3. Post-install self-test passes and produces expected artifacts.
4. Portable mode works without admin rights.
5. Offline bundle install works in disconnected environment.
6. Repair mode can fix at least one simulated broken dependency case.

## 18. Implementation Plan (Installer)
1. Define manifest schema and lockfile generator.
2. Build bootstrap runner (PowerShell + native WinForms dialog for v1, optional packaged EXE later).
3. Implement preflight checks and environment detection.
4. Implement downloader + checksum verifier + resume logic.
5. Implement profile-aware install actions.
6. Implement smoke test harness.
7. Add rollback/repair/uninstall.
8. Add signing and enterprise packaging pipeline.

## 19. V1 Decisions (Locked)
1. Bootstrap technology: `PowerShell-first bootstrap` for v1, with optional packaged EXE wrapper later.
2. Portable install root: `%LOCALAPPDATA%\360GS`.
3. Hardware support tiers:
- `Preview Supported`: CPU-only or any GPU, 32 GB RAM recommended.
- `Production-Lite Supported`: NVIDIA CUDA GPU with >= 8 GB VRAM.
- `Production Target`: NVIDIA CUDA GPU with >= 12 GB VRAM (16 GB preferred).
4. `research-full` composition: modular backend packs, not install-everything-by-default.
- Base research install includes core runtime + preview stack + one default production backend.
- Additional packs installed on demand via installer flags or repair/add-pack workflow.
5. First classical multi-view baseline target: `COLMAP global_mapper` when available in released Windows binaries; use standalone `GLOMAP` as the Windows fallback when the shipped COLMAP build does not expose that command.
6. First 3DGS training integration target: `LichtFeld Studio`, subject to driver/CUDA compatibility on the target machine.

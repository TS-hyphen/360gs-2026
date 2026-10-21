# 360GS Install Inventory And Dependency Policy

## 1. Purpose
Define exactly what must be installed, what is optional, and how the installer handles pre-existing software.

## 2. Compatibility Baseline
- OS: Windows 10 22H2+ or Windows 11 (x64)
- Shell: PowerShell 5.1+ (PowerShell 7 preferred)
- CPU: x64
- RAM baseline: 32 GB

## 3. GPU/Driver Baseline
- Preview supported: CPU-only allowed, NVIDIA preferred
- Production-lite: NVIDIA GPU with >= 8 GB VRAM
- Production target: NVIDIA GPU with >= 12 GB VRAM (16 GB preferred)
- Driver policy:
  - Installer detects NVIDIA driver version and CUDA capability
  - Installer does not auto-uninstall driver
  - Installer blocks incompatible production profile with actionable remediation

## 4. Managed Components (Installed Inside 360GS Root)
1. Python runtime (embedded/pinned)
- Owner: 360GS installer
- Install location: `runtime/python311/`
- Update policy: `upgrade` by default

2. Python package environment (pinned lock)
- Owner: 360GS installer
- Install location: `runtime/env/` or embedded site-packages path
- Update policy: reinstall/upgrade per lockfile

3. FFmpeg (pinned)
- Owner: 360GS installer
- Install location: `tools/ffmpeg/`
- Update policy: replace by versioned artifact

4. App core and wrappers
- Owner: 360GS installer
- Install location: `app/`, `run360gs.cmd`, `run360gs.ps1`
- Update policy: replace

5. Benchmark support scripts
- Owner: 360GS installer
- Install location: `benchmark/`
- Contents: staging, detached job launchers, status tools, shared PowerShell helpers
- Update policy: replace

6. Config templates and local registry seed
- Owner: 360GS installer
- Install location: `config/`
- Contents: `datasets.example.json` and initial `datasets.local.json` seed when available
- Update policy: preserve local dataset registry when already present

7. Backend packs (optional, profile-driven)
- `packs/vggsfm/`
- `packs/colmap-global/`
- `packs/glomap-standalone/`
- `packs/lichtfeld-studio/`
- `packs/vggt/`
- `packs/spark-publish/`
- `packs/sharp-preview/`
- Update policy: pack-level add/upgrade/remove

## 5. External/System Components (Detected, Not Owned By Default)
1. System Python
- Detection only unless explicitly configured for reuse
- Never auto-uninstall

2. NVIDIA Driver
- Detection and compatibility gating only
- Never auto-uninstall

3. CUDA Toolkit (system-wide)
- Optional for many wheel-based workflows
- Detection only by default

4. Git/Node.js (if needed by selected pack)
- Prefer managed pack-contained binaries when practical
- System installations can be reused when compatible

## 6. Install Profiles To Component Mapping
1. `preview-min`
- Managed Python runtime
- Managed Python packages (preview/culling set)
- FFmpeg
- App core + wrappers

2. `research-full`
- Everything in `preview-min`
- Selected backend pack(s)
- Spark publish pack (optional)

3. `offline-preview`
- Same as `preview-min`, sourced from offline bundle

## 7. Existing Installation Handling
1. Policy `reuse`
- Keep compatible managed components
- Install missing components only

2. Policy `upgrade` (default)
- Bring managed components to pinned versions
- Preserve user project data

3. Policy `replace`
- Remove managed runtime/tools/packs in install root
- Clean reinstall from manifest
- Keep project data unless `--purge-project-data` is explicitly requested

## 8. Conflict Resolution Rules
1. If managed component exists at wrong version:
- `reuse`: keep and warn
- `upgrade`: replace/update
- `replace`: clean reinstall

2. If system dependency is incompatible:
- fail with specific remediation text
- do not attempt unsafe global uninstall

3. If install path contains partial/stale state:
- run repair path automatically before failure

## 9. Uninstall Scope
- `uninstall-managed` removes only installer-owned paths:
  - `runtime/`, `tools/`, `packs/`, wrappers, installer state
- Default uninstall does not remove:
  - user datasets
  - generated outputs
  - external/system-wide tools/drivers

## 10. Version Pinning Rules
- Every artifact in `install-manifest.lock.json` must include:
  - exact version
  - source
  - SHA-256
  - install method
- Placeholder hashes are allowed only for initial research bootstrap with explicit override flag.

## 11. Reporting Requirements
Installer report must include:
1. Detected system software and versions
2. Managed components actions (`installed`, `reused`, `upgraded`, `replaced`, `skipped`)
3. Profile and pack set applied
4. Any blocked requirements and remediation guidance

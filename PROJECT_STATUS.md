# Project Status - 360GS

Last updated: 2026-10-21

All paths in this document are relative to the repository root, or to `<install folder>` (the folder chosen in the installer, `%LOCALAPPDATA%\360GS` by default).

## 1. Goals
Build a Windows-first 3D Gaussian Splat pipeline that a non-technical user can operate with minimal training:
- point at a folder of images and get a splat with as little setup as possible
- keep everything self-contained under a managed local runtime instead of global software
- support a fast preview path and a higher-quality production path
- give clear machine-readiness checks and readable remediation guidance
- keep the codebase organized for a small team using Git

## 2. Current State (validated March 2026)
Working today:
- double-click installer (`Install-360GS.cmd`) with a native Windows dialog, folder selection, live status and post-install self-test
- managed portable install with pinned Python 3.11.9, FFmpeg 7.1.1, COLMAP 3.13.0, standalone GLOMAP 1.2.0 and LichtFeld Studio 0.4.2
- machine-readiness reporting (Windows version, NVIDIA driver, CUDA runtime, VRAM)
- local web app (`<install folder>\run360gs.cmd`): image folder -> `Check Folder` -> quality choice -> `Create Splat!`
- workflow progress with stage markers, cancel with optional cleanup (source imagery is never deleted), workflow history, and `View Splat` in LichtFeld Studio
- automatic lower-memory retry for LichtFeld training on GPU-memory failures
- advanced media prep for standard video and exported equirectangular 360 video
- Windows 10 22H2+ and Windows 11 validated

Not yet done:
- final polished operator UI
- team branch / pull-request conventions
- installer-driven uninstall from the dialog

## 3. Confirmed Decisions
1. Windows-first for v1.
2. The default user path stays simple and non-technical.
3. The GUI is a thin front end over the working scripts, not a pipeline rewrite.
4. Default install root is `%LOCALAPPDATA%\360GS`; users may choose another folder.
5. Managed, runtime-local tools are preferred over global system tools.
6. LichtFeld Studio is the supported local viewer; the old browser viewer was removed.
7. Generated outputs go under `artifacts\benchmark\...`, never into source folders.
8. Security hardening favors explicit trust boundaries and readable guidance over silent machine-wide changes.
9. Launchers, logs and outputs live under the chosen install folder.
10. End users never need AI tools to install or operate 360GS. Project files stay tool-neutral.

## 4. Source Layout
- `app/` - local web app (Python server in `app/main.py`, frontend in `app/web/`)
- `benchmark/` - staging, sparse reconstruction, training and job-status scripts (`benchmark/lib/Benchmark.Common.ps1` holds shared helpers)
- `installer/` - installer, GUI shell, self-test and pinned artifact manifest
- `config/` - dataset registry template (`datasets.example.json`); `datasets.local.json` is machine-local and not committed
- `docs/` - developer setup and validation checklists
- `datasets/`, `artifacts/` - local only, excluded from Git

Dataset `local_path` values in the registry may be relative; they resolve against the repository or install root.

## 5. Validated Results
- Mip-NeRF 360 bonsai, 30,000 iterations on a 4 GB laptop GPU. Measured stage times: feature extraction 135 s, matching 48 s, GLOMAP mapping 534 s, dataset prep 2 s, training 4,289 s; total about 1 h 23 m.
- Installed-app simple workflow, Mip-NeRF 360 bicycle `images_4`, `Fast-preview`: completed end-to-end and produced `splat_6000.ply`.

Dataset sources are listed in `EXAMPLE_DATASET_LINK.md`.

## 6. Known Constraints
1. The development test laptop has a 4 GB VRAM GPU: fine for preview and light testing, below the preferred production target.
2. Some machines carry other global Python installs; 360GS must keep relying on its managed runtime.
3. Destructive-path safety checks must only be tested against disposable folders.
4. Long-running jobs must keep using detached/background execution.

## 7. Next Steps
See `docs/UPGRADE_PLAN.md` for the recommended upgrade path.

## 8. Useful Commands
From the `installer` folder:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\Install-360GS.ps1 -Mode portable -Profile research-full -ExistingInstallPolicy upgrade -AcceptEula
```

Dry run:

```powershell
.\Install-360GS.ps1 -Mode portable -Profile research-full -ExistingInstallPolicy upgrade -AcceptEula -WhatIfInstall
```

Installed app self-test:

```powershell
<install folder>\run360gs.ps1 --self-test
```

## 9. Reference Documents
- `README.md`
- `OPERATOR_WORKFLOW.md`
- `2026_3dGS_Requirements.md`
- `installer_spec.md`
- `docs/DEVELOPER_SETUP.md`
- `docs/WINDOWS11_VALIDATION_CHECKLIST.md`
- `docs/UPGRADE_PLAN.md`

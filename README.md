# 360GS Windows Pipeline

This repository contains a Windows-first research project focused on helping non-technical users create 3D Gaussian Splats quickly from captured imagery and video. The intended audience is professional operators, evaluators, and technical teammates who need a practical workflow today while the project continues to evaluate installer, reconstruction, training, and operator-experience options for a production-ready pipeline.

## Start Here
- Most users should start with: `Install-360GS.cmd`
- After install, follow: `OPERATOR_WORKFLOW.md`
- If you need the example dataset source: `EXAMPLE_DATASET_LINK.md`
- Technical setup notes: `docs/DEVELOPER_SETUP.md`
- Windows 11 validation checklist: `docs/WINDOWS11_VALIDATION_CHECKLIST.md`
- Project status: `PROJECT_STATUS.md`
- Upgrade plan: `docs/UPGRADE_PLAN.md`
- Requirements: `2026_3dGS_Requirements.md`
- Installer specification: `installer_spec.md`

## First-Time Local Run
1. Double-click `Install-360GS.cmd`.
2. Choose an install folder in the Windows installer dialog.
3. Wait for install and validation to complete.
4. Launch the app from the dialog or with `<install folder>\run360gs.cmd`.
5. In the app, enter an image folder, click `Check Folder`, choose quality, then click `Create Splat!`.

For operator installs, treat the chosen install folder as the main 360GS home. Launchers, install logs, and generated outputs should all be there.

If the installer stops with a machine-readiness message, do not guess. Read the exact remediation text in the installer window first. Windows 11 has now been validated successfully on an updated test machine, but readiness checks still matter because the full operator path depends on the correct NVIDIA driver/runtime stack.

## Repository Layout
- `app/`: installed local web app source.
- `benchmark/`: staging, sparse reconstruction, training, and status scripts.
- `config/`: configuration templates and local dataset registry files.
- `docs/`: developer and GitHub workflow notes.
- `installer/`: managed runtime installer, manifest, and self-test scripts.
- `datasets/`: local datasets, excluded from Git.
- `artifacts/`: generated outputs. This path is excluded from Git.

## Git Rules
- Keep source, docs, and templates in Git.
- Keep datasets, generated artifacts, caches, logs, and machine-specific config out of Git.
- `config/datasets.local.json` is intentionally local-only.
- `EXAMPLE_DATASET_LINK.md` records where the example datasets came from so the repository can stay small.
- Root backup archives such as `360GS_code_docs_backup_*.zip` are intentionally local-only.

## Current Research Snapshot
- Managed installer flow is working and opens from `Install-360GS.cmd`.
- The default installer path now installs the full operator bundle needed for `Create Splat!`, including sparse reconstruction and LichtFeld training tools.
- Installed operator app is working from `run360gs.cmd` in the managed install root.
- Portable installs now write installer logs under `<chosen install folder>\logs` instead of a separate `%LOCALAPPDATA%\360GS\logs` path.
- The simple GUI path has passed an end-to-end image-folder smoke test.
- LichtFeld training now has an automatic lower-memory tile fallback that retries on some GPU-memory failures. It can run slower and may slightly change result quality, and the workflow UI now says when that fallback is active or was used.
- Completed runs in `Recent Workflow History` now include a `View Splat` button that opens the saved `.ply` directly in LichtFeld Studio.
- Running simple-workflow jobs now include a `Cancel` action with a two-step confirmation flow. The operator can stop the run and choose whether 360GS should also remove the managed working files created for that run, while always keeping the original source imagery.
- The installer now creates a standard Start Menu shortcut for LichtFeld Studio with the proper app icon.
- Windows 11 validation has now succeeded after the required driver update and follow-up repo fixes from that machine.
- Advanced media preparation exists for standard video and exported equirectangular 360 video.
- The validated sparse path still uses managed `COLMAP 3.13.0` for feature extraction/matching plus standalone `GLOMAP 1.2.0` for mapping.
- The browser viewer has been intentionally removed. LichtFeld Studio is the supported local viewer path.

## Notes
- New generated outputs should go under `artifacts/benchmark/...`.
- Legacy generated folders under `benchmark/` are compatibility-only and should not be used for new runs.
- The `preview-min` profile remains available for specialized preview-only work, but it is not the default operator install because it does not include the full `Create Splat!` toolchain.

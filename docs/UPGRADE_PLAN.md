# 360GS Upgrade Plan

Status: proposed, October 2026. Nothing in this plan has been implemented yet.

## Why upgrade now
The pinned toolchain dates from March 2026. Since then:

| Area | 360GS today | Available now | What it enables |
|---|---|---|---|
| Sparse reconstruction | COLMAP 3.13.0 (features/matching) + standalone GLOMAP 1.2.0 (mapping) | COLMAP 4.x: global mapper built in (4.0), native spherical/equirectangular cameras and GPU bundle adjustment (4.1), multi-component global mapping (4.2). Windows CUDA binaries are published. | One tool instead of two; removes the GLOMAP pack. Matches requirement 8.2 of `2026_3dGS_Requirements.md`. |
| Training / viewer | LichtFeld Studio 0.4.2 | LichtFeld Studio 0.5.4.x: lower training VRAM, SPZ export, project files | Fewer GPU-memory failures on 4 GB laptops; SPZ output toward the Spark publishing requirement. |
| 360 video | Custom reprojection into four virtual cameras | Native equirectangular camera model in COLMAP 4.1+ | Possible removal of the custom reprojection step. |

## Guiding rules
- End users never need AI tools to install or run 360GS.
- Every change keeps the current operator workflow working: `Install-360GS.cmd` -> `run360gs.cmd` -> `Check Folder` -> `Create Splat!`.
- Every change is validated on a Windows machine with an NVIDIA GPU before it reaches `main`.
- Work happens on short-lived branches and lands through pull requests.

## Phase 1 - Safety net
- Add automated tests for the pure helper functions in `app/main.py` (quality presets, video detection, path checks, failure summaries).
- Add a single checks script: Python compile + tests, JavaScript syntax check, PowerShell parse and lint.
- Done when the checks pass on the current code.

## Phase 2 - Toolchain update
- Move to COLMAP 4.2.x and LichtFeld Studio 0.5.4.x with pinned checksums in `installer/install-manifest.lock.json`.
- Replace the standalone GLOMAP mapping call with COLMAP's global mapper; remove the GLOMAP pack.
- Update capability checks and user-facing wording ("Camera solve" instead of tool names).
- Re-evaluate whether the lower-memory training retry is still needed with the newer LichtFeld.
- Keep the old manifest on a rollback branch.

## Phase 3 - Simplification
- Split `app/main.py` (about 2,300 lines) into focused modules without changing behavior.
- Remove duplicated helpers between Python and `benchmark/lib/Benchmark.Common.ps1`, unused compatibility API aliases, and legacy `benchmark\jobs` path handling.
- Decide whether to keep the `preview-min` / SHARP research profile; remove it if unused.
- Remove the `app/web/app.css` and `app/web/app.js` shims.

## Phase 4 - Operator UI polish
- Clearer stage-specific running text and honest time ranges.
- Layout and visual-hierarchy cleanup; adopt one of the UI concept directions once chosen.

## Phase 5 (optional) - Native 360
- Prototype feeding equirectangular frames directly to COLMAP's spherical camera model behind an Advanced option. Keep only if results are equal or better than the current reprojection.

## Validation gate (every phase)
On a Windows machine with an NVIDIA GPU:
1. Fresh install into an empty folder; self-test passes.
2. `Fast-preview` on Mip-NeRF 360 bicycle `images_4`.
3. One `Medium` run on bonsai; compare stage times with the March baseline in `PROJECT_STATUS.md`.
4. Cancel a run with and without cleanup.
5. `View Splat` opens the result.

If mapping or training quality regresses, revert the toolchain change and ship the other phases alone.

## Development approach
This project is developed with AI-assisted tooling, kept tool-neutral in the repository. The recommended pattern for the next round:
- a lead role that scopes each change, writes acceptance criteria and does the final review
- implementer roles that each own a fixed set of files for one change
- an independent reviewer role that checks each change against its criteria and runs the checks script, without having written the change
- a human Windows validation gate before merge

## References
- COLMAP 4.0: https://radiancefields.com/colmap-4.0-introduces-major-performance-and-infrastructure-updates
- COLMAP 4.1: https://radiancefields.com/colmap-4.1.0-ships-caspar-gpu-bundle-adjustment-and-native-360-reconstruction
- COLMAP 4.2: https://radiancefields.com/colmap-4.2.0-adds-multi-component-global-mapping-and-loma-learned-matching
- LichtFeld Studio releases: https://radiancefields.com/tags/lichtfeld-studio

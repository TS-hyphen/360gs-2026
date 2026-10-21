# 360GS Upgrade Plan

Status: proposed, October 2026. Nothing in this plan has been implemented yet.

## Why upgrade now
The pinned toolchain dates from March 2026. Since then:

| Area | 360GS today | Available now | What it enables |
|---|---|---|---|
| Sparse reconstruction | COLMAP 3.13.0 (features/matching) + standalone GLOMAP 1.2.0 (mapping) | COLMAP 4.x: global mapper built in (4.0), native spherical/equirectangular cameras and GPU bundle adjustment (4.1), multi-component global mapping (4.2). Free Windows CUDA binaries are published on GitHub for 4.1.0 through 4.2.1. | One tool instead of two; removes the GLOMAP pack. Matches requirement 8.2 of `2026_3dGS_Requirements.md`. |
| Training / viewer | LichtFeld Studio 0.4.2 | LichtFeld Studio 0.5.4.x: lower training VRAM, SPZ export, project files, Vulkan viewer | Fewer GPU-memory failures on 4 GB laptops; SPZ output toward the Spark publishing requirement. **See licensing below: free Windows binaries stop at 0.4.2.** |
| 360 video | Custom reprojection into four virtual cameras | Native equirectangular camera model in COLMAP 4.1+ | Possible removal of the custom reprojection step. |

## Licensing, cost and offline packaging (checked 2026-10-21)
Goal: every tool stays free to use, and the installer can ship as a self-contained offline package that does not download anything at install time.

| Tool | License | Free Windows binary? | Can be bundled in an offline installer? | Upgrade verdict |
|---|---|---|---|---|
| Python 3.11 embeddable | PSF | Yes (python.org) | Yes | No change needed |
| FFmpeg essentials build (gyan.dev) | GPL | Yes | Yes, if the package includes the license and points to the matching source | No change needed |
| COLMAP 4.2.x | BSD (dependencies under their own licenses) | Yes, GitHub releases 4.1.0-4.2.1 | Yes, include its license files | **Safe to upgrade** |
| Standalone GLOMAP 1.2.0 | BSD | Yes | Yes | Replaced by COLMAP 4.x; can be removed |
| LichtFeld Studio 0.4.2 (current) | GPLv3 | Yes, still downloadable from GitHub releases | Yes, with its GPLv3 license and a pointer to the matching source | Keep as the default for now |
| LichtFeld Studio 0.5.x | GPLv3 (the software is still open source) | **No.** From 0.5.0 on, official Windows binaries are only offered through the paid LichtFeld Portal (donation/one-time purchase); GitHub has source tags only | Yes under GPLv3, if we build it ourselves from source or redistribute a purchased build with its source; Portal terms forbid sharing download links or accounts | **Decision needed** (options below) |
| SHARP preview (ml-sharp) | Not re-verified; installs from source at install time and needs `-AllowUnverifiedArtifacts` | No binary | No (it downloads at install time) | Recommend removing with the `preview-min` profile |

Notes:
- No feature of the LichtFeld desktop app is locked behind payment. What changed is how the ready-made Windows build is distributed, not the GPLv3 license.
- LichtFeld 0.5.x needs an NVIDIA GPU with compute capability 7.5+ (GTX 16-series / RTX 20-series or newer) and driver 570+. The current 4 GB Quadro T2000 test laptop meets that.
- This is a summary of public terms, not legal advice. Have the organization's software/licensing contact confirm before distributing an offline package outside the team.

### LichtFeld options
1. **Stay on 0.4.2 (recommended for now).** Free, already pinned and validated, and its binary can go in the offline package. We keep our own lower-memory retry.
2. **Build 0.5.x from source ourselves.** Free under GPLv3 and fully bundleable. Costs a one-time build setup (Visual Studio, CUDA 12.8+ toolkit, C++23), ideally as an automated Windows build. We must ship or link the exact source used.
3. **Buy a 0.5.x build through the LichtFeld Portal.** Small one-time cost; GPLv3 still allows bundling the binary with its source, but this depends on the organization being able to make the purchase and keep doing so for future versions.

### Offline installer package
- The installer already supports `source.type = offline` and `-OfflineBundle`. Phase 2 extends this so the default operator profile can install entirely from a local bundle.
- The bundle contains every pinned artifact with its checksum, plus a `licenses/` folder (each tool's license and, for GPL tools, a pointer to the exact source version).
- The bundle is built once per release from the pinned manifest and versioned with the repo release; operators never download from the web.

## Guiding rules
- End users never need AI tools to install or run 360GS.
- Every bundled tool must be free to use and legally redistributable in an offline package.
- Every change keeps the current operator workflow working: `Install-360GS.cmd` -> `run360gs.cmd` -> `Check Folder` -> `Create Splat!`.
- Every change is validated on a Windows machine with an NVIDIA GPU before it reaches `main`.
- Work happens on short-lived branches and lands through pull requests.

## Phase 1 - Safety net
- Add automated tests for the pure helper functions in `app/main.py` (quality presets, video detection, path checks, failure summaries).
- Add a single checks script: Python compile + tests, JavaScript syntax check, PowerShell parse and lint.
- Done when the checks pass on the current code.

## Phase 2 - Toolchain update
- Move to COLMAP 4.2.x with pinned checksums in `installer/install-manifest.lock.json`. Keep LichtFeld Studio 0.4.2 unless option 2 or 3 above is chosen.
- Replace the standalone GLOMAP mapping call with COLMAP's global mapper; remove the GLOMAP pack.
- Update capability checks and user-facing wording ("Camera solve" instead of tool names).
- Build the offline installer bundle (all pinned artifacts + `licenses/` folder) and make it the default install source.
- Re-evaluate the lower-memory training retry only if LichtFeld moves to 0.5.x.
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

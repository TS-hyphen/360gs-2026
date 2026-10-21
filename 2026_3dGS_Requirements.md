# 2026 3D Gaussian Splatting (3DGS) Pipeline Requirements

## 1. Purpose
Define a Windows-first, non-technical-user pipeline for converting site-captured imagery (`.jpg`, `.jpeg`, `.png`, `.mp4`, `.mov`) into usable Gaussian Splat outputs for rapid review and production-quality publishing.

This document is implementation-driving. It will be used to build v1 of the pipeline.

## 2. Primary Objectives
1. Deliver a fast **Preview Path** to validate dataset quality and scene coverage before expensive processing.
2. Deliver a robust **Production Path** for higher-fidelity, larger-scene outputs.
3. Support low-friction use by non-technical field and office staff on managed Windows laptops.
4. Produce outputs compatible with Spark 2.0 workflows, including LoD and `.rad` for scalable sharing/rendering.

## 3. Platform And User Constraints
- OS: Windows 10 and Windows 11.
- Users: Non-technical operators; no CLI required.
- Environment: Work laptops with possible restrictions (limited admin rights, locked networking/proxy, controlled installs).
- Data: Potentially sensitive infrastructure imagery; local-first handling required.

## 4. Scope
### In Scope
- Ingest imagery/video from phones and drones.
- Pre-cull/filter poor frames using Sharp Frames-style quality selection.
- Use stable video tooling (`FFmpeg`) for frame extraction and optional shot segmentation (`PySceneDetect`) for long videos.
- Support dynamic-object masking input for pose robustness where available.
- Run fast preview reconstructions for go/no-go decisions.
- Run production reconstructions using faster-than-traditional COLMAP workflows where feasible.
- Export splats and publish-ready artifacts (including Spark LoD `.rad`).
- Record run metadata, quality metrics, and reproducibility information.

### Out Of Scope (v1)
- Fully automated survey-grade georeferencing guarantees.
- Live field capture control from drone SDKs.
- Multi-tenant cloud orchestration platform.

## 5. Architecture Strategy (Preview First)
The program is split into two connected paths:

1. **Preview Path (required first):**
   - Dataset QA, culling, and rapid reconstruction to catch capture failures early.
   - Produces reusable artifacts for production.

2. **Production Path (next):**
   - Higher-fidelity multi-view reconstruction and training.
   - Uses preview artifacts to reduce failure rate and runtime.

## 6. Preview Path Requirements (Phase 1)
### 6.1 Functional Requirements
1. Input ingestion:
   - Accept folders of images and videos.
   - Extract video frames via `FFmpeg` using configurable sampling presets (`low`, `medium`, `high`).
   - Optional shot-boundary segmentation via `PySceneDetect` before sampling for long clips.
2. Quality culling:
   - Integrate Sharp Frames workflow (or equivalent local module) for blur/redundancy reduction.
   - Output a manifest of `kept`, `rejected`, rejection reasons, and quality score.
3. Rapid reconstruction:
   - Support one or more fast methods (e.g., SHARP, VGGT-style fast geometry init) for quick visual validation.
   - Allow scene chunking (by folder/time) for large captures.
4. Review output:
   - Generate quick preview assets: low-cost splat/model output and a QA summary report.

### 6.2 Non-Functional Requirements
- Operator runtime target: preview pass starts in <= 2 minutes after import and returns first result quickly (target <= 5-10 minutes on standard hardware, dataset dependent).
- UX: 4-step wizard minimum (`Import -> Cull -> Preview -> Decision`).
- Reliability: pipeline resumes after interruption from last completed stage.

### 6.3 Preview Acceptance Criteria
1. User can process a mixed image/video dataset without command line usage.
2. System emits a culling report and a preview artifact that can be visually inspected.
3. User can mark dataset as `Proceed to Production` or `Needs Recapture`.
4. All preview outputs are saved to a project folder with stable naming.

## 7. Preview-To-Production Handoff Requirements
Preview must create machine-readable artifacts consumed by Production:
1. `cull_manifest.json`: frame/image keep/drop decisions and scores.
2. `selection_profile.json`: chosen sampling/culling parameters.
3. `scene_chunks.json`: logical partitions for large sites.
4. `preview_qc_report.json`: quality findings and risk flags.
5. Optional coarse transforms/anchors if generated in preview.

Production must be able to run using these artifacts without redoing culling.

## 8. Production Path Requirements (Phase 2)
### 8.1 Functional Requirements
1. Pose/geometry pipeline should prioritize faster alternatives to legacy sequential SfM flows.
2. Must support pluggable backends so candidate methods can be benchmarked and swapped.
3. Train/build higher-quality 3DGS outputs from curated frames.
4. Export master outputs (`.ply` and/or `.spz`) and Spark publishing artifacts.
5. Build LoD publish package with `.rad` for large-scene streaming when enabled.

### 8.1.1 Training Backend Plan
1. Primary near-term training candidate: **LichtFeld Studio** for actual 3DGS optimization and interactive review.
2. Expected handoff into training:
   - source images
   - sparse reconstruction / camera solution from `COLMAP + GLOMAP` or equivalent
3. Training backend selection criteria:
   - ability to consume current sparse reconstruction outputs without fragile preprocessing
   - Windows binary availability for research evaluation
   - training speed and convergence quality on laptop-class GPUs and stronger target hardware
   - viewer quality for operator QA
4. Current planning assumption:
   - use `COLMAP + GLOMAP` for sparse reconstruction
   - use `LichtFeld Studio` as first integrated training backend
5. Track hard constraints during integration:
   - NVIDIA driver >= 570
   - CUDA 12.8+ expectation from upstream
   - GPLv3 license for the research phase

### 8.2 COLMAP Global Mapper Resolution (Design Rule)
1. Use `COLMAP format` (text/bin models) as a neutral interchange contract where helpful.
2. Do **not** require full COLMAP GUI/toolchain as a mandatory user dependency.
3. For classical SfM baseline, use **COLMAP integrated `global_mapper`** rather than the deprecated standalone GLOMAP repository.
4. Prefer fast mappers or model-driven estimators (`COLMAP global_mapper`, `VGGSfM`, `VGGT`) that can emit compatible camera/point outputs.
5. If bundle adjustment is needed, allow lightweight backend calls without exposing COLMAP complexity to users.
6. On Windows, if the current stable COLMAP binary does not expose `global_mapper`, allow standalone `GLOMAP` as the practical benchmark fallback until released COLMAP binaries catch up.

### 8.3 Candidate Backend Evaluation (Required)
Evaluate at least 2 alternatives against project datasets:
- VGGSfM
- COLMAP `global_mapper`
- standalone `GLOMAP` (Windows fallback if integrated `global_mapper` is not exposed in released binaries)
- MASt3R-SfM
- VGGT/other feed-forward fast geometry candidate
- LichtFeld Studio (training/backend execution layer after sparse reconstruction)

Selection criteria:
- Runtime on target hardware
- Reconstruction robustness on site imagery
- Integration complexity on Windows
- Reproducibility and failure behavior

### 8.4 Production Acceptance Criteria
1. Consumes preview handoff artifacts directly.
2. Produces a stable scene output and publish package.
3. Provides quality summary and reproducibility metadata.

## 9. Spark 2.0 And `.rad` Requirements
1. Treat `.rad` as a publish/runtime format for LoD streaming, not the master training format.
2. Pipeline must support output profiles:
   - `Local Review`: `.ply` / `.spz`
   - `Web Share Large Scene`: LoD build + `.rad`
3. Renderer integration must support paged loading for large scenes.

## 10. Security, Compliance, And Governance
1. Local-first processing by default.
2. Explicit controls for any cloud/off-device processing.
3. Project-level audit metadata:
   - tool versions
   - model/backend version
   - timestamps
   - operator ID (if available)
4. No silent data exfiltration; network usage must be visible/configurable.

## 11. Deployment Requirements (High Priority)
1. Installer options:
   - standard install (admin available)
   - portable/user-space mode (no-admin)
2. One-shot setup workflow:
   - single installer or bootstrap launcher that installs pinned dependencies/tools
   - GPU/driver capability check and clear pass/fail report
   - model/artifact download with checksum verification
   - post-install self-test that runs a tiny sample job end-to-end
3. Offline package mode for dependencies/models where possible.
4. Proxy-aware networking config.
5. Existing installation policy support (`reuse`, `upgrade`, `replace`) for installer-managed components, without unsafe auto-removal of system drivers/tools.

## 12. Performance Targets (Initial)
- Preview turnaround: first usable result <= 10 minutes for typical small/medium job.
- Production turnaround: same-day completion target for typical project on approved hardware.
- Memory/disk checks must run before job start and report expected resource usage.

## 13. Observability And Support
1. User-friendly status indicators per stage.
2. Structured logs for support (`logs/*.jsonl`).
3. One-click export of support bundle (logs + config + metadata, no raw images unless chosen).

## 13.1 Long-Running Job Requirements
1. The pipeline must support jobs that run for many hours on laptop-class hardware.
2. Long-running jobs must support detached/background execution so the operator is not required to keep a terminal session active.
3. Each major stage must write durable logs and machine-readable state so partial progress is not lost.
4. The system must support resume from the last completed stage after interruption, timeout, or user relaunch.
5. Job status must be inspectable without attaching to the original console session.
6. Timeouts imposed by wrapper scripts or UI shells must not be treated as pipeline failure if the underlying stage is still progressing.

## 14. Risks And Open Decisions
1. **Setup complexity:** multi-tool Windows environments can fail without strict version pinning and automated validation.
2. **Hardware floor:** define minimum GPU/VRAM and CPU/RAM profiles for supported laptops.
3. **Cloud policy:** determine whether burst compute is permitted for production jobs.
4. **Accuracy requirements:** define whether visual realism only or metric constraints are required.
5. **Licensing:** tracked for later commercialization/deployment phase; not a research-phase blocker.

## 15. Implementation Order
1. Build Preview Path end-to-end with culling + quick preview + go/no-go decision.
2. Add handoff artifact contract and schema validation.
3. Implement one-shot installer/bootstrap + environment self-test.
4. Integrate production backend candidates and benchmark.
5. Add Spark LoD `.rad` publish stage.
6. Harden deployment, logging, and support tooling.

## 16. Definition Of Done (v1)
v1 is complete when:
1. Non-technical user can run Preview Path and get actionable decision output.
2. Production can consume preview artifacts and generate a publishable splat package.
3. Spark-compatible large-scene output (including `.rad`) is generated for at least one representative dataset.
4. Process is documented and repeatable on Windows 10/11 managed laptops.
5. Setup from clean laptop to first sample preview run is reliable via one-shot workflow.

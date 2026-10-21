# Benchmark Harness

This folder contains the first reproducible benchmark harness for the 360GS project.

## Purpose
- Move from ad hoc image tests to repeatable runs against named datasets.
- Record run metadata, input counts, output counts, and duration.
- Reuse the managed local `sharp-preview` runtime that is already installed under `%LOCALAPPDATA%\360GS`.

## Files
- `..\config\datasets.local.json`: preferred machine-specific dataset registry.
- `..\config\datasets.example.json`: template dataset registry for new machines.
- `..\EXAMPLE_DATASET_LINK.md`: source note for public example datasets that stay out of Git.
- `datasets.standard.json`: legacy dataset registry snapshot kept for compatibility.
- `Run-Benchmark.ps1`: benchmark runner for managed SHARP preview runs.
- `Stage-Dataset.ps1`: stages a named benchmark dataset into a controlled image folder for repeatable pipeline tests.
- `Run-GlomapBenchmark.ps1`: multi-view benchmark runner using `COLMAP` feature extraction/matching plus standalone `GLOMAP` mapping.
- `Run-ColmapGlobalBenchmark.ps1`: reserved runner for future COLMAP integrated `global_mapper` testing when the installed Windows binary exposes that command.
- `Start-GlomapBenchmarkJob.ps1`: launches a detached/background GLOMAP benchmark job for long-running runs.
- `Get-BenchmarkJobStatus.ps1`: checks current job state and whether resume is needed.
- `..\OPERATOR_WORKFLOW.md`: copy/paste guide for non-PowerShell users.
- `..\artifacts\benchmark\results\`: generated benchmark runs for new executions.
- `..\artifacts\benchmark\staged\`: generated staged datasets and manifests for new executions.
- `..\artifacts\benchmark\jobs\`: detached job metadata, stdout, and stderr logs for new executions.
- `results/`, `staged/`, `jobs/`: legacy artifact folders kept only so older runs still work.

## Current Scope
This first harness targets the current working preview path:
- single-image / preview benchmarking with Apple SHARP

Current multi-view benchmark status:
- `GLOMAP` standalone path is working on Windows.
- `COLMAP global_mapper` is not currently exposed by the installed `COLMAP 3.13.0` Windows CUDA binary on this machine, despite repository-level migration language.
- `VGGSfM` is not yet integrated.

## Standard Dataset Workflow
For multi-view benchmark scenes, first stage a controlled input set:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\Stage-Dataset.ps1 -DatasetId mipnerf360-bicycle -MaxImages 24
```

This creates a stable staged folder with:
- `images\`
- `stage_manifest.json`

New runs default to:
- `artifacts\benchmark\staged\...`

For this laptop, `mipnerf360-bicycle` with `images_4` and `24-48` images is the right first-scale test before trying larger runs.

## First Working Multi-View Benchmark
Run the current working fast-global path:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\Run-GlomapBenchmark.ps1 -StagedDatasetPath ..\artifacts\benchmark\staged\mipnerf360-bicycle_images_4_n24_s1_o0 -UseGpu
```

This uses:
- `COLMAP feature_extractor`
- `COLMAP sequential_matcher`
- `GLOMAP mapper`

## Long-Running Usage
For hours-long runs, launch detached:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\Start-GlomapBenchmarkJob.ps1 -StagedDatasetPath ..\artifacts\benchmark\staged\mipnerf360-bicycle_images_4_n24_s1_o0 -UseGpu
```

Check status later:

```powershell
.\Get-BenchmarkJobStatus.ps1 -Latest
```

Resume a stopped run by relaunching `Run-GlomapBenchmark.ps1` with the same `-RunRoot` and `-Resume` arguments. The runner now tracks completed stages in `run_state.json`.

## Example Commands
From the `benchmark` folder:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\Run-Benchmark.ps1 -DatasetId sharp-single-image-smoke -UseCheckpointCache
```

To run a custom local dataset folder:

```powershell
.\Run-Benchmark.ps1 -DatasetId sharp-single-image-smoke -DatasetPath C:\datasets\my_test_folder -UseCheckpointCache
```

To intentionally include nested image folders:

```powershell
.\Run-Benchmark.ps1 -DatasetId sharp-single-image-smoke -DatasetPath C:\datasets\my_test_folder -AllowRecursiveImages -UseCheckpointCache
```

## Output Contract
Each run creates:
- `..\artifacts\benchmark\results\<dataset_id>_<timestamp>\input\`
- `..\artifacts\benchmark\results\<dataset_id>_<timestamp>\pipeline_output\`
- `..\artifacts\benchmark\results\<dataset_id>_<timestamp>\benchmark_report.json`

## Near-Term Next Step
- Add handoff from working sparse reconstruction output into `LichtFeld Studio` as the first actual 3DGS training backend.
- Add quality metrics and viewer launch hooks.

## LichtFeld Training

Use Start-LichtFeldTrainingJob.ps1 to launch detached training from an existing staged dataset and sparse COLMAP or GLOMAP model. Use Get-LichtFeldTrainingJobStatus.ps1 -Latest to inspect progress.

# Developer Setup Guide

This guide is written for someone with basic or slightly elevated technical experience.

## 1. What Belongs In Source vs Artifacts
- Source: scripts, docs, config templates, and viewer assets.
- Artifacts: staged datasets, benchmark jobs, benchmark results, downloaded dataset bundles, and scratch outputs.

The project now defaults new benchmark artifacts to:

`artifacts\benchmark` (relative to the repository or install root)

## 2. Local Dataset Config
Machine-specific dataset paths live in:

`config\datasets.local.json`

Template file:

`config\datasets.example.json`

If a teammate uses a different machine, they should edit only `datasets.local.json`. Dataset `local_path` values may be relative; relative paths resolve against the repository (or install) root, for example `datasets/mipnerf360/360_v2/bicycle`.

Dataset source note:

`EXAMPLE_DATASET_LINK.md`

Use that file to see where the tracked example datasets originally came from without committing the actual dataset contents.

## 3. Safe Working Rules
- Do not delete old `benchmark\jobs`, `benchmark\results`, or `benchmark\staged` folders unless you have confirmed they are not needed.
- Prefer installer-managed tools under the chosen install root. The current default pattern is `%LOCALAPPDATA%\360GS`, but do not assume that path in operator-facing guidance.
- Keep large datasets and generated outputs out of Git.
- Keep `EXAMPLE_DATASET_LINK.md` updated if the project starts using additional public reference datasets.
- Keep public-facing docs professional and external-facing. Lead with project purpose and operator guidance before internal implementation detail.
- In operator-facing docs, prefer `<chosen install folder>\...` over hardcoded `C:\Users\...\AppData\Local\360GS\...` examples unless you are recording a real validation artifact from one machine.
- Keep all file paths in docs and config relative to the repository or install root. Never commit machine-specific paths, usernames, or personal contact details.
- Keep project files tool-neutral: do not commit assistant-specific instruction files or name specific AI models or products in code or docs.
- Before accepting remote doc changes, check whether they accidentally regress the professional/public-facing structure of `README.md`, installer docs, or operator docs.
- Before committing large PowerShell diffs after a merge, verify whether they are real content changes or line-ending churn with an end-of-line-insensitive diff first.

## 4. Basic Script Entry Points
From:

the `benchmark` folder

Common scripts are:
- `Stage-Dataset.ps1`
- `Start-GlomapBenchmarkJob.ps1`
- `Get-BenchmarkJobStatus.ps1`
- `Start-LichtFeldTrainingJob.ps1`
- `Get-LichtFeldTrainingJobStatus.ps1`

## 5. Compatibility Note
The scripts now prefer the new `artifacts\benchmark` folders for new runs, but they still recognize legacy benchmark folders when reading existing runs.

# Windows 11 Validation Checklist

Use this checklist when validating 360GS on a Windows 11 machine for the first time.

## Purpose
- confirm the repository can be obtained cleanly
- confirm the installer behavior is correct on Windows 11
- confirm the machine is either ready for the full operator workflow or blocked with clear remediation
- confirm the installed app launches and the simplest operator path works

## 1. Get The Source
- Download the latest repository ZIP from GitHub or clone the repository.
- Extract it to a simple local path such as:
  `C:\360GS\360gs-2026-main`
- Open:
  `C:\360GS\360gs-2026-main\README.md`

## 2. Preflight Expectations
- Confirm the machine is Windows 11.
- Confirm the machine has network access for installer downloads, unless you are testing an offline bundle.
- If the machine has an NVIDIA GPU, note the current NVIDIA driver version.

## 3. Run The Installer
- Double-click:
  `C:\360GS\360gs-2026-main\Install-360GS.cmd`
- Confirm the native Windows installer dialog opens.
- Confirm the default install path is populated.
- Click `Install 360GS`.

## 4. Record The Outcome
- If install succeeds:
  - note the install folder
  - click `Launch 360GS`
- If install fails:
  - copy the exact remediation text shown in the installer
  - record the latest files under:
    `<install folder>\logs`
  - stop and classify the failure before trying unrelated fixes

## 5. Current Validation Note
- Windows 11 has now been validated successfully after the required NVIDIA driver update and follow-up repo fixes.
- The full operator install still depends on the expected NVIDIA driver/runtime level for the LichtFeld portion of the workflow.
- If a future Windows 11 machine hits a readiness block, record the exact message, update the driver/runtime as needed, and rerun the installer instead of working around the gate manually.

## 6. Launch Validation
- After a successful install, launch:
  `<install folder>\run360gs.cmd`
- Confirm the local app opens.
- Confirm the page loads without stale frontend errors.

## 7. Simple Workflow Validation
- Use a small image-only folder first.
- In the app:
  1. enter the folder path
  2. click `Check Folder`
  3. choose `Fast-preview`
  4. click `Create Splat!`
- Confirm the app does one of these:
  - starts the workflow normally
  - blocks early with a clear missing-tools or readiness message

## 8. What Counts As Pass
- The installer opens normally on Windows 11.
- The machine either:
  - completes a full install successfully, or
  - stops with clear remediation text before leaving a misleading partial operator install.
- The installed app launches.
- The simplest image-folder workflow is either runnable or blocked with a clear, correct explanation.
- For a fully ready machine, the preferred outcome is a real successful `Check Folder` and `Create Splat!` path, not just a readiness block.

## 9. What To Capture For Follow-Up
- Windows edition and build
- NVIDIA driver version
- CUDA/runtime information reported by the installer, if shown
- exact install failure or readiness message
- path to the latest install report/log
- whether `Check Folder` and `Create Splat!` worked after install

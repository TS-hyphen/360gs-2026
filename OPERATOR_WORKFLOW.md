# 360GS Operator Workflow

This guide is written for a non-technical operator.

Use the double-click files exactly as listed here. You do not need to open PowerShell for the normal workflow.

## 1. Install The App

If 360GS is not installed yet, double-click `Install-360GS.cmd` in the 360GS package folder.

What this does:
- opens the 360GS installer dialog
- asks you to choose the installation folder
- shows simple status updates while files are downloaded, installed, and validated
- installs the full operator tool bundle needed for `Create Splat!`
- enables the app launch button only after installation completes successfully
- if 360GS is already installed and current, it reports that the app is ready and no updates were needed

Important:
- the install can take a little time because the app may need to download tools, install files, and run validation checks
- the default install includes staging, sparse reconstruction, and LichtFeld training tools so the app is ready to run a full image workflow after install
- do not close the installer window while installation is running

## 2. Choose The Installation Folder

In the installer dialog:

1. Review the `Installation Folder` field.
2. Click `Browse...` if you want a different folder.
3. Click `Install 360GS`.

The installer keeps the folder field locked while install is running.

Important:
- do not choose the 360GS source-package folder itself as the install location
- after install succeeds, the chosen installation folder stays fixed for that installer session
- the default follows this per-user pattern:
  `%LOCALAPPDATA%\360GS`

## 3. Launch The App

After install completes, click `Launch 360GS` in the installer dialog.

You can also double-click:

`<chosen install folder>\run360gs.cmd`

What this does:
- starts the local-only 360GS web app
- opens the browser to the local page
- keeps all work on the local machine

## 4. Use The Simple Workflow For Image Folders

On the page:

1. In `Image Folder Path`, paste the path to a folder that contains still images.
2. Click `Check Folder`.
3. Wait for the folder summary and quality choices to unlock.
4. Choose one of:
   - `Fast-preview`
   - `Medium`
   - `High`
5. Click `Create Splat!`

The app then runs:
- managed image staging
- sparse reconstruction
- LichtFeld training

You do not need to start the sparse or training steps separately when using the simple workflow.

If the machine runs short on GPU memory during LichtFeld training, 360GS may automatically retry with a lower-memory tile mode.

Important:
- this fallback can run slower
- it may slightly change result quality
- the workflow card will say when lower-memory training mode is active or was used

## 5. What The Quality Buttons Mean

`Fast-preview`
- quickest confidence check
- uses a reduced image sample
- runs a shorter training pass

`Medium`
- balanced default for a better result without the longest wait

`High`
- uses the most images and the longest training run

The app shows a rough time estimate after `Check Folder`.

## 6. Read The Workflow Status Panel

The `Workflow Status` panel shows:
- current workflow id
- whether it is `queued`, `running`, `completed`, or `failed`
- stage markers:
  - `Ready`
  - `Stage Images`
  - `Sparse Model`
  - `Train Splat`
  - `Complete`
- the staged-copy location
- the latest splat path after completion

Buttons on the status card can open:
- the staged folder
- the sparse job folder
- the training job folder
- the latest splat folder

If a run is still active, the status card also shows a `Cancel` button next to the running state.

What cancel does:
- stops the current simple workflow
- asks you to confirm before anything is stopped
- then asks whether 360GS should also delete the working copy and other files it created for that run
- never deletes the original source imagery folder you started from

## 7. Where The Output Files Go

The install root is the folder you selected in the installer dialog.

By default this is `%LOCALAPPDATA%\360GS`.

The main operator-facing locations are:

- launcher:
  `<chosen install folder>\run360gs.cmd`
- install logs:
  `<chosen install folder>\logs`

The main output areas are:

- staged datasets:
  `<chosen install folder>\artifacts\benchmark\staged`
- sparse jobs:
  `<chosen install folder>\artifacts\benchmark\jobs`
- workflow records:
  `<chosen install folder>\artifacts\benchmark\workflows`

The final splat file for a completed run will be inside the training job folder, under:

`run\training_output\splat_<iteration>.ply`

Example:

`<chosen install folder>\artifacts\benchmark\jobs\lichtfeld-<timestamp>\run\training_output\splat_6000.ply`

## 8. View The Result In LichtFeld Studio

To open the supported local viewer, double-click:

`<chosen install folder>\openlichtfeld.cmd`

You can also use the Start Menu shortcut:

`360GS LichtFeld Studio`

Then open the `.ply` file from the training output folder.

If a run is already completed in `Recent Workflow History`, click:

`View Splat`

That button opens the saved `.ply` file directly in LichtFeld Studio.

## 9. Working With Old Runs

The right side of the page shows:
- the currently active simple workflow
- `Recent Workflow History`

Use:
- `Dismiss History Item` to remove one old history record
- `Clear Old History` to remove old completed or failed workflow records

Important:
- these history cleanup actions remove workflow records only
- they do not delete your original source images
- they do not delete completed sparse job folders or splat outputs

## 10. Advanced Options

Open `Advanced Options` only when you need manual control.

Advanced sections currently include:
- `Prepare Media`
- `Stage Dataset`
- `Latest Staged Datasets`
- `Start Sparse Reconstruction`
- `Completed Sparse Results`
- `Start LichtFeld Training`

Use advanced mode if you need to:
- prepare video into staged frames
- stage a dataset manually
- start sparse reconstruction manually
- start LichtFeld training manually
- inspect or delete a managed staged copy

## 11. Video Handling

The simple workflow is image-only.

If you point the simple workflow at a folder that contains video files:
- the app will warn that simple mode is blocked
- quality selection will stay disabled
- `Create Splat!` will stay disabled

For video, use:

`Advanced Options` -> `Prepare Media`

Supported advanced media v1:
- standard video
- exported equirectangular 360 video

Not supported directly in v1:
- raw Insta360/proprietary capture files such as `.insv`

## 12. If A Run Fails

If the status panel shows `failed`:

1. Read the error text in the workflow card.
2. Open the job folder from the workflow card.
3. Check the latest sparse or training logs under the job's `run\logs` folder.
4. Keep the original image folder unchanged.
5. Retry from the app after correcting the problem.

If the error mentions lower-memory tile mode:
- the app already tried a slower lower-memory fallback
- retrying the same folder unchanged may not help if the machine still does not have enough VRAM
- the most practical next steps are fewer images, smaller images, or a machine with more GPU memory

If the page shows old completed or failed records from a previous session, use `Recent Workflow History` cleanup so the current run is easier to read.

## 13. Current Validated Simple-Workflow Smoke Test

Validated on 2026-03-13 using the installed app path:

- source image folder:
  `datasets\mipnerf360\360_v2\bicycle\images_4`
- selected quality:
  `Fast-preview`
- workflow id:
  `workflow-20260313-064945`
- staged dataset:
  `<chosen install folder>\artifacts\benchmark\staged\adhoc-images-4-20260313-064946`
- sparse job:
  `<chosen install folder>\artifacts\benchmark\jobs\glomap-20260313-064947`
- training job:
  `<chosen install folder>\artifacts\benchmark\jobs\lichtfeld-20260313-065015`
- final splat:
  `<chosen install folder>\artifacts\benchmark\jobs\lichtfeld-20260313-065015\run\training_output\splat_6000.ply`

This is the current reference that the installed GUI workflow is functioning end-to-end for an image-only run.

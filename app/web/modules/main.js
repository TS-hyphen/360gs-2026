import { fetchJson, postJson } from "./api.js";
import { elements } from "./dom.js";
import {
  renderAll,
  renderCancelDialog,
  renderFolderSummary,
  renderMediaQualityExplain,
  renderQualityExplain,
  setMessage,
  updateBusyBanner,
  workflowIsActive,
} from "./render.js";
import { state } from "./state.js";

function setBusy(active, button = null, options = {}) {
  const { busyLabel = "", message = "" } = options;
  state.busyCount += active ? 1 : -1;
  state.busyCount = Math.max(0, state.busyCount);
  document.body.classList.toggle("busy", state.busyCount > 0);

  if (button) {
    if (active) {
      if (!button.dataset.originalLabel) {
        button.dataset.originalLabel = button.textContent;
      }
      if (busyLabel) {
        button.textContent = busyLabel;
      }
      button.classList.add("busy");
      button.disabled = true;
    } else {
      if (button.dataset.originalLabel) {
        button.textContent = button.dataset.originalLabel;
        delete button.dataset.originalLabel;
      }
      button.classList.remove("busy");
      button.disabled = false;
    }
  }

  if (active) {
    state.busyMessage = message || busyLabel || "Working...";
  } else if (state.busyCount === 0) {
    state.busyMessage = "";
  }
  updateBusyBanner();
}

function clearDeleteArm(render = true) {
  if (state.deleteConfirmTimer) {
    window.clearTimeout(state.deleteConfirmTimer);
    state.deleteConfirmTimer = 0;
  }
  if (!state.deleteConfirmPath) {
    return;
  }
  state.deleteConfirmPath = "";
  if (render) {
    renderAll();
  }
}

function armDelete(stageRoot) {
  clearDeleteArm(false);
  state.deleteConfirmPath = stageRoot;
  state.deleteConfirmTimer = window.setTimeout(() => clearDeleteArm(), 8000);
  renderAll();
  setMessage("Delete is ready for 8 seconds. Click the same button again to remove only the working copy made by 360GS.");
}

function openCancelDialog(workflowId) {
  state.cancelWorkflowId = workflowId;
  state.cancelDialogStep = "confirm";
  state.cancelDialogOpen = true;
  renderCancelDialog();
}

function closeCancelDialog() {
  state.cancelDialogOpen = false;
  state.cancelDialogStep = "confirm";
  state.cancelWorkflowId = "";
  renderCancelDialog();
}

async function refreshAll(silent = false) {
  if (!silent) {
    setMessage("Refreshing status...");
  }
  state.overview = await fetchJson("/api/overview");
  const activeWorkflow = state.overview?.active_workflow;
  const activeWorkflowId = activeWorkflow?.workflow_id || "";
  const activeWorkflowRunning = Boolean(activeWorkflow && ["queued", "running"].includes(activeWorkflow.status));
  if (state.cancelDialogOpen && (!activeWorkflowRunning || activeWorkflowId !== state.cancelWorkflowId)) {
    closeCancelDialog();
  }
  renderAll();
  if (!silent) {
    setMessage("Status refreshed.");
  }
}

async function checkFolder(button) {
  try {
    setBusy(true, button, { busyLabel: "Checking...", message: "Checking the selected folder..." });
    const payload = await postJson("/api/actions/inspect-folder", {
      folder_path: elements.simpleFolderPath().value,
    });
    state.inspectedFolder = payload;
    renderFolderSummary();
    if (payload.video_count) {
      setMessage(payload.video_notice || "Video import is limited to Advanced Options.");
    } else if (payload.simple_workflow_ready === false) {
      setMessage(payload.simple_mode_blocked_reason || "This install is missing required pipeline tools.");
    } else {
      setMessage(`Folder is ready. Found ${payload.image_count} images.`);
    }
  } catch (error) {
    state.inspectedFolder = null;
    renderFolderSummary();
    setMessage(error.message, true);
  } finally {
    setBusy(false, button);
  }
}

async function clearWorkflowHistory(button) {
  try {
    setBusy(true, button, { busyLabel: "Clearing...", message: "Removing older items from the list..." });
    const result = await postJson("/api/actions/clear-workflow-history", {
      remove_failed: true,
      remove_completed: true,
    });
    setMessage(result.message);
    await refreshAll(true);
  } catch (error) {
    setMessage(error.message, true);
  } finally {
    setBusy(false, button);
  }
}

async function deleteStage(stageRoot, button) {
  try {
    setBusy(true, button, { busyLabel: "Deleting...", message: "Deleting the working copy..." });
    const result = await postJson("/api/actions/delete-staged", { stage_root: stageRoot });
    clearDeleteArm(false);
    setMessage(result.message);
    await refreshAll(true);
  } catch (error) {
    setMessage(error.message, true);
  } finally {
    setBusy(false, button);
  }
}

async function removeWorkflowRecord(workflowId, button) {
  try {
    setBusy(true, button, { busyLabel: "Removing...", message: "Removing the selected item from the list..." });
    const result = await postJson("/api/actions/delete-workflow", { workflow_id: workflowId });
    setMessage(result.message);
    await refreshAll(true);
  } catch (error) {
    setMessage(error.message, true);
  } finally {
    setBusy(false, button);
  }
}

async function openFolder(path) {
  try {
    const result = await postJson("/api/actions/open-folder", { path });
    setMessage(result.message);
  } catch (error) {
    setMessage(error.message, true);
  }
}

async function viewSplat(splatPath) {
  try {
    const result = await postJson("/api/actions/open-splat", { splat_path: splatPath });
    setMessage(result.message);
  } catch (error) {
    setMessage(error.message, true);
  }
}

async function cancelWorkflow(deleteGenerated, button) {
  try {
    if (!state.cancelWorkflowId) {
      throw new Error("No running workflow is selected.");
    }
    setBusy(true, button, {
      busyLabel: "Working...",
      message: deleteGenerated
        ? "Canceling the workflow and removing its 360GS working files..."
        : "Canceling the workflow...",
    });
    const result = await postJson("/api/actions/cancel-workflow", {
      workflow_id: state.cancelWorkflowId,
      delete_generated: deleteGenerated,
    });
    closeCancelDialog();
    setMessage(
      deleteGenerated
        ? "The workflow was canceled and its 360GS working files were removed. Your source imagery was kept."
        : "The workflow was canceled. The 360GS working files were kept, and your source imagery was kept."
    );
    if (result?.message) {
      await refreshAll(true);
    }
  } catch (error) {
    setMessage(error.message, true);
  } finally {
    setBusy(false, button);
  }
}

async function inspectMedia(button) {
  try {
    setBusy(true, button, { busyLabel: "Analyzing...", message: "Inspecting the selected media..." });
    const payload = await postJson("/api/actions/inspect-media", {
      source_path: elements.mediaSourcePath().value,
    });
    state.inspectedMedia = payload;
    renderAll();
    setMessage(payload.recommended_quality_reason || payload.video_notice || "Media analysis is ready.");
  } catch (error) {
    state.inspectedMedia = null;
    renderAll();
    setMessage(error.message, true);
  } finally {
    setBusy(false, button);
  }
}

async function prepareMedia(button) {
  try {
    if (!state.inspectedMedia) {
      throw new Error("Analyze media first.");
    }
    if (!state.inspectedMedia.supported_for_prepare) {
      throw new Error(state.inspectedMedia.video_notice || "This source is not supported for advanced video preparation.");
    }
    setBusy(true, button, { busyLabel: "Preparing...", message: "Preparing frames from the selected media..." });
    const result = await postJson("/api/actions/prepare-media", {
      source_path: elements.mediaSourcePath().value,
      quality: elements.mediaQuality().value,
    });
    setMessage(`${result.message} ${result.stage_root || ""}`.trim());
    await refreshAll(true);
  } catch (error) {
    setMessage(error.message, true);
  } finally {
    setBusy(false, button);
  }
}

function bindSimpleWorkflow() {
  elements.inspectFolder().addEventListener("click", async (event) => {
    await checkFolder(event.currentTarget);
  });

  elements.simpleFolderPath().addEventListener("input", (event) => {
    const value = event.currentTarget.value.trim();
    if (state.inspectedFolder && value !== state.inspectedFolder.folder_path) {
      state.inspectedFolder = null;
      renderFolderSummary();
    }
  });

  elements.qualityMode().addEventListener("change", () => {
    renderQualityExplain();
  });

  elements.simpleForm().addEventListener("submit", async (event) => {
    event.preventDefault();
    const button = elements.createSplat();
    try {
      if (!state.inspectedFolder) {
        throw new Error("Check the folder first.");
      }
      if (workflowIsActive()) {
      throw new Error("A simple workflow is already running.");
      }
      setBusy(true, button, { busyLabel: "Starting...", message: "Starting the Create Splat workflow..." });
      const result = await postJson("/api/actions/create-splat", {
        folder_path: elements.simpleFolderPath().value,
        quality: elements.qualityMode().value,
      });
      setMessage(`${result.message} ${result.workflow_id}`);
      await refreshAll(true);
    } catch (error) {
      setMessage(error.message, true);
    } finally {
      setBusy(false, button);
    }
  });
}

function bindAdvancedForms() {
  elements.mediaInspect().addEventListener("click", async (event) => {
    await inspectMedia(event.currentTarget);
  });

  elements.mediaSourcePath().addEventListener("input", (event) => {
    const value = event.currentTarget.value.trim();
    if (state.inspectedMedia && value !== state.inspectedMedia.source_path) {
      state.inspectedMedia = null;
      renderAll();
    }
  });

  elements.mediaQuality().addEventListener("change", () => {
    renderMediaQualityExplain();
  });

  elements.mediaForm().addEventListener("submit", async (event) => {
    event.preventDefault();
    await prepareMedia(elements.prepareMedia());
  });

  elements.stageForm().addEventListener("submit", async (event) => {
    event.preventDefault();
    const button = event.submitter;
    try {
      setBusy(true, button, { busyLabel: "Preparing...", message: "Preparing the photo set..." });
      const result = await postJson("/api/actions/stage", {
        dataset_id: elements.datasetId().value,
        variant: elements.variant().value,
        max_images: elements.maxImages().value,
        stride: elements.stride().value,
        start_index: elements.startIndex().value,
      });
      setMessage(result.message);
      await refreshAll(true);
    } catch (error) {
      setMessage(error.message, true);
    } finally {
      setBusy(false, button);
    }
  });

  elements.glomapForm().addEventListener("submit", async (event) => {
    event.preventDefault();
    const button = event.submitter;
    try {
      setBusy(true, button, { busyLabel: "Starting...", message: "Building the camera layout..." });
      const result = await postJson("/api/actions/start-glomap", {
        staged_dataset_path: elements.glomapStage().value,
        matcher: elements.glomapMatcher().value,
        sift_max_image_size: elements.siftMaxImageSize().value,
        random_seed: elements.randomSeed().value,
        use_gpu: elements.useGpu().checked,
        single_camera: elements.singleCamera().checked,
      });
      setMessage(`${result.message} ${result.job_id || ""}`.trim());
      await refreshAll(true);
    } catch (error) {
      setMessage(error.message, true);
    } finally {
      setBusy(false, button);
    }
  });

  elements.lichtfeldForm().addEventListener("submit", async (event) => {
    event.preventDefault();
    const button = event.submitter;
    try {
      setBusy(true, button, { busyLabel: "Starting...", message: "Building the final model..." });
      const result = await postJson("/api/actions/start-lichtfeld", {
        staged_dataset_path: elements.lichtfeldStage().value,
        sparse_model_path: elements.sparseModel().value,
        strategy: elements.strategy().value,
        images_mode: elements.imagesMode().value,
        iterations: elements.iterations().value,
      });
      setMessage(`${result.message} ${result.job_id || ""}`.trim());
      await refreshAll(true);
    } catch (error) {
      setMessage(error.message, true);
    } finally {
      setBusy(false, button);
    }
  });
}

function bindToolbarActions() {
  elements.clearWorkflowHistory().addEventListener("click", async (event) => {
    await clearWorkflowHistory(event.currentTarget);
  });

  elements.cancelModalNo().addEventListener("click", async (event) => {
    if (state.cancelDialogStep === "cleanup") {
      await cancelWorkflow(false, event.currentTarget);
      return;
    }
    closeCancelDialog();
  });

  elements.cancelModalYes().addEventListener("click", async (event) => {
    if (state.cancelDialogStep === "cleanup") {
      await cancelWorkflow(true, event.currentTarget);
      return;
    }
    state.cancelDialogStep = "cleanup";
    renderCancelDialog();
  });
}

function bindDelegatedActions() {
  document.body.addEventListener("click", async (event) => {
    const target = event.target;
    if (!(target instanceof HTMLButtonElement)) {
      return;
    }

    const deleteStagePath = target.dataset.deleteStage;
    if (deleteStagePath) {
      if (state.deleteConfirmPath !== deleteStagePath) {
        armDelete(deleteStagePath);
        return;
      }
      await deleteStage(deleteStagePath, target);
      return;
    }

    const workflowId = target.dataset.deleteWorkflow;
    if (workflowId) {
      await removeWorkflowRecord(workflowId, target);
      return;
    }

    const cancelWorkflowId = target.dataset.cancelWorkflow;
    if (cancelWorkflowId) {
      openCancelDialog(cancelWorkflowId);
      return;
    }

    const folder = target.dataset.openFolder;
    if (folder) {
      await openFolder(folder);
      return;
    }

    const splatPath = target.dataset.viewSplat;
    if (splatPath) {
      await viewSplat(splatPath);
    }
  });
}

function startAutoRefresh() {
  window.setInterval(async () => {
    try {
      await refreshAll(true);
    } catch {
      // Keep silent during background refreshes.
    }
  }, 5000);
}

export async function initApp() {
  bindSimpleWorkflow();
  bindAdvancedForms();
  bindToolbarActions();
  bindDelegatedActions();
  try {
    await refreshAll();
  } catch (error) {
    setMessage(error.message, true);
  }
  startAutoRefresh();

  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && state.cancelDialogOpen) {
      closeCancelDialog();
    }
  });
}

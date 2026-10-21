import { elements } from "./dom.js";
import { state } from "./state.js";
import { escapeHtml, formatWorkflowTime, parentPath } from "./utils.js";

function workflowStatusClass(status) {
  if (status === "failed") {
    return "error";
  }
  if (status === "canceled") {
    return "cancel";
  }
  if (status === "completed") {
    return "";
  }
  return "warn";
}

export function workflowIsActive() {
  const workflow = state.overview?.active_workflow;
  return Boolean(workflow && ["queued", "running"].includes(workflow.status));
}

export function updateBusyBanner() {
  const banner = elements.busyBanner();
  const active = state.busyCount > 0;
  banner.hidden = !active;
  banner.textContent = active ? state.busyMessage || "Working..." : "";
}

export function setMessage(message, isError = false) {
  const el = elements.globalMessage();
  el.textContent = message || "";
  el.dataset.error = isError ? "true" : "false";
}

function summarizeStatus(status) {
  if (!status) {
    return `<p class="card muted-card">Nothing has run yet.</p>`;
  }
  const className = workflowStatusClass(status.status);
  const fallbackNote =
    status.memory_fallback_active && status.memory_fallback_tile_mode
      ? `Lower-memory tile fallback is active (tile mode ${status.memory_fallback_tile_mode}). This can run slower and may slightly change result quality.`
      : status.memory_fallback_completed && status.memory_fallback_tile_mode
        ? `Completed using lower-memory tile mode ${status.memory_fallback_tile_mode}. It may have taken longer, and result quality may vary slightly.`
        : status.memory_fallback_used && status.memory_fallback_tile_mode
          ? `Used lower-memory tile mode ${status.memory_fallback_tile_mode}. It may run slower and result quality may vary slightly.`
          : "";
  return `
    <article class="card status-card">
      <div class="status-head">
        <h3>${escapeHtml(status.job_id || "Unknown job")}</h3>
        <span class="status-pill ${className}">${escapeHtml(status.status)}</span>
      </div>
      <p><strong>Saved in:</strong> <span class="mono">${escapeHtml(status.run_root || "")}</span></p>
      ${fallbackNote ? `<p><strong>Training mode:</strong> ${escapeHtml(fallbackNote)}</p>` : ""}
      <div class="row-actions">
        ${status.job_root ? `<button class="ghost" data-open-folder="${escapeHtml(status.job_root)}">Open Run Folder</button>` : ""}
        ${status.output_path ? `<button class="ghost" data-open-folder="${escapeHtml(status.output_path)}">Open Output Folder</button>` : ""}
        ${status.latest_splat ? `<button class="accent" data-view-splat="${escapeHtml(status.latest_splat)}">View Splat</button>` : ""}
      </div>
    </article>
  `;
}

export function renderInstallStatus() {
  const container = elements.installStatus();
  const info = state.overview.status;
  const windowsLabel = info.windows
    ? `${info.windows.product_name} (${info.windows.support_label}) build ${info.windows.build}${info.windows.display_version ? ` / ${info.windows.display_version}` : ""}`
    : "Unknown";
  const rows = [
    ["Windows", windowsLabel],
    ["Installed In", info.install_root],
    ["Create Splat", info.simple_workflow_ready ? "Ready" : "Needs Repair"],
    ["Photo Matching", info.has_colmap_global && info.has_glomap_standalone ? "Ready" : "Needs Repair"],
    ["LichtFeld Viewer", info.has_lichtfeld ? "Ready" : "Not installed"],
    ["Video Import", info.has_ffmpeg_tools ? "Ready" : "Not installed"],
    ["Saved Results", info.results_root],
  ];
  container.innerHTML = rows
    .map(
      ([label, value]) => `
        <article class="fact-tile">
          <span>${escapeHtml(label)}</span>
          <strong>${escapeHtml(value)}</strong>
        </article>
      `
    )
    .join("");
}

export function renderLatestJobs() {
  const container = elements.latestJobs();
  container.innerHTML = `
    <div class="status-stack">
      <h3>Latest Camera Layout</h3>
      ${summarizeStatus(state.overview.latest_glomap_status)}
    </div>
    <div class="status-stack">
      <h3>Latest Model Build</h3>
      ${summarizeStatus(state.overview.latest_lichtfeld_status)}
    </div>
  `;
}

export function renderDatasetOptions() {
  const datasets = state.overview.datasets || [];
  const options = datasets
    .map((entry) => {
      const suffix = entry.local_path_exists ? "" : " (path missing)";
      return `<option value="${escapeHtml(entry.id)}">${escapeHtml(entry.name)}${suffix}</option>`;
    })
    .join("");
  elements.datasetId().innerHTML = options || `<option value="">No saved photo sets found</option>`;
}

export function renderStageList() {
  const staged = state.overview.staged || [];
  const list = elements.stagedList();
  const options = staged
    .map((entry) => `<option value="${escapeHtml(entry.stage_root)}">${escapeHtml(entry.stage_name)}</option>`)
    .join("");

  elements.glomapStage().innerHTML = options || `<option value="">No prepared photo sets</option>`;
  elements.lichtfeldStage().innerHTML = options || `<option value="">No prepared photo sets</option>`;

  if (!staged.length) {
    list.innerHTML = `<p class="card muted-card">No prepared photo sets yet.</p>`;
    return;
  }

  list.innerHTML = staged
    .map((entry) => {
      const armed = state.deleteConfirmPath === entry.stage_root;
      return `
        <article class="card">
          <h3>${escapeHtml(entry.stage_name)}</h3>
          <p><strong>Photo set:</strong> ${escapeHtml(entry.dataset_id)}</p>
          <p><strong>Images:</strong> ${escapeHtml(entry.selected_image_count)}</p>
          ${entry.source_kind ? `<p><strong>Source Type:</strong> ${escapeHtml(entry.source_kind)}</p>` : ""}
          <p><strong>Variant:</strong> ${escapeHtml(entry.source_variant || "default")}</p>
          ${entry.quality_mode ? `<p><strong>Quality:</strong> ${escapeHtml(entry.quality_mode)}</p>` : ""}
          ${entry.virtual_view_mode ? `<p><strong>Virtual Views:</strong> ${escapeHtml(entry.virtual_view_mode)}</p>` : ""}
          ${entry.in_active_use ? `<p><span class="status-pill warn">In Use</span></p>` : ""}
          <p class="mono">${escapeHtml(entry.stage_root)}</p>
          <div class="row-actions">
            <button class="ghost" data-open-folder="${escapeHtml(entry.stage_root)}">Open Prepared Copy</button>
            ${
              entry.deletable
                ? `<button class="${armed ? "danger" : "ghost"}" data-delete-stage="${escapeHtml(entry.stage_root)}">${armed ? "Confirm Delete" : "Delete Working Copy"}</button>`
                : ""
            }
          </div>
        </article>
      `;
    })
    .join("");
}

export function renderSparseResults() {
  const sparse = state.overview.sparse_results || [];
  const container = elements.sparseList();
  const options = sparse
    .map((entry) => `<option value="${escapeHtml(entry.sparse_output_path)}">${escapeHtml(entry.job_id)} - ${escapeHtml(entry.dataset_id)}</option>`)
    .join("");
  elements.sparseModel().innerHTML = options || `<option value="">No saved camera layouts</option>`;

  if (!sparse.length) {
    container.innerHTML = `<p class="card muted-card">No saved camera layouts yet.</p>`;
    return;
  }

  container.innerHTML = sparse
    .map(
      (entry) => `
        <article class="card">
          <h3>${escapeHtml(entry.job_id)}</h3>
          <p><strong>Photo set:</strong> ${escapeHtml(entry.dataset_id)}</p>
          <p><strong>Matching style:</strong> ${escapeHtml(entry.matcher)}</p>
          <p class="mono">${escapeHtml(entry.sparse_output_path)}</p>
          <div class="row-actions">
            <button class="ghost" data-open-folder="${escapeHtml(entry.job_root)}">Open Run Folder</button>
            <button class="ghost" data-open-folder="${escapeHtml(entry.sparse_output_path)}">Open Camera Layout</button>
          </div>
        </article>
      `
    )
    .join("");
}

export function renderWorkflowStatus() {
  const container = elements.status();
  const workflow = state.overview.active_workflow;
  if (!workflow) {
    container.innerHTML = `<p class="card muted-card">No simple workflow is running right now.</p>`;
    return;
  }

  const className = workflowStatusClass(workflow.status);
  const stageItems = (workflow.stage_markers || [])
    .map(
      (stage) => `
        <li class="stage-item ${escapeHtml(stage.state)}">
          <span class="stage-dot"></span>
          <span>${escapeHtml(stage.label)}</span>
        </li>
      `
    )
    .join("");

  container.innerHTML = `
    <article class="card status-card">
      <div class="status-head">
        <h3>${escapeHtml(workflow.workflow_id)}</h3>
        <div class="status-head-actions">
          <span class="status-pill ${className}">${escapeHtml(workflow.status)}</span>
          ${
            ["queued", "running"].includes(workflow.status)
              ? `<button class="danger-soft" data-cancel-workflow="${escapeHtml(workflow.workflow_id)}">Cancel</button>`
              : ""
          }
        </div>
      </div>
      <p class="status-line">${escapeHtml(workflow.status_text || "")}</p>
      <div class="workflow-progress">
        <div class="progress-meter">
          <div class="progress-fill" style="width: ${Number(workflow.progress_percent || 0)}%"></div>
        </div>
        <div class="progress-meta">
          <span><strong>Current step:</strong> ${escapeHtml((workflow.stage_markers || []).find((stage) => stage.state === "active" || stage.state === "error")?.label || "Working")}</span>
          <span><strong>Progress:</strong> ${escapeHtml(workflow.progress_percent || 0)}%</span>
        </div>
        <ol class="stage-list">${stageItems}</ol>
      </div>
      <div class="key-facts">
        <p><strong>Quality:</strong> ${escapeHtml(workflow.quality || "")}</p>
        <p><strong>Source:</strong> <span class="mono">${escapeHtml(workflow.source_folder || "")}</span></p>
        ${
          workflow.training_mode_note
            ? `<p><strong>Training mode:</strong> ${escapeHtml(workflow.training_mode_note)}</p>`
            : ""
        }
        ${workflow.staged_dataset_path ? `<p><strong>Working copy:</strong> <span class="mono">${escapeHtml(workflow.staged_dataset_path)}</span></p>` : ""}
        ${workflow.latest_splat ? `<p><strong>Saved model:</strong> <span class="mono">${escapeHtml(workflow.latest_splat)}</span></p>` : ""}
      </div>
      ${
        workflow.error
          ? `<div class="error-detail">
              <strong>What happened</strong>
              <span>${escapeHtml(workflow.error)}</span>
              ${workflow.error_detail ? `<span class="mono">${escapeHtml(workflow.error_detail)}</span>` : ""}
              ${workflow.error_guidance ? `<span>${escapeHtml(workflow.error_guidance)}</span>` : ""}
            </div>`
          : ""
      }
      <div class="row-actions">
        ${workflow.staged_dataset_path ? `<button class="ghost" data-open-folder="${escapeHtml(workflow.staged_dataset_path)}">Open Working Copy</button>` : ""}
        ${workflow.glomap_job_root ? `<button class="ghost" data-open-folder="${escapeHtml(workflow.glomap_job_root)}">Open Camera Layout Folder</button>` : ""}
        ${workflow.lichtfeld_job_root ? `<button class="ghost" data-open-folder="${escapeHtml(workflow.lichtfeld_job_root)}">Open Model Folder</button>` : ""}
        ${workflow.latest_splat ? `<button class="ghost" data-open-folder="${escapeHtml(parentPath(workflow.latest_splat))}">Open Saved Model Folder</button>` : ""}
        ${workflow.latest_splat ? `<button class="accent" data-view-splat="${escapeHtml(workflow.latest_splat)}">View Splat</button>` : ""}
      </div>
    </article>
  `;
}

export function renderWorkflowHistory() {
  const container = elements.history();
  const activeWorkflowId = state.overview.active_workflow?.workflow_id || "";
  const items = (state.overview.recent_workflows || []).filter((item) => item.workflow_id !== activeWorkflowId);

  if (!items.length) {
    container.innerHTML = `<p class="card muted-card">No previous simple workflows are recorded yet.</p>`;
    return;
  }

  container.innerHTML = items
    .map((workflow) => {
      const className = workflowStatusClass(workflow.status);
      return `
        <article class="card history-card">
          <div class="history-head">
            <h3>${escapeHtml(workflow.workflow_id)}</h3>
            <span class="status-pill ${className}">${escapeHtml(workflow.status)}</span>
          </div>
          <p>${escapeHtml(workflow.status_text || "")}</p>
          <p><strong>When:</strong> ${escapeHtml(formatWorkflowTime(workflow.updated_at || workflow.created_at || ""))}</p>
          <p><strong>Quality:</strong> ${escapeHtml(workflow.quality || "")}</p>
          ${
            workflow.status === "canceled"
              ? `<p><strong>Cleanup:</strong> ${
                  workflow.canceled_cleanup_performed
                    ? "360GS removed the working files for this run. The source imagery was kept."
                    : "The 360GS working files were kept. The source imagery was kept."
                }</p>`
              : ""
          }
          ${workflow.training_mode_note ? `<p><strong>Training mode:</strong> ${escapeHtml(workflow.training_mode_note)}</p>` : ""}
          ${workflow.latest_splat ? `<p><strong>Saved model:</strong> <span class="mono">${escapeHtml(workflow.latest_splat)}</span></p>` : ""}
          ${
            workflow.error
              ? `<p><strong>What happened:</strong> ${escapeHtml(workflow.error)}</p>
                 ${workflow.error_detail ? `<p><strong>Detail:</strong> <span class="mono">${escapeHtml(workflow.error_detail)}</span></p>` : ""}
                 ${workflow.error_guidance ? `<p><strong>Try next:</strong> ${escapeHtml(workflow.error_guidance)}</p>` : ""}`
              : ""
          }
          <div class="row-actions">
            <button class="ghost" data-delete-workflow="${escapeHtml(workflow.workflow_id)}">Remove From List</button>
            ${workflow.staged_dataset_path ? `<button class="ghost" data-open-folder="${escapeHtml(workflow.staged_dataset_path)}">Open Working Copy</button>` : ""}
            ${workflow.glomap_job_root ? `<button class="ghost" data-open-folder="${escapeHtml(workflow.glomap_job_root)}">Open Camera Layout Folder</button>` : ""}
            ${workflow.lichtfeld_job_root ? `<button class="ghost" data-open-folder="${escapeHtml(workflow.lichtfeld_job_root)}">Open Model Folder</button>` : ""}
            ${workflow.latest_splat ? `<button class="ghost" data-open-folder="${escapeHtml(parentPath(workflow.latest_splat))}">Open Saved Model Folder</button>` : ""}
            ${workflow.status === "completed" && workflow.latest_splat ? `<button class="accent" data-view-splat="${escapeHtml(workflow.latest_splat)}">View Splat</button>` : ""}
          </div>
        </article>
      `;
    })
    .join("");
}

export function renderCancelDialog() {
  const scrim = elements.cancelModalScrim();
  const title = elements.cancelModalTitle();
  const body = elements.cancelModalBody();
  const note = elements.cancelModalNote();
  const yes = elements.cancelModalYes();
  const no = elements.cancelModalNo();

  document.body.classList.toggle("modal-open", state.cancelDialogOpen);
  scrim.hidden = !state.cancelDialogOpen;
  if (!state.cancelDialogOpen) {
    return;
  }

  if (state.cancelDialogStep === "cleanup") {
    title.textContent = "Delete the 360GS working files too?";
    body.textContent = "This will remove the working copy and any files or folders created for this run inside 360GS.";
    note.textContent = "Your original source imagery will never be deleted by this action.";
    yes.textContent = "Yes";
    no.textContent = "No";
  } else {
    title.textContent = "Stop this run?";
    body.textContent = "This will cancel the entire process at its current stage.";
    note.textContent = "You will be asked next whether 360GS should also delete the working files it created for this run.";
    yes.textContent = "Yes";
    no.textContent = "No";
  }
}

export function renderQualityExplain() {
  const explain = elements.qualityExplain();
  const select = elements.qualityMode();
  const createButton = elements.createSplat();
  if (!state.inspectedFolder) {
    explain.textContent = "Quality details and rough timing will appear here after the folder is checked.";
    createButton.disabled = true;
    return;
  }

  if (state.inspectedFolder.video_count) {
    explain.innerHTML = `
      <strong>Video detected.</strong><br />
      ${escapeHtml(state.inspectedFolder.video_notice || "Video import is limited to Advanced Options.")}<br />
      <strong>Next step:</strong> open <strong>Advanced Options</strong> and use <strong>Prepare Media</strong>.
    `;
    createButton.disabled = true;
    return;
  }

  if (state.inspectedFolder.simple_workflow_ready === false) {
    explain.innerHTML = `
      <strong>Create Splat is unavailable.</strong><br />
      ${escapeHtml(state.inspectedFolder.simple_mode_blocked_reason || "This install is missing required pipeline tools.")}
    `;
    createButton.disabled = true;
    return;
  }

  const preset = state.inspectedFolder.quality_options[select.value];
  if (!preset) {
    explain.textContent = "Choose a quality level to see what it will do.";
    createButton.disabled = true;
    return;
  }

  const activeNote = workflowIsActive()
    ? `<br /><strong>Current limit:</strong> wait for the running workflow to finish before starting another simple workflow.`
    : "";

  explain.innerHTML = `
    <strong>${escapeHtml(preset.label)}</strong><br />
    ${escapeHtml(preset.description)}<br />
    <strong>How many images it uses:</strong> about ${escapeHtml(preset.selected_images)} of ${escapeHtml(state.inspectedFolder.image_count)}<br />
    <strong>Rough time:</strong> ${escapeHtml(preset.estimated_minutes_low)}-${escapeHtml(preset.estimated_minutes_high)} minutes on this laptop
    ${activeNote}
  `;
  createButton.disabled = workflowIsActive();
}

export function renderFolderSummary() {
  const summary = elements.folderSummary();
  const qualitySelect = elements.qualityMode();
  if (!state.inspectedFolder) {
    summary.innerHTML = `Enter a folder path and click <strong>Check Folder</strong>. The quality options will unlock after the app finds supported images.`;
    qualitySelect.disabled = true;
    qualitySelect.value = "";
    renderQualityExplain();
    return;
  }

  if (state.inspectedFolder.video_count) {
    const imageCount = Number(state.inspectedFolder.image_count || 0);
    const videoCount = Number(state.inspectedFolder.video_count || 0);
    summary.innerHTML = `
      <strong>Advanced-only media detected.</strong><br />
      Found ${escapeHtml(imageCount)} still images and ${escapeHtml(videoCount)} video file(s) in:<br />
      <span class="mono">${escapeHtml(state.inspectedFolder.folder_path)}</span><br />
      <strong>Why simple mode is blocked:</strong> ${escapeHtml(
        state.inspectedFolder.simple_mode_blocked_reason || state.inspectedFolder.video_notice || "Video import is limited to Advanced Options."
      )}
    `;
    qualitySelect.disabled = true;
    qualitySelect.value = "";
    renderQualityExplain();
    return;
  }

  if (state.inspectedFolder.simple_workflow_ready === false) {
    summary.innerHTML = `
      <strong>Folder checked, but 360GS needs repair.</strong><br />
      Found ${escapeHtml(state.inspectedFolder.image_count)} supported image files in:<br />
      <span class="mono">${escapeHtml(state.inspectedFolder.folder_path)}</span><br />
      <strong>Why Create Splat is blocked:</strong> ${escapeHtml(
        state.inspectedFolder.simple_mode_blocked_reason || "This install is missing required pipeline tools."
      )}
    `;
    qualitySelect.disabled = true;
    qualitySelect.value = "";
    renderQualityExplain();
    return;
  }

  summary.innerHTML = `
    <strong>Folder ready.</strong><br />
    Found ${escapeHtml(state.inspectedFolder.image_count)} supported image files in:<br />
    <span class="mono">${escapeHtml(state.inspectedFolder.folder_path)}</span>
  `;
  qualitySelect.disabled = false;
  if (!qualitySelect.value) {
    qualitySelect.value = "medium";
  }
  renderQualityExplain();
}

export function renderMediaQualityExplain() {
  const explain = elements.mediaQualityExplain();
  const select = elements.mediaQuality();
  const button = elements.prepareMedia();
  if (!state.inspectedMedia) {
    explain.textContent = "Analyze a video path first. The app will suggest the best starting preset and explain what it will prepare.";
    button.disabled = true;
    return;
  }

  if (!state.inspectedMedia.supported_for_prepare) {
    explain.textContent = state.inspectedMedia.video_notice || "This source is not supported for advanced video preparation.";
    button.disabled = true;
    return;
  }

  const preset = state.inspectedMedia.quality_options?.[select.value];
  if (!preset) {
    explain.textContent = "Choose a preset to see the planned extraction details.";
    button.disabled = true;
    return;
  }

  const sceneDetectText = preset.use_scene_detect
    ? `Scene detection will be requested for longer clips if the optional dependency is available.`
    : `Scene detection is not planned for this preset.`;

  if (preset.virtual_view_mode) {
    explain.innerHTML = `
      <strong>${escapeHtml(preset.label)}</strong><br />
      ${escapeHtml(preset.description)}<br />
      <strong>Estimated staged views:</strong> about ${escapeHtml(preset.estimated_frames)} images from ${escapeHtml(
        preset.estimated_timestamps
      )} timestamps across ${escapeHtml(preset.view_count)} virtual cameras.<br />
      <strong>View size:</strong> ${escapeHtml(preset.view_width)} x ${escapeHtml(preset.view_height)}<br />
      <strong>Sampling rate:</strong> about ${escapeHtml(preset.extraction_fps)} fps<br />
      ${escapeHtml(sceneDetectText)}
    `;
  } else {
    explain.innerHTML = `
      <strong>${escapeHtml(preset.label)}</strong><br />
      ${escapeHtml(preset.description)}<br />
      <strong>Estimated staged frames:</strong> about ${escapeHtml(preset.estimated_frames)} images<br />
      <strong>Max output width:</strong> ${escapeHtml(preset.max_output_width)} px<br />
      <strong>Sampling rate:</strong> about ${escapeHtml(preset.extraction_fps)} fps<br />
      ${escapeHtml(sceneDetectText)}
    `;
  }
  button.disabled = false;
}

export function renderMediaSummary() {
  const summary = elements.mediaSummary();
  const select = elements.mediaQuality();
  if (!state.inspectedMedia) {
    summary.innerHTML = `Point to a supported video file, or to a folder containing one video file, then click <strong>Analyze Media</strong>.`;
    select.disabled = true;
    select.value = "";
    renderMediaQualityExplain();
    return;
  }

  const sourceKindLabel = state.inspectedMedia.source_kind_label || state.inspectedMedia.source_kind || "Unknown media";
  const info = state.inspectedMedia.video_info || null;
  const recommendation = state.inspectedMedia.recommended_quality_reason || state.inspectedMedia.video_notice || "";
  const details = info
    ? `Duration ${escapeHtml((info.duration_seconds || 0).toFixed ? info.duration_seconds.toFixed(1) : info.duration_seconds)}s, ${escapeHtml(
        info.width
      )} x ${escapeHtml(info.height)}, about ${escapeHtml(Number(info.source_fps || 0).toFixed(2))} fps.`
    : "This path is not a supported video source for advanced preparation.";

  summary.innerHTML = `
    <strong>${escapeHtml(sourceKindLabel)}</strong><br />
    ${escapeHtml(details)}<br />
    <strong>Source:</strong> <span class="mono">${escapeHtml(state.inspectedMedia.source_path || "")}</span><br />
    ${
      state.inspectedMedia.detection_reasons?.length
        ? `<strong>Detection:</strong> ${escapeHtml(state.inspectedMedia.detection_reasons.join(" "))}<br />`
        : ""
    }
    ${recommendation ? `<strong>Recommendation:</strong> ${escapeHtml(recommendation)}` : ""}
  `;

  select.disabled = !state.inspectedMedia.supported_for_prepare;
  if (!select.disabled) {
    select.value = state.inspectedMedia.recommended_quality || select.value || "medium";
  } else {
    select.value = "";
  }
  renderMediaQualityExplain();
}

export function renderAll() {
  renderInstallStatus();
  renderLatestJobs();
  renderDatasetOptions();
  renderStageList();
  renderSparseResults();
  renderWorkflowStatus();
  renderWorkflowHistory();
  renderFolderSummary();
  renderMediaSummary();
  renderCancelDialog();
}

from __future__ import annotations

import argparse
import json
import math
import os
import re
import socket
import subprocess
import sys
import threading
import time
import webbrowser
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import shutil
import winreg
from typing import Any
from urllib.parse import urlparse


APP_ROOT = Path(__file__).resolve().parent
INSTALL_ROOT = APP_ROOT.parent
WEB_ROOT = APP_ROOT / "web"
BENCHMARK_ROOT = INSTALL_ROOT / "benchmark"
CONFIG_ROOT = INSTALL_ROOT / "config"
IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".bmp"}
VIDEO_EXTENSIONS = {".mp4", ".mov", ".m4v", ".avi", ".mkv"}
RAW_360_EXTENSIONS = {".insv", ".insp", ".lrv"}
ALL_VIDEO_EXTENSIONS = VIDEO_EXTENSIONS | RAW_360_EXTENSIONS
ANSI_ESCAPE_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
VIDEO_PRESET_TARGETS = {
    "standard_video": {
        "fast-preview": {"target_frames": 120, "max_output_width": 1600, "scene_detect_threshold_seconds": 120},
        "medium": {"target_frames": 240, "max_output_width": 1920, "scene_detect_threshold_seconds": 90},
        "high": {"target_frames": 480, "max_output_width": 2560, "scene_detect_threshold_seconds": 60},
    },
    "video_360_equirect": {
        "fast-preview": {"target_timestamps": 24, "view_width": 1280, "scene_detect_threshold_seconds": 120},
        "medium": {"target_timestamps": 48, "view_width": 1600, "scene_detect_threshold_seconds": 90},
        "high": {"target_timestamps": 96, "view_width": 1920, "scene_detect_threshold_seconds": 60},
    },
}
VIDEO_KIND_LABELS = {
    "image_folder": "Still images only",
    "standard_video": "Standard video",
    "video_360_equirect": "360 video",
    "mixed_media": "Mixed media",
    "unsupported_raw_360": "Unsupported raw 360 capture",
}
WORKFLOW_PROGRESS_STEPS = [
    {"key": "queued", "label": "Ready", "progress": 6},
    {"key": "staging", "label": "Stage Images", "progress": 22},
    {"key": "sparse", "label": "Sparse Model", "progress": 52},
    {"key": "training", "label": "Train Splat", "progress": 82},
    {"key": "done", "label": "Complete", "progress": 100},
]
WORKFLOW_STAGE_ALIASES = {
    "queued": "queued",
    "staging": "staging",
    "sparse-start": "sparse",
    "sparse-running": "sparse",
    "training-start": "training",
    "training-running": "training",
    "done": "done",
    "failed": "failed",
}


class AppError(Exception):
    def __init__(self, message: str, status_code: int = 400, *, detail: str = "", guidance: str = "") -> None:
        super().__init__(message)
        self.status_code = status_code
        self.detail = detail
        self.guidance = guidance


class WorkflowCanceledError(Exception):
    pass


def preferred_powershell_exe() -> Path:
    pwsh_path = shutil.which("pwsh.exe")
    candidates = []
    if pwsh_path:
        candidates.append(Path(pwsh_path))
    candidates.append(Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "PowerShell" / "7" / "pwsh.exe")
    candidates.append(Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe")
    for candidate in candidates:
        if candidate.exists():
            return candidate
    raise AppError("No supported PowerShell executable was found on this machine.", 500)


POWERSHELL_EXE = preferred_powershell_exe()
COLMAP_EXE = INSTALL_ROOT / "packs" / "colmap-global" / "bin" / "colmap.exe"
GLOMAP_EXE = INSTALL_ROOT / "packs" / "glomap-standalone" / "bin" / "glomap.exe"
LICHTFELD_EXE = INSTALL_ROOT / "packs" / "lichtfeld-studio" / "bin" / "LichtFeld-Studio.exe"
SHARP_CLI = INSTALL_ROOT / "runtime" / "python311" / "Scripts" / "sharp.exe"


def pipeline_capabilities() -> dict[str, Any]:
    missing_simple_workflow_components: list[str] = []
    has_colmap_global = COLMAP_EXE.exists()
    has_glomap_standalone = GLOMAP_EXE.exists()
    has_lichtfeld = LICHTFELD_EXE.exists()

    if not has_colmap_global:
        missing_simple_workflow_components.append("COLMAP")
    if not has_glomap_standalone:
        missing_simple_workflow_components.append("GLOMAP")
    if not has_lichtfeld:
        missing_simple_workflow_components.append("LichtFeld Studio")

    simple_workflow_ready = not missing_simple_workflow_components
    if simple_workflow_ready:
        simple_workflow_note = "The full Create Splat tool bundle is installed."
    else:
        missing_text = ", ".join(missing_simple_workflow_components)
        simple_workflow_note = (
            f"This 360GS install is missing required pipeline tools: {missing_text}. "
            "Re-run the 360GS installer to install the full operator tool bundle, then retry."
        )

    return {
        "has_colmap_global": has_colmap_global,
        "has_glomap_standalone": has_glomap_standalone,
        "has_lichtfeld": has_lichtfeld,
        "has_sharp_preview": SHARP_CLI.exists(),
        "simple_workflow_ready": simple_workflow_ready,
        "missing_simple_workflow_components": missing_simple_workflow_components,
        "simple_workflow_note": simple_workflow_note,
    }


def require_simple_workflow_capability() -> None:
    capability = pipeline_capabilities()
    if not capability["simple_workflow_ready"]:
        raise AppError(str(capability["simple_workflow_note"]))


def require_glomap_capability() -> None:
    capability = pipeline_capabilities()
    missing_components: list[str] = []
    if not capability["has_colmap_global"]:
        missing_components.append("COLMAP")
    if not capability["has_glomap_standalone"]:
        missing_components.append("GLOMAP")
    if missing_components:
        missing_text = ", ".join(missing_components)
        raise AppError(
            f"This 360GS install is missing required sparse-reconstruction tools: {missing_text}. "
            "Re-run the 360GS installer to install the full operator tool bundle, then retry."
        )


def require_lichtfeld_capability() -> None:
    capability = pipeline_capabilities()
    if not capability["has_lichtfeld"]:
        raise AppError(
            "This 360GS install is missing LichtFeld Studio. "
            "Re-run the 360GS installer to install the full operator tool bundle, then retry."
        )


def windows_platform_info() -> dict[str, Any]:
    version = sys.getwindowsversion()
    build = int(version.build)
    product_name = "Windows"
    display_version = ""
    try:
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Microsoft\Windows NT\CurrentVersion") as key:
            product_name = str(winreg.QueryValueEx(key, "ProductName")[0] or product_name)
            try:
                display_version = str(winreg.QueryValueEx(key, "DisplayVersion")[0] or "")
            except FileNotFoundError:
                display_version = ""
    except OSError:
        pass

    family = "unsupported"
    support_label = "Unsupported Windows"
    if build >= 22000:
        family = "windows-11"
        support_label = "Windows 11"
    elif build >= 19045:
        family = "windows-10"
        support_label = "Windows 10 22H2+"

    return {
        "family": family,
        "support_label": support_label,
        "product_name": product_name,
        "version": f"{version.major}.{version.minor}.{version.build}",
        "build": build,
        "display_version": display_version,
        "preferred_shell": str(POWERSHELL_EXE),
        "is_supported": family != "unsupported",
    }


def existing_benchmark_path(child_path: str) -> Path:
    preferred = INSTALL_ROOT / "artifacts" / "benchmark" / child_path
    legacy = INSTALL_ROOT / "benchmark" / child_path
    if preferred.exists():
        return preferred
    if legacy.exists():
        return legacy
    return preferred


def registry_path() -> Path:
    candidates = (
        CONFIG_ROOT / "datasets.local.json",
        CONFIG_ROOT / "datasets.example.json",
        BENCHMARK_ROOT / "datasets.standard.json",
    )
    for candidate in candidates:
        if candidate.exists():
            return candidate
    raise AppError("Dataset registry not found in install payload.", 500)


def read_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def is_under_root(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def assert_allowed_path(path_text: str, *, must_exist: bool = True) -> Path:
    if not path_text.strip():
        raise AppError("A path value is required.")
    path = Path(path_text)
    if must_exist and not path.exists():
        raise AppError(f"Path does not exist: {path}")
    if not is_under_root(path, INSTALL_ROOT):
        raise AppError(f"Path is outside the managed 360GS install root: {path}")
    return path


def assert_existing_directory_anywhere(path_text: str) -> Path:
    if not path_text.strip():
        raise AppError("An image folder path is required.")
    path = Path(path_text)
    if not path.exists():
        raise AppError(f"Folder does not exist: {path}")
    if not path.is_dir():
        raise AppError(f"Path is not a folder: {path}")
    return path.resolve()


def workflows_root() -> Path:
    root = existing_benchmark_path("workflows")
    root.mkdir(parents=True, exist_ok=True)
    return root


def managed_staged_roots() -> list[Path]:
    return [
        (INSTALL_ROOT / "artifacts" / "benchmark" / "staged").resolve(),
        (INSTALL_ROOT / "benchmark" / "staged").resolve(),
    ]


def managed_tool_root_candidates() -> list[Path]:
    return [INSTALL_ROOT / "tools"]


def find_managed_tool(executable_name: str) -> Path:
    for root in managed_tool_root_candidates():
        if not root.exists():
            continue
        matches = sorted(root.rglob(executable_name))
        if matches:
            return matches[0]

    discovered = shutil.which(executable_name)
    if discovered:
        return Path(discovered)
    raise AppError(f"Required media tool was not found: {executable_name}", 500)


def ffmpeg_exe() -> Path:
    return find_managed_tool("ffmpeg.exe")


def ffprobe_exe() -> Path:
    return find_managed_tool("ffprobe.exe")


def image_files_in_folder(folder: Path) -> list[Path]:
    files = [item for item in folder.iterdir() if item.is_file() and item.suffix.lower() in IMAGE_EXTENSIONS]
    return sorted(files, key=lambda item: item.name.lower())


def video_files_in_folder(folder: Path) -> list[Path]:
    files = [item for item in folder.iterdir() if item.is_file() and item.suffix.lower() in ALL_VIDEO_EXTENSIONS]
    return sorted(files, key=lambda item: item.name.lower())


def slugify(value: str) -> str:
    slug = re.sub(r"[^a-zA-Z0-9]+", "-", value.strip()).strip("-").lower()
    return slug or "dataset"


def parse_fraction(value: Any, *, default: float = 0.0) -> float:
    text = str(value or "").strip()
    if not text:
        return default
    if "/" in text:
        left, right = text.split("/", 1)
        try:
            numerator = float(left)
            denominator = float(right)
        except ValueError:
            return default
        if denominator == 0:
            return default
        return numerator / denominator
    try:
        return float(text)
    except ValueError:
        return default


def ffprobe_media_info(path: Path) -> dict[str, Any]:
    command = [
        str(ffprobe_exe()),
        "-v",
        "error",
        "-show_streams",
        "-show_format",
        "-print_format",
        "json",
        str(path),
    ]
    completed = subprocess.run(command, capture_output=True, text=True, timeout=90)
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout or "").strip()
        raise AppError(detail or f"ffprobe could not inspect: {path}", 500)
    payload = json.loads(completed.stdout or "{}")
    streams = payload.get("streams", [])
    video_stream = next((stream for stream in streams if stream.get("codec_type") == "video"), None)
    if not video_stream:
        raise AppError(f"No video stream was found in: {path}")

    width = int(video_stream.get("width") or 0)
    height = int(video_stream.get("height") or 0)
    duration = parse_fraction(video_stream.get("duration")) or parse_fraction(payload.get("format", {}).get("duration"))
    source_fps = parse_fraction(video_stream.get("avg_frame_rate")) or parse_fraction(video_stream.get("r_frame_rate"), default=0.0)
    raw_metadata_text = json.dumps(payload, default=str).lower()
    rotation = 0
    tags = video_stream.get("tags") or {}
    if "rotate" in tags:
        rotation = int(parse_fraction(tags.get("rotate")))
    return {
        "path": str(path),
        "file_name": path.name,
        "codec_name": str(video_stream.get("codec_name") or ""),
        "width": width,
        "height": height,
        "duration_seconds": float(duration or 0.0),
        "source_fps": float(source_fps or 0.0),
        "rotation": rotation,
        "bit_rate": str(payload.get("format", {}).get("bit_rate") or ""),
        "raw_metadata_text": raw_metadata_text,
        "format_name": str(payload.get("format", {}).get("format_name") or ""),
    }


def detect_video_kind(path: Path, info: dict[str, Any]) -> tuple[str, list[str]]:
    suffix = path.suffix.lower()
    lowered_name = path.name.lower()
    reasons: list[str] = []

    if suffix in RAW_360_EXTENSIONS:
        reasons.append(f"Raw camera capture extension: {suffix}")
        return "unsupported_raw_360", reasons

    aspect_ratio = (float(info.get("width") or 0) / float(info.get("height") or 1)) if int(info.get("height") or 0) > 0 else 0.0
    metadata_text = str(info.get("raw_metadata_text") or "")
    has_360_metadata = any(token in metadata_text for token in ("spherical", "equirect", "projection"))
    if has_360_metadata:
        reasons.append("Spherical/equirect metadata detected.")

    has_aspect_hint = 1.9 <= aspect_ratio <= 2.1 and int(info.get("width") or 0) >= 1920
    if has_aspect_hint:
        reasons.append(f"Aspect ratio looks equirectangular ({aspect_ratio:.2f}:1).")

    vendor_hint = any(token in lowered_name for token in ("insta360", "x3", "x4", "one-rs", "oners", "one_rs"))
    if vendor_hint:
        reasons.append("File name indicates 360 capture.")

    if has_360_metadata or (has_aspect_hint and vendor_hint):
        return "video_360_equirect", reasons or ["Likely exported equirectangular 360 video."]
    return "standard_video", reasons or ["No 360-specific markers detected."]


def recommend_video_quality(source_kind: str, info: dict[str, Any]) -> tuple[str, str]:
    duration_seconds = float(info.get("duration_seconds") or 0.0)
    width = int(info.get("width") or 0)
    if source_kind == "video_360_equirect":
        if duration_seconds >= 180 or width >= 5760:
            return "fast-preview", "Long or high-resolution 360 video is safer to sample lightly first."
        if duration_seconds >= 75 or width >= 3840:
            return "medium", "This 360 video is large enough that the balanced preset is the safer starting point."
        return "medium", "The balanced 360 preset is the default starting point for exported 360 video."

    if duration_seconds >= 480 or width >= 3840:
        return "fast-preview", "Very long or high-resolution video is safer to sample lightly first."
    if duration_seconds <= 30 and width <= 1920:
        return "high", "Shorter standard video can usually support the higher preset."
    return "medium", "The balanced video preset is the default starting point for standard video."


def video_quality_preset(source_kind: str, quality: str, info: dict[str, Any]) -> dict[str, Any]:
    if source_kind not in VIDEO_PRESET_TARGETS:
        raise AppError(f"Video presets are not defined for media kind: {source_kind}")
    if quality not in VIDEO_PRESET_TARGETS[source_kind]:
        raise AppError("Quality must be one of: fast-preview, medium, high.")

    config = dict(VIDEO_PRESET_TARGETS[source_kind][quality])
    duration_seconds = max(float(info.get("duration_seconds") or 1.0), 1.0)
    source_fps = max(float(info.get("source_fps") or 0.0), 1.0)
    preset = {
        "quality": quality,
        "label": quality_preset(180, quality)["label"],
    }

    if source_kind == "standard_video":
        target_frames = int(config["target_frames"])
        extraction_fps = min(source_fps, target_frames / duration_seconds)
        extraction_fps = max(0.2, extraction_fps)
        estimated_frames = max(1, int(math.ceil(duration_seconds * extraction_fps)))
        max_output_width = int(config["max_output_width"])
        use_scene_detect = duration_seconds >= int(config["scene_detect_threshold_seconds"])
        low_minutes = max(3, int((estimated_frames * 0.7) / 60))
        high_minutes = max(low_minutes + 2, int((estimated_frames * 1.5) / 60))
        preset.update(
            {
                "description": "Samples a standard video into a managed frame set for the existing sparse and training pipeline.",
                "target_frames": target_frames,
                "estimated_frames": estimated_frames,
                "extraction_fps": round(extraction_fps, 3),
                "max_output_width": max_output_width,
                "use_scene_detect": use_scene_detect,
                "scene_detect_threshold_seconds": int(config["scene_detect_threshold_seconds"]),
                "virtual_view_mode": "",
                "view_count": 1,
                "estimated_minutes_low": low_minutes,
                "estimated_minutes_high": high_minutes,
                "operator_text": (
                    f"{preset['label']}: roughly {estimated_frames} extracted frames at about "
                    f"{round(extraction_fps, 2)} fps, scaled to {max_output_width}px wide when needed."
                ),
            }
        )
        return preset

    target_timestamps = int(config["target_timestamps"])
    extraction_fps = min(source_fps, target_timestamps / duration_seconds)
    extraction_fps = max(0.1, extraction_fps)
    estimated_timestamps = max(1, int(math.ceil(duration_seconds * extraction_fps)))
    view_width = int(config["view_width"])
    view_height = max(360, int(round(view_width * 9 / 16)))
    estimated_frames = estimated_timestamps * 4
    use_scene_detect = duration_seconds >= int(config["scene_detect_threshold_seconds"])
    low_minutes = max(4, int((estimated_frames * 0.8) / 60))
    high_minutes = max(low_minutes + 2, int((estimated_frames * 1.5) / 60))
    preset.update(
        {
            "description": "Reprojects an exported 360 video into four horizon-facing rectilinear view streams for the existing sparse and training pipeline.",
            "target_timestamps": target_timestamps,
            "estimated_timestamps": estimated_timestamps,
            "estimated_frames": estimated_frames,
            "extraction_fps": round(extraction_fps, 3),
            "view_width": view_width,
            "view_height": view_height,
            "use_scene_detect": use_scene_detect,
            "scene_detect_threshold_seconds": int(config["scene_detect_threshold_seconds"]),
            "virtual_view_mode": "horizon-4",
            "view_count": 4,
            "estimated_minutes_low": low_minutes,
            "estimated_minutes_high": high_minutes,
            "operator_text": (
                f"{preset['label']}: roughly {estimated_timestamps} timestamps expanded into about "
                f"{estimated_frames} staged views across four horizon cameras."
            ),
        }
    )
    return preset


def inspect_video_path(path: Path) -> dict[str, Any]:
    info = ffprobe_media_info(path)
    source_kind, detection_reasons = detect_video_kind(path, info)
    recommended_quality = ""
    recommendation_reason = ""
    quality_options: dict[str, Any] = {}
    supported_for_prepare = source_kind != "unsupported_raw_360"
    if supported_for_prepare:
        recommended_quality, recommendation_reason = recommend_video_quality(source_kind, info)
        quality_options = {
            quality: video_quality_preset(source_kind, quality, info)
            for quality in ("fast-preview", "medium", "high")
        }
    else:
        recommendation_reason = "This looks like a raw or proprietary 360 capture that is out of scope for the current app."

    return {
        "source_path": str(path),
        "resolved_video_path": str(path),
        "source_kind": source_kind,
        "source_kind_label": VIDEO_KIND_LABELS.get(source_kind, source_kind),
        "video_count": 1,
        "image_count": 0,
        "supported_for_prepare": supported_for_prepare,
        "detection_reasons": detection_reasons,
        "video_notice": recommendation_reason,
        "recommended_quality": recommended_quality,
        "recommended_quality_reason": recommendation_reason,
        "quality_options": quality_options,
        "video_info": {
            key: value
            for key, value in info.items()
            if key != "raw_metadata_text"
        },
        "simple_mode_blocked_reason": "Video import is limited to Advanced Options.",
    }


def inspect_media_source_path(source_path: str) -> dict[str, Any]:
    path = Path(source_path)
    if not path.exists():
        raise AppError(f"Source path does not exist: {path}")

    if path.is_file():
        suffix = path.suffix.lower()
        if suffix in IMAGE_EXTENSIONS:
            return {
                "source_path": str(path.resolve()),
                "source_kind": "image_folder",
                "source_kind_label": VIDEO_KIND_LABELS["image_folder"],
                "image_count": 1,
                "video_count": 0,
                "supported_for_prepare": False,
                "video_notice": "Prepare Media is for video import. Use the still-image workflow for image folders.",
                "recommended_quality": "",
                "recommended_quality_reason": "Still-image sources do not need FFmpeg extraction.",
                "quality_options": {},
                "simple_mode_blocked_reason": "",
                "detection_reasons": ["This path is a still image file."],
            }
        if suffix in RAW_360_EXTENSIONS:
            return {
                "source_path": str(path.resolve()),
                "resolved_video_path": str(path.resolve()),
                "source_kind": "unsupported_raw_360",
                "source_kind_label": VIDEO_KIND_LABELS["unsupported_raw_360"],
                "image_count": 0,
                "video_count": 1,
                "supported_for_prepare": False,
                "video_notice": "Raw or proprietary 360 captures are not supported in this version. Export a stitched equirectangular video first.",
                "recommended_quality": "",
                "recommended_quality_reason": "Export a stitched equirectangular video first.",
                "quality_options": {},
                "simple_mode_blocked_reason": "Video import is limited to Advanced Options.",
                "detection_reasons": [f"Raw camera capture extension detected: {suffix}"],
            }
        if suffix not in ALL_VIDEO_EXTENSIONS:
            raise AppError(f"Unsupported media type: {path.suffix or path.name}")
        return inspect_video_path(path.resolve())

    folder = path.resolve()
    image_files = image_files_in_folder(folder)
    video_files = video_files_in_folder(folder)
    if not image_files and not video_files:
        raise AppError("No supported image or video files were found in that folder.")
    if not video_files:
        return {
            "source_path": str(folder),
            "source_kind": "image_folder",
            "source_kind_label": VIDEO_KIND_LABELS["image_folder"],
            "image_count": len(image_files),
            "video_count": 0,
            "supported_for_prepare": False,
            "video_notice": "Prepare Media is for video import. Use the still-image workflow for image folders.",
            "recommended_quality": "",
            "recommended_quality_reason": "Still-image folders do not need FFmpeg extraction.",
            "quality_options": {},
            "simple_mode_blocked_reason": "",
            "detection_reasons": ["This folder contains only supported still images."],
        }
    if len(video_files) > 1:
        raise AppError("Advanced video import currently accepts one video file at a time. Choose a single file or a folder with one video.")

    result = inspect_video_path(video_files[0].resolve())
    result.update(
        {
            "source_path": str(folder),
            "image_count": len(image_files),
            "video_count": len(video_files),
        }
    )
    if image_files:
        result["source_kind"] = "mixed_media"
        result["source_kind_label"] = VIDEO_KIND_LABELS["mixed_media"]
        result["video_notice"] = "This folder mixes still images and video. The simple workflow is blocked; advanced video prep will use the video file only."
        result["simple_mode_blocked_reason"] = "Video import is limited to Advanced Options."
    return result


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def read_text_if_exists(path: Path) -> str:
    try:
        if path.exists():
            return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""
    return ""


def clean_console_text(text: str) -> str:
    return ANSI_ESCAPE_RE.sub("", text or "")


def summarize_lichtfeld_failure(job_root: str | Path | None, *, raw_error: str = "", status_hint: str = "") -> dict[str, str]:
    fallback = {
        "error": raw_error or "LichtFeld training stopped before a final splat was written.",
        "error_detail": "",
        "error_guidance": (
            "Open the Training Job folder to inspect the logs. "
            "If you try again, change something first if the same run is likely to hit the same limit."
        ),
    }
    if not job_root:
        return fallback

    root = Path(job_root)
    run_root = root / "run"
    train_log_path = run_root / "logs" / "train.log"
    stderr_log_path = root / "stderr.log"
    stdout_log_path = root / "stdout.log"
    state_path = run_root / "train_state.json"
    output_root = run_root / "training_output"
    checkpoint_dir = output_root / "checkpoints"

    combined = clean_console_text(
        "\n".join(
            part
            for part in (
                read_text_if_exists(train_log_path),
                read_text_if_exists(stderr_log_path),
                read_text_if_exists(stdout_log_path),
            )
            if part
        )
    )

    if "Insufficient GPU memory for arena initialization" in combined:
        image_match = re.search(r"Training with (\d+) images", combined)
        undistort_matches = re.findall(r"Undistort:\s+(\d+)x(\d+)\s+->\s+(\d+)x(\d+)", combined)
        fallback_state = None
        if state_path.exists():
            try:
                fallback_state = read_json(state_path).get("memory_fallback") or {}
            except Exception:
                fallback_state = None
        fallback_attempts = fallback_state.get("attempts") if isinstance(fallback_state, dict) else []
        attempted_tiles = [
            str(item.get("tile_mode"))
            for item in (fallback_attempts or [])
            if isinstance(item, dict) and item.get("status") == "failed-low-memory" and item.get("tile_mode")
        ]
        detail_parts = ["LichtFeld reported insufficient GPU memory during training startup."]
        if image_match:
            detail_parts.append(f"The run reached {image_match.group(1)} training images.")
        if undistort_matches:
            last = undistort_matches[-1]
            detail_parts.append(f"Undistorted frames were about {last[2]} x {last[3]}.")
        if attempted_tiles:
            detail_parts.append(f"The app already tried lower-memory tile mode(s): {', '.join(attempted_tiles)}.")
        return {
            "error": "Training ran out of GPU memory on this machine before the splat could be generated.",
            "error_detail": " ".join(detail_parts),
            "error_guidance": (
                "Try again with fewer or smaller images. "
                "If the app already retried in lower-memory tile mode, retrying the same folder unchanged is unlikely to help. "
                "A smaller image set, downscaled images, or a GPU with more VRAM is the practical next step."
            ),
        }

    reason_match = re.search(r"Training error:\s*(.+)", combined)
    if reason_match:
        return {
            "error": "LichtFeld training stopped before a final splat was written.",
            "error_detail": f"LichtFeld reported: {reason_match.group(1).strip()}",
            "error_guidance": fallback["error_guidance"],
        }

    has_checkpoint = checkpoint_dir.exists() and any(checkpoint_dir.glob("checkpoint_*.resume"))
    if status_hint == "stopped-needs-resume" and has_checkpoint:
        return {
            "error": "Training stopped before the final splat was written, but a partial checkpoint was saved.",
            "error_detail": f"A resume checkpoint exists under: {checkpoint_dir}",
            "error_guidance": (
                "The operator app does not resume partial LichtFeld runs automatically yet. "
                "Keep the checkpoint, then retry after reducing image count or image resolution if the same stop repeats."
            ),
        }

    if status_hint == "stopped-needs-resume" and state_path.exists():
        return {
            "error": "Training stopped before the final splat was written.",
            "error_detail": "A partial training state exists, but no completed result was written.",
            "error_guidance": fallback["error_guidance"],
        }

    return fallback


def summarize_workflow_failure(payload: dict[str, Any], raw_error: str, *, detail: str = "", guidance: str = "") -> dict[str, str]:
    current_stage = str(payload.get("current_stage") or "")
    if current_stage.startswith("training"):
        summary = summarize_lichtfeld_failure(
            payload.get("lichtfeld_job_root"),
            raw_error=raw_error,
            status_hint=raw_error,
        )
    else:
        summary = {
            "error": raw_error,
            "error_detail": "",
            "error_guidance": "",
        }

    if detail and not summary.get("error_detail"):
        summary["error_detail"] = detail
    if guidance and not summary.get("error_guidance"):
        summary["error_guidance"] = guidance
    return summary


def apply_lichtfeld_status_metadata(workflow_state: dict[str, Any], status_payload: dict[str, Any]) -> None:
    fallback = status_payload.get("memory_fallback") or {}
    active = bool(status_payload.get("memory_fallback_active"))
    used = bool(status_payload.get("memory_fallback_used"))
    completed = bool(status_payload.get("memory_fallback_completed"))

    tile_mode = status_payload.get("memory_fallback_tile_mode")
    try:
        tile_mode = int(tile_mode) if tile_mode not in (None, "") else 1
    except (TypeError, ValueError):
        tile_mode = 1

    message = str(status_payload.get("memory_fallback_message") or "").strip()
    attempts = fallback.get("attempts") if isinstance(fallback, dict) else []
    attempt_count = len(attempts) if isinstance(attempts, list) else 0

    workflow_state["low_memory_fallback_active"] = active
    workflow_state["low_memory_fallback_used"] = used
    workflow_state["low_memory_fallback_completed"] = completed
    workflow_state["training_tile_mode"] = tile_mode
    workflow_state["low_memory_fallback_message"] = message
    workflow_state["low_memory_fallback_attempt_count"] = attempt_count

    note = ""
    if active and tile_mode > 1:
        note = f"Lower-memory tile fallback is active (tile mode {tile_mode}). This can run slower and may slightly change result quality."
    elif completed and used and tile_mode > 1:
        note = f"This run finished using lower-memory tile mode {tile_mode}. It may have taken longer, and result quality may vary slightly."
    elif used and tile_mode > 1:
        note = f"This run switched to lower-memory tile mode {tile_mode}. It may run slower and result quality may vary slightly."
    elif message:
        note = message

    workflow_state["training_mode_note"] = note


def read_workflow_state(path: Path) -> dict[str, Any]:
    return enrich_workflow_state(read_json(path))


def save_workflow_state(path: Path, payload: dict[str, Any]) -> None:
    payload["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    write_json(path, enrich_workflow_state(payload))


def workflow_step_key(status: str, current_stage: str) -> str:
    if status == "completed":
        return "done"
    if status == "canceled":
        return WORKFLOW_STAGE_ALIASES.get(current_stage, "queued")
    if status == "failed":
        return WORKFLOW_STAGE_ALIASES.get(current_stage, "failed")
    return WORKFLOW_STAGE_ALIASES.get(current_stage, "queued")


def enrich_workflow_state(payload: dict[str, Any]) -> dict[str, Any]:
    result = dict(payload)
    status = str(result.get("status") or "")
    current_stage = str(result.get("current_stage") or "")
    if status == "failed":
        failure = summarize_workflow_failure(
            result,
            str(result.get("error") or "The workflow stopped with an error."),
            detail=str(result.get("error_detail") or ""),
            guidance=str(result.get("error_guidance") or ""),
        )
        result.update(failure)
    active_key = workflow_step_key(status, current_stage)
    step_lookup = {item["key"]: item for item in WORKFLOW_PROGRESS_STEPS}
    active_index = next((index for index, item in enumerate(WORKFLOW_PROGRESS_STEPS) if item["key"] == active_key), 0)
    if active_key == "failed":
        active_index = next((index for index, item in enumerate(WORKFLOW_PROGRESS_STEPS) if item["key"] == "training"), 0)
    stage_markers: list[dict[str, Any]] = []
    for index, item in enumerate(WORKFLOW_PROGRESS_STEPS):
        marker_state = "pending"
        if status == "completed":
            marker_state = "complete"
        elif status == "failed":
            if index < active_index:
                marker_state = "complete"
            elif index == active_index:
                marker_state = "error"
        else:
            if index < active_index:
                marker_state = "complete"
            elif index == active_index:
                marker_state = "active"
        stage_markers.append(
            {
                "key": item["key"],
                "label": item["label"],
                "progress": item["progress"],
                "state": marker_state,
            }
        )

    progress_percent = step_lookup.get(active_key, WORKFLOW_PROGRESS_STEPS[0])["progress"] if active_key != "failed" else stage_markers[active_index]["progress"]
    result.update(
        {
            "active_step_key": active_key,
            "progress_percent": progress_percent,
            "stage_markers": stage_markers,
        }
    )
    return result


def quality_preset(image_count: int, quality: str) -> dict[str, Any]:
    presets = {
        "fast-preview": {
            "label": "Fast-preview",
            "target_images": 96,
            "iterations": 6000,
            "sift_max_image_size": 2200,
            "matcher": "sequential",
            "strategy": "mcmc",
            "description": "Fastest result for a quick confidence check. Uses a reduced image sample and a shorter optimization run.",
        },
        "medium": {
            "label": "Medium",
            "target_images": 180,
            "iterations": 15000,
            "sift_max_image_size": 2800,
            "matcher": "sequential",
            "strategy": "mcmc",
            "description": "Balanced setting for a strong model without the longest wait. Keeps more images and trains longer.",
        },
        "high": {
            "label": "High",
            "target_images": image_count,
            "iterations": 30000,
            "sift_max_image_size": 3200,
            "matcher": "sequential",
            "strategy": "mcmc",
            "description": "Highest quality setting in the current app. Uses all available images and the longest training run.",
        },
    }

    if quality not in presets:
        raise AppError("Quality must be one of: fast-preview, medium, high.")

    preset = dict(presets[quality])
    target_images = min(image_count, int(preset["target_images"]))
    stride = max(1, math.ceil(image_count / max(1, target_images)))
    selected_images = math.ceil(image_count / stride)
    max_images = 0 if stride == 1 else target_images

    glomap_seconds = 45 + (2.45 * selected_images)
    prep_seconds = 5
    train_seconds = 0.143 * int(preset["iterations"])
    estimate_seconds = glomap_seconds + prep_seconds + train_seconds

    low_minutes = max(5, int((estimate_seconds * 0.8) / 60))
    high_minutes = max(low_minutes + 3, int((estimate_seconds * 1.25) / 60))

    preset.update(
        {
            "quality": quality,
            "selected_images": selected_images,
            "stride": stride,
            "max_images": max_images,
            "estimated_minutes_low": low_minutes,
            "estimated_minutes_high": high_minutes,
            "estimated_text": f"Roughly {low_minutes}-{high_minutes} minutes on this laptop for about {selected_images} working images.",
            "operator_text": (
                f"{preset['label']}: {preset['description']} "
                f"Estimated time: {low_minutes}-{high_minutes} minutes on this laptop."
            ),
        }
    )
    return preset


def latest_workflow_state() -> dict[str, Any] | None:
    states = workflow_states(limit=1)
    if not states:
        return None
    return states[0]


def workflow_states(*, limit: int | None = None) -> list[dict[str, Any]]:
    root = workflows_root()
    states = sorted(root.glob("workflow-*.json"), key=lambda item: item.stat().st_mtime, reverse=True)
    if limit is not None:
        states = states[:limit]
    return [read_workflow_state(item) for item in states]


def active_workflow_state() -> dict[str, Any] | None:
    for state in workflow_states(limit=12):
        if str(state.get("status") or "") in {"queued", "running"}:
            return state
    return None


def workflow_state_path(workflow_id: str) -> Path:
    if not re.fullmatch(r"workflow-\d{8}-\d{6}", workflow_id):
        raise AppError(f"Invalid workflow id: {workflow_id}")
    return workflows_root() / f"{workflow_id}.json"


def delete_workflow_record(payload: dict[str, Any]) -> dict[str, Any]:
    workflow_id = str(payload.get("workflow_id") or "").strip()
    if not workflow_id:
        raise AppError("Workflow id is required.")

    active = active_workflow_state()
    if active and str(active.get("workflow_id") or "") == workflow_id:
        raise AppError("The active workflow record cannot be removed while it is still running.")

    state_path = workflow_state_path(workflow_id)
    if not state_path.exists():
        raise AppError(f"Workflow record not found: {workflow_id}", 404)

    state_path.unlink()
    return {
        "message": f"Removed workflow record: {workflow_id}",
        "workflow_id": workflow_id,
    }


def clear_workflow_history(payload: dict[str, Any]) -> dict[str, Any]:
    remove_failed = to_bool(payload.get("remove_failed"), default=True)
    remove_completed = to_bool(payload.get("remove_completed"), default=True)
    active = active_workflow_state()
    active_id = str(active.get("workflow_id") or "") if active else ""
    removed: list[str] = []

    for state in workflow_states(limit=100):
        workflow_id = str(state.get("workflow_id") or "")
        status = str(state.get("status") or "")
        if not workflow_id or workflow_id == active_id:
            continue
        if status in {"failed", "canceled"} and remove_failed:
            workflow_state_path(workflow_id).unlink(missing_ok=True)
            removed.append(workflow_id)
        elif status == "completed" and remove_completed:
            workflow_state_path(workflow_id).unlink(missing_ok=True)
            removed.append(workflow_id)

    return {
        "message": f"Removed {len(removed)} workflow record(s).",
        "removed_workflow_ids": removed,
    }


def active_staged_paths(
    *,
    latest_workflow: dict[str, Any] | None = None,
    latest_glomap: dict[str, Any] | None = None,
    latest_lichtfeld: dict[str, Any] | None = None,
) -> set[Path]:
    active: set[Path] = set()
    workflow = latest_workflow
    if workflow and str(workflow.get("status") or "") in {"queued", "running"}:
        stage_path = str(workflow.get("staged_dataset_path") or "")
        if stage_path:
            active.add(Path(stage_path).resolve())

    for status_payload in (latest_glomap, latest_lichtfeld):
        if status_payload and str(status_payload.get("status") or "") == "running":
            stage_path = str(status_payload.get("staged_dataset_path") or "")
            if stage_path:
                active.add(Path(stage_path).resolve())

    return active


def current_active_staged_paths() -> set[Path]:
    return active_staged_paths(
        latest_workflow=latest_workflow_state(),
        latest_glomap=latest_glomap_status(),
        latest_lichtfeld=latest_lichtfeld_status(),
    )


def to_int(value: Any, *, default: int, minimum: int = 0, maximum: int | None = None) -> int:
    if value in (None, ""):
        result = default
    else:
        try:
            result = int(value)
        except (TypeError, ValueError) as exc:
            raise AppError(f"Expected an integer value, got: {value}") from exc
    if result < minimum:
        raise AppError(f"Value must be >= {minimum}.")
    if maximum is not None and result > maximum:
        raise AppError(f"Value must be <= {maximum}.")
    return result


def to_bool(value: Any, *, default: bool = False) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in {"1", "true", "yes", "on"}:
            return True
        if normalized in {"0", "false", "no", "off"}:
            return False
    raise AppError(f"Expected a boolean value, got: {value}")


def terminate_process_tree(process_id: int) -> bool:
    if process_id <= 0:
        return False

    creationflags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    completed = subprocess.run(
        ["taskkill.exe", "/PID", str(process_id), "/T", "/F"],
        capture_output=True,
        text=True,
        timeout=30,
        creationflags=creationflags,
    )
    combined = clean_console_text("\n".join(part for part in (completed.stdout, completed.stderr) if part)).lower()
    if completed.returncode == 0:
        return True
    if "not found" in combined or "no running instance" in combined or "process" in combined and "not found" in combined:
        return False
    raise AppError(
        f"Could not stop process tree for PID {process_id}.",
        500,
        detail=combined.strip(),
        guidance="Try again after closing any related PowerShell, COLMAP, GLOMAP, or LichtFeld windows.",
    )


def read_job_metadata(job_root_text: str) -> dict[str, Any] | None:
    if not job_root_text:
        return None
    job_root = Path(job_root_text)
    job_meta_path = job_root / "job.json"
    if not job_meta_path.exists():
        return None
    try:
        return read_json(job_meta_path)
    except Exception:
        return None


def find_matching_job_metadata(job_prefix: str, *, filters: dict[str, str]) -> list[dict[str, Any]]:
    jobs_root = existing_benchmark_path("jobs")
    if not jobs_root.exists():
        return []

    matches: list[tuple[str, dict[str, Any]]] = []
    for job_dir in jobs_root.iterdir():
        if not job_dir.is_dir() or not job_dir.name.startswith(job_prefix):
            continue
        job_meta = read_job_metadata(str(job_dir))
        if not job_meta:
            continue
        if any(str(job_meta.get(key) or "") != value for key, value in filters.items() if value):
            continue
        created_at = str(job_meta.get("created_at") or "")
        matches.append((created_at or str(job_dir.stat().st_mtime), job_meta))

    return [item for _, item in sorted(matches, key=lambda pair: pair[0], reverse=True)]


def workflow_cancel_requested(state_path: Path) -> bool:
    if not state_path.exists():
        return False
    try:
        payload = read_json(state_path)
    except Exception:
        return False
    return bool(payload.get("cancel_requested")) or str(payload.get("status") or "") == "canceled"


def candidate_workflow_process_ids(state: dict[str, Any]) -> list[int]:
    process_ids: set[int] = set()

    workflow_runner_pid = state.get("workflow_runner_pid")
    if workflow_runner_pid not in (None, ""):
        try:
            process_ids.add(int(workflow_runner_pid))
        except (TypeError, ValueError):
            pass

    glomap_meta = read_job_metadata(str(state.get("glomap_job_root") or ""))
    if not glomap_meta and str(state.get("staged_dataset_path") or "") and str(state.get("current_stage") or "").startswith("sparse"):
        matches = find_matching_job_metadata(
            "glomap-",
            filters={
                "staged_dataset_path": str(state.get("staged_dataset_path") or ""),
            },
        )
        glomap_meta = matches[0] if matches else None
    if glomap_meta and glomap_meta.get("process_id") not in (None, ""):
        try:
            process_ids.add(int(glomap_meta["process_id"]))
        except (TypeError, ValueError):
            pass

    lichtfeld_meta = read_job_metadata(str(state.get("lichtfeld_job_root") or ""))
    if not lichtfeld_meta and str(state.get("staged_dataset_path") or "") and str(state.get("current_stage") or "").startswith("training"):
        matches = find_matching_job_metadata(
            "lichtfeld-",
            filters={
                "staged_dataset_path": str(state.get("staged_dataset_path") or ""),
                "sparse_model_path": str(state.get("sparse_model_path") or ""),
            },
        )
        lichtfeld_meta = matches[0] if matches else None
    if lichtfeld_meta and lichtfeld_meta.get("process_id") not in (None, ""):
        try:
            process_ids.add(int(lichtfeld_meta["process_id"]))
        except (TypeError, ValueError):
            pass

    return sorted(process_ids)


def managed_workflow_artifact_paths(state: dict[str, Any]) -> list[Path]:
    candidates: list[Path] = []
    for key in ("staged_dataset_path", "glomap_job_root", "lichtfeld_job_root"):
        raw_value = str(state.get(key) or "").strip()
        if not raw_value:
            continue
        path = Path(raw_value)
        try:
            resolved = path.resolve()
        except OSError:
            resolved = path
        if is_under_root(resolved, INSTALL_ROOT):
            candidates.append(resolved)

    unique: list[Path] = []
    seen: set[str] = set()
    for path in sorted(candidates, key=lambda item: len(item.parts), reverse=True):
        normalized = str(path).lower()
        if normalized in seen:
            continue
        seen.add(normalized)
        unique.append(path)
    return unique


def delete_workflow_artifacts(state: dict[str, Any]) -> list[str]:
    deleted: list[str] = []
    for path in managed_workflow_artifact_paths(state):
        if not path.exists():
            continue
        try:
            if path.is_dir():
                shutil.rmtree(path)
            else:
                path.unlink(missing_ok=True)
            deleted.append(str(path))
        except OSError as exc:
            raise AppError(
                f"360GS could not remove a working folder for the canceled run: {path}",
                500,
                detail=str(exc),
                guidance="Close any open Explorer, PowerShell, COLMAP, GLOMAP, or LichtFeld windows for this run, then try canceling again.",
            ) from exc
    return deleted


def cancel_workflow(payload: dict[str, Any]) -> dict[str, Any]:
    workflow_id = str(payload.get("workflow_id") or "").strip()
    delete_generated = to_bool(payload.get("delete_generated"), default=False)

    if not workflow_id:
        active = active_workflow_state()
        if not active:
            raise AppError("No simple workflow is currently running.")
        workflow_id = str(active.get("workflow_id") or "")

    state_path = workflow_state_path(workflow_id)
    if not state_path.exists():
        raise AppError(f"Workflow record not found: {workflow_id}", 404)

    state = read_workflow_state(state_path)
    if str(state.get("status") or "") not in {"queued", "running"}:
        raise AppError("This workflow is no longer running.")

    state["cancel_requested"] = True
    state["cancel_requested_at"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    state["canceled_cleanup_requested"] = delete_generated
    save_workflow_state(state_path, state)

    stopped_process_ids: list[int] = []
    for process_id in candidate_workflow_process_ids(state):
        if terminate_process_tree(process_id):
            stopped_process_ids.append(process_id)

    if stopped_process_ids:
        time.sleep(0.8)

    deleted_paths: list[str] = []
    if delete_generated:
        deleted_paths = delete_workflow_artifacts(state)
        state["staged_dataset_path"] = ""
        state["glomap_job_root"] = ""
        state["lichtfeld_job_root"] = ""
        state["sparse_model_path"] = ""
        state["latest_splat"] = ""

    state["cancel_requested"] = False
    state["status"] = "canceled"
    state["status_text"] = (
        "This run was canceled and the 360GS working files were removed. Your source imagery was not changed."
        if delete_generated
        else "This run was canceled. The 360GS working files were kept, and your source imagery was not changed."
    )
    state["canceled_at"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    state["canceled_cleanup_performed"] = delete_generated
    state["canceled_deleted_paths"] = deleted_paths
    state["workflow_runner_pid"] = ""
    state["error"] = ""
    state["error_detail"] = ""
    state["error_guidance"] = ""
    save_workflow_state(state_path, state)

    return {
        "message": "The workflow was canceled.",
        "workflow_id": workflow_id,
        "deleted_paths": deleted_paths,
        "stopped_process_ids": stopped_process_ids,
        "source_imagery_changed": False,
    }


def parse_key_value_output(text: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or ":" not in line:
            continue
        key, value = line.split(":", 1)
        normalized = key.strip().lower().replace(" ", "_")
        result[normalized] = value.strip()
    return result


def run_powershell_script(script_name: str, arguments: list[str], *, expect_json: bool = False, timeout: int = 900) -> Any:
    script_path = BENCHMARK_ROOT / script_name
    if not script_path.exists():
        raise AppError(f"Required benchmark script is missing: {script_path}", 500)
    if not POWERSHELL_EXE.exists():
        raise AppError(f"PowerShell executable is missing: {POWERSHELL_EXE}", 500)

    command = [
        str(POWERSHELL_EXE),
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(script_path),
    ] + arguments

    completed = subprocess.run(
        command,
        cwd=str(INSTALL_ROOT),
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout or "").strip()
        raise AppError(detail or f"{script_name} failed with exit code {completed.returncode}.", 500)
    if expect_json:
        payload = completed.stdout.strip()
        if not payload:
            raise AppError(f"{script_name} returned no JSON payload.", 500)
        return json.loads(payload)
    return completed.stdout


def resolve_registry_local_path(value: str, registry_file: Path) -> str:
    """Resolve a dataset local_path; relative paths are relative to the project/install root."""
    if not value:
        return ""
    candidate = Path(value)
    if not candidate.is_absolute():
        candidate = registry_file.resolve().parent.parent / candidate
    return str(candidate)


def dataset_entries() -> list[dict[str, Any]]:
    registry_file = registry_path()
    registry = read_json(registry_file)
    datasets = registry.get("datasets", [])
    result: list[dict[str, Any]] = []
    for entry in datasets:
        local_path = resolve_registry_local_path(str(entry.get("local_path") or ""), registry_file)
        path_exists = bool(local_path) and Path(local_path).exists()
        result.append(
            {
                "id": entry.get("id", ""),
                "name": entry.get("name", ""),
                "task": entry.get("task", ""),
                "modality": entry.get("modality", ""),
                "homepage": entry.get("homepage", ""),
                "local_path": local_path,
                "local_path_exists": path_exists,
                "recommended_entry": entry.get("recommended_entry", ""),
                "notes": entry.get("notes", ""),
            }
        )
    return result


def staged_entries(*, active_paths: set[Path] | None = None) -> list[dict[str, Any]]:
    staged_root = existing_benchmark_path("staged")
    if not staged_root.exists():
        return []

    active_stage_paths = active_paths or set()
    items: list[tuple[str, dict[str, Any]]] = []
    for stage_dir in staged_root.iterdir():
        if not stage_dir.is_dir():
            continue
        manifest_path = stage_dir / "stage_manifest.json"
        if not manifest_path.exists():
            continue
        manifest = read_json(manifest_path)
        generated_at = str(manifest.get("generated_at") or "")
        stage_root_resolved = stage_dir.resolve()
        in_active_use = stage_root_resolved in active_stage_paths
        items.append(
            (
                generated_at or str(stage_dir.stat().st_mtime),
                {
                    "stage_name": stage_dir.name,
                    "stage_root": str(stage_dir),
                    "manifest_path": str(manifest_path),
                    "dataset_id": manifest.get("dataset_id", ""),
                    "dataset_name": manifest.get("dataset_name", ""),
                    "source_kind": manifest.get("source_kind", ""),
                    "source_variant": manifest.get("source_variant", ""),
                    "source_dataset_root": manifest.get("source_dataset_root", ""),
                    "quality_mode": manifest.get("quality_mode", ""),
                    "selected_image_count": manifest.get("selected_image_count", 0),
                    "derived_frame_count": manifest.get("derived_frame_count", 0),
                    "virtual_view_mode": manifest.get("virtual_view_mode", ""),
                    "staged_images_path": manifest.get("staged_images_path", ""),
                    "generated_at": generated_at,
                    "in_active_use": in_active_use,
                    "deletable": not in_active_use,
                },
            )
        )

    return [item for _, item in sorted(items, key=lambda pair: pair[0], reverse=True)]


def sparse_results() -> list[dict[str, Any]]:
    jobs_root = existing_benchmark_path("jobs")
    if not jobs_root.exists():
        return []

    items: list[tuple[str, dict[str, Any]]] = []
    for job_dir in jobs_root.iterdir():
        if not job_dir.is_dir() or not job_dir.name.startswith("glomap-"):
            continue
        report_path = job_dir / "run" / "benchmark_report.json"
        if not report_path.exists():
            continue
        report = read_json(report_path)
        generated_at = str(report.get("generated_at") or "")
        items.append(
            (
                generated_at or str(report_path.stat().st_mtime),
                {
                    "job_id": job_dir.name,
                    "job_root": str(job_dir),
                    "run_root": str(job_dir / "run"),
                    "dataset_id": report.get("dataset_id", ""),
                    "staged_dataset_path": report.get("staged_dataset_path", ""),
                    "sparse_output_path": report.get("sparse_output_path", ""),
                    "report_path": str(report_path),
                    "matcher": report.get("matcher", ""),
                    "used_gpu": bool(report.get("used_gpu", False)),
                    "generated_at": generated_at,
                },
            )
        )

    return [item for _, item in sorted(items, key=lambda pair: pair[0], reverse=True)]


def recover_detached_job(job_prefix: str, *, filters: dict[str, str]) -> dict[str, Any] | None:
    jobs_root = existing_benchmark_path("jobs")
    if not jobs_root.exists():
        return None

    matches: list[tuple[str, dict[str, Any]]] = []
    for job_dir in jobs_root.iterdir():
        if not job_dir.is_dir() or not job_dir.name.startswith(job_prefix):
            continue
        job_meta_path = job_dir / "job.json"
        if not job_meta_path.exists():
            continue
        job_meta = read_json(job_meta_path)
        if any(str(job_meta.get(key) or "") != value for key, value in filters.items()):
            continue
        created_at = str(job_meta.get("created_at") or "")
        matches.append(
            (
                created_at or str(job_meta_path.stat().st_mtime),
                {
                    "job_id": str(job_meta.get("job_id") or job_dir.name),
                    "job_root": str(job_dir),
                    "run_root": str(job_meta.get("run_root") or (job_dir / "run")),
                    "stdout_log": str(job_meta.get("stdout_log") or (job_dir / "stdout.log")),
                    "stderr_log": str(job_meta.get("stderr_log") or (job_dir / "stderr.log")),
                    "recovered_after_timeout": True,
                },
            )
        )

    if not matches:
        return None
    return sorted(matches, key=lambda item: item[0], reverse=True)[0][1]


def latest_glomap_status() -> dict[str, Any] | None:
    try:
        return run_powershell_script("Get-BenchmarkJobStatus.ps1", ["-Latest"], expect_json=True)
    except AppError as exc:
        if "No benchmark jobs found" in str(exc) or "Jobs root not found" in str(exc):
            return None
        raise


def latest_lichtfeld_status() -> dict[str, Any] | None:
    try:
        return run_powershell_script("Get-LichtFeldTrainingJobStatus.ps1", ["-Latest"], expect_json=True)
    except AppError as exc:
        if "No LichtFeld jobs found" in str(exc) or "Jobs root not found" in str(exc):
            return None
        raise


def install_status() -> dict[str, Any]:
    capability = pipeline_capabilities()
    ffmpeg_tools = INSTALL_ROOT / "tools"
    return {
        "install_root": str(INSTALL_ROOT),
        "registry_path": str(registry_path()),
        "app_entrypoint": str(APP_ROOT / "main.py"),
        "has_colmap_global": capability["has_colmap_global"],
        "has_glomap_standalone": capability["has_glomap_standalone"],
        "has_lichtfeld": capability["has_lichtfeld"],
        "has_sharp_preview": capability["has_sharp_preview"],
        "simple_workflow_ready": capability["simple_workflow_ready"],
        "missing_simple_workflow_components": capability["missing_simple_workflow_components"],
        "simple_workflow_note": capability["simple_workflow_note"],
        "has_ffmpeg_tools": ffmpeg_tools.exists(),
        "windows": windows_platform_info(),
        "preferred_shell": str(POWERSHELL_EXE),
        "jobs_root": str(existing_benchmark_path("jobs")),
        "staged_root": str(existing_benchmark_path("staged")),
        "results_root": str(existing_benchmark_path("results")),
    }


def overview_payload() -> dict[str, Any]:
    latest_glomap = latest_glomap_status()
    latest_lichtfeld = latest_lichtfeld_status()
    latest_workflow = latest_workflow_state()
    active_workflow = active_workflow_state()
    recent_workflows = workflow_states(limit=6)
    active_paths = active_staged_paths(
        latest_workflow=active_workflow or latest_workflow,
        latest_glomap=latest_glomap,
        latest_lichtfeld=latest_lichtfeld,
    )
    return {
        "status": install_status(),
        "datasets": dataset_entries(),
        "staged": staged_entries(active_paths=active_paths)[:12],
        "sparse_results": sparse_results()[:12],
        "latest_glomap_status": latest_glomap,
        "latest_lichtfeld_status": latest_lichtfeld,
        "active_workflow": active_workflow,
        "latest_workflow": latest_workflow,
        "recent_workflows": recent_workflows,
    }


def inspect_image_folder(payload: dict[str, Any]) -> dict[str, Any]:
    folder = assert_existing_directory_anywhere(str(payload.get("folder_path") or ""))
    inspection = inspect_media_source_path(str(folder))
    capability = pipeline_capabilities()
    if inspection.get("video_count"):
        return {
            "folder_path": str(folder),
            "image_count": int(inspection.get("image_count") or 0),
            "video_count": int(inspection.get("video_count") or 0),
            "media_kind": str(inspection.get("source_kind") or "mixed_media"),
            "video_notice": str(inspection.get("video_notice") or "Video import is limited to Advanced Options."),
            "simple_mode_blocked_reason": str(inspection.get("simple_mode_blocked_reason") or "Video import is limited to Advanced Options."),
            "simple_workflow_ready": capability["simple_workflow_ready"],
            "quality_options": {},
        }

    image_count = int(inspection.get("image_count") or 0)
    if image_count == 0:
        raise AppError("No supported image files were found in that folder.")

    presets = {
        quality: quality_preset(image_count, quality)
        for quality in ("fast-preview", "medium", "high")
    }
    return {
        "folder_path": str(folder),
        "image_count": image_count,
        "video_count": 0,
        "media_kind": "image_folder",
        "video_notice": "",
        "simple_mode_blocked_reason": "" if capability["simple_workflow_ready"] else capability["simple_workflow_note"],
        "simple_workflow_ready": capability["simple_workflow_ready"],
        "quality_options": presets if capability["simple_workflow_ready"] else {},
    }


def inspect_media(payload: dict[str, Any]) -> dict[str, Any]:
    source_path = str(payload.get("source_path") or "").strip()
    if not source_path:
        raise AppError("A media source path is required.")
    return inspect_media_source_path(source_path)


def create_custom_stage(folder: Path, preset: dict[str, Any]) -> dict[str, Any]:
    all_images = image_files_in_folder(folder)
    if not all_images:
        raise AppError("No supported image files were found in that folder.")

    selected = all_images[:: int(preset["stride"])]
    if preset["max_images"]:
        selected = selected[: int(preset["max_images"])]
    if not selected:
        raise AppError("The selected quality preset produced zero images.")

    stage_root = existing_benchmark_path("staged") / f"adhoc-{slugify(folder.name)}-{time.strftime('%Y%m%d-%H%M%S')}"
    images_root = stage_root / "images"
    images_root.mkdir(parents=True, exist_ok=True)

    for image_path in selected:
        shutil.copy2(image_path, images_root / image_path.name)

    manifest = {
        "dataset_id": f"adhoc-{slugify(folder.name)}",
        "dataset_name": folder.name,
        "dataset_task": "custom-folder",
        "dataset_homepage": "",
        "source_dataset_root": str(folder),
        "source_variant": "",
        "source_variant_path": str(folder),
        "total_source_images": len(all_images),
        "selected_image_count": len(selected),
        "stride": int(preset["stride"]),
        "start_index": 0,
        "max_images": int(preset["max_images"]),
        "staged_root": str(stage_root),
        "staged_images_path": str(images_root),
        "selected_images": [item.name for item in selected],
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "quality_mode": preset["quality"],
    }
    write_json(stage_root / "stage_manifest.json", manifest)
    return manifest


def prepare_media_stage(payload: dict[str, Any]) -> dict[str, Any]:
    source_path = str(payload.get("source_path") or "").strip()
    if not source_path:
        raise AppError("A media source path is required.")

    inspection = inspect_media_source_path(source_path)
    source_kind = str(inspection.get("source_kind") or "")
    resolved_video_path = str(inspection.get("resolved_video_path") or "")
    if source_kind == "mixed_media":
        source_kind = str(detect_video_kind(Path(resolved_video_path), ffprobe_media_info(Path(resolved_video_path)))[0])
    if source_kind not in {"standard_video", "video_360_equirect"}:
        raise AppError(str(inspection.get("video_notice") or "This media source is not supported for Advanced video import."))

    quality = str(payload.get("quality") or "").strip().lower()
    if not quality:
        quality = str(inspection.get("recommended_quality") or "medium")
    info = ffprobe_media_info(Path(resolved_video_path))
    preset = video_quality_preset(source_kind, quality, info)

    arguments = [
        "-SourcePath",
        resolved_video_path,
        "-SourceKind",
        source_kind,
        "-Quality",
        quality,
        "-ExtractionFps",
        str(preset["extraction_fps"]),
        "-TargetFrames",
        str(int(preset.get("target_frames") or 0)),
        "-TargetTimestamps",
        str(int(preset.get("target_timestamps") or 0)),
        "-MaxOutputWidth",
        str(int(preset.get("max_output_width") or 0)),
        "-VirtualViewMode",
        str(preset.get("virtual_view_mode") or ""),
        "-ViewWidth",
        str(int(preset.get("view_width") or 0)),
        "-ViewHeight",
        str(int(preset.get("view_height") or 0)),
    ]
    if to_bool(preset.get("use_scene_detect"), default=False):
        arguments.append("-UseSceneDetectRequested")

    stdout = run_powershell_script("Prepare-MediaDataset.ps1", arguments, timeout=3600)
    parsed = parse_key_value_output(stdout)
    return {
        "message": "Media prepared as a staged dataset.",
        "stage_root": parsed.get("stage_root", ""),
        "manifest_path": parsed.get("manifest", ""),
        "selected_image_count": parsed.get("selected_images", ""),
        "source_kind": source_kind,
        "quality": quality,
        "stdout": stdout,
    }


def start_background_workflow(payload: dict[str, Any]) -> dict[str, Any]:
    require_simple_workflow_capability()
    folder = assert_existing_directory_anywhere(str(payload.get("folder_path") or ""))
    inspection = inspect_media_source_path(str(folder))
    if int(inspection.get("video_count") or 0) > 0:
        raise AppError(str(inspection.get("video_notice") or "Video import is limited to Advanced Options."))
    image_count = int(inspection.get("image_count") or 0)
    if image_count == 0:
        raise AppError("No supported image files were found in that folder.")

    quality = str(payload.get("quality") or "").strip().lower()
    preset = quality_preset(image_count, quality)
    workflow_id = "workflow-" + time.strftime("%Y%m%d-%H%M%S")
    state_path = workflows_root() / f"{workflow_id}.json"
    state = {
        "workflow_id": workflow_id,
        "status": "queued",
        "current_stage": "queued",
        "status_text": "Workflow queued.",
        "source_folder": str(folder),
        "image_count": image_count,
        "quality": quality,
        "quality_preset": preset,
        "staged_dataset_path": "",
        "glomap_job_id": "",
        "glomap_job_root": "",
        "lichtfeld_job_id": "",
        "lichtfeld_job_root": "",
        "sparse_model_path": "",
        "latest_splat": "",
        "workflow_runner_pid": "",
        "cancel_requested": False,
        "cancel_requested_at": "",
        "canceled_at": "",
        "canceled_cleanup_requested": False,
        "canceled_cleanup_performed": False,
        "canceled_deleted_paths": [],
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "updated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "error": "",
        "error_detail": "",
        "error_guidance": "",
        "low_memory_fallback_active": False,
        "low_memory_fallback_used": False,
        "low_memory_fallback_completed": False,
        "training_tile_mode": 1,
        "training_mode_note": "",
    }
    write_json(state_path, state)

    creationflags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    proc = subprocess.Popen(
        [sys.executable, str(APP_ROOT / "main.py"), "--run-workflow", str(state_path)],
        cwd=str(INSTALL_ROOT),
        creationflags=creationflags,
    )
    state["workflow_runner_pid"] = proc.pid
    write_json(state_path, state)
    return {
        "message": "Create Splat workflow started.",
        "workflow_id": workflow_id,
        "state_path": str(state_path),
        "quality_preset": preset,
    }


def run_background_workflow(state_path: Path) -> int:
    state = read_workflow_state(state_path)

    def throw_if_workflow_canceled() -> None:
        if workflow_cancel_requested(state_path):
            raise WorkflowCanceledError()

    def update(status: str, stage: str, text: str, **extra: Any) -> None:
        throw_if_workflow_canceled()
        state["status"] = status
        state["current_stage"] = stage
        state["status_text"] = text
        state.update(extra)
        save_workflow_state(state_path, state)

    try:
        throw_if_workflow_canceled()
        folder = assert_existing_directory_anywhere(str(state.get("source_folder") or ""))
        preset = state["quality_preset"]

        update("running", "staging", "Copying the selected images into a managed staging area.")
        manifest = create_custom_stage(folder, preset)
        state["staged_dataset_path"] = manifest["staged_root"]
        save_workflow_state(state_path, state)
        throw_if_workflow_canceled()

        update("running", "sparse-start", "Starting sparse reconstruction.")
        glomap_result = launch_glomap_job(
            {
                "staged_dataset_path": manifest["staged_root"],
                "matcher": preset["matcher"],
                "sift_max_image_size": preset["sift_max_image_size"],
                "random_seed": 0,
                "use_gpu": True,
                "single_camera": True,
            }
        )
        state["glomap_job_id"] = glomap_result["job_id"]
        state["glomap_job_root"] = glomap_result["job_root"]
        save_workflow_state(state_path, state)
        throw_if_workflow_canceled()

        update("running", "sparse-running", "Sparse reconstruction is running.")
        while True:
            throw_if_workflow_canceled()
            status = run_powershell_script("Get-BenchmarkJobStatus.ps1", ["-JobId", state["glomap_job_id"]], expect_json=True)
            if status["status"] == "completed":
                break
            if status["status"] != "running":
                raise AppError(f"Sparse reconstruction stopped unexpectedly with status: {status['status']}", 500)
            time.sleep(5)

        benchmark_report = read_json(Path(status["report_path"]))
        sparse_model_path = str(benchmark_report["sparse_output_path"])
        state["sparse_model_path"] = sparse_model_path

        throw_if_workflow_canceled()
        update("running", "training-start", "Starting LichtFeld training.")
        lichtfeld_result = launch_lichtfeld_job(
            {
                "staged_dataset_path": manifest["staged_root"],
                "sparse_model_path": sparse_model_path,
                "strategy": preset["strategy"],
                "images_mode": "junction",
                "iterations": preset["iterations"],
            }
        )
        state["lichtfeld_job_id"] = lichtfeld_result["job_id"]
        state["lichtfeld_job_root"] = lichtfeld_result["job_root"]
        save_workflow_state(state_path, state)
        throw_if_workflow_canceled()

        update("running", "training-running", "LichtFeld training is running.")
        while True:
            throw_if_workflow_canceled()
            status = run_powershell_script("Get-LichtFeldTrainingJobStatus.ps1", ["-JobId", state["lichtfeld_job_id"]], expect_json=True)
            apply_lichtfeld_status_metadata(state, status)
            if status["status"] == "completed":
                state["latest_splat"] = str(status.get("latest_splat") or "")
                save_workflow_state(state_path, state)
                break
            if state.get("low_memory_fallback_active"):
                state["status_text"] = str(state.get("training_mode_note") or "LichtFeld training is running in lower-memory tile mode.")
            else:
                state["status_text"] = "LichtFeld training is running."
            save_workflow_state(state_path, state)
            if status["status"] != "running":
                summary = summarize_lichtfeld_failure(
                    state.get("lichtfeld_job_root"),
                    raw_error=str(status.get("error_message") or f"LichtFeld training stopped unexpectedly with status: {status['status']}"),
                    status_hint=str(status.get("status") or ""),
                )
                raise AppError(
                    summary["error"],
                    500,
                    detail=summary.get("error_detail", ""),
                    guidance=summary.get("error_guidance", ""),
                )
            time.sleep(10)

        completed_text = (
            "Splat complete. The app used a slower lower-memory tile fallback to finish on this machine. Quality may vary slightly."
            if state.get("low_memory_fallback_completed")
            else "Splat complete. Open the output folder or latest model."
        )
        update("completed", "done", completed_text, latest_splat=state["latest_splat"])
        return 0
    except WorkflowCanceledError:
        return 2
    except Exception as exc:  # pragma: no cover
        failed_stage = str(state.get("current_stage") or "failed")
        detail = exc.detail if isinstance(exc, AppError) else ""
        guidance = exc.guidance if isinstance(exc, AppError) else ""
        failure = summarize_workflow_failure(state, str(exc), detail=detail, guidance=guidance)
        update(
            "failed",
            failed_stage,
            "The workflow stopped with an error.",
            error=failure["error"],
            error_detail=failure.get("error_detail", ""),
            error_guidance=failure.get("error_guidance", ""),
        )
        return 1


def launch_stage_job(payload: dict[str, Any]) -> dict[str, Any]:
    dataset_id = str(payload.get("dataset_id") or "").strip()
    if not dataset_id:
        raise AppError("Dataset selection is required.")

    arguments = ["-DatasetId", dataset_id]
    variant = str(payload.get("variant") or "").strip()
    if variant:
        arguments += ["-Variant", variant]

    max_images = to_int(payload.get("max_images"), default=0, minimum=0, maximum=50000)
    stride = to_int(payload.get("stride"), default=1, minimum=1, maximum=50000)
    start_index = to_int(payload.get("start_index"), default=0, minimum=0, maximum=50000)
    arguments += ["-MaxImages", str(max_images), "-Stride", str(stride), "-StartIndex", str(start_index)]

    stdout = run_powershell_script("Stage-Dataset.ps1", arguments, timeout=1800)
    parsed = parse_key_value_output(stdout)
    return {
        "message": "Dataset staged.",
        "stage_root": parsed.get("stage_root", ""),
        "manifest_path": parsed.get("manifest", ""),
        "source_variant": parsed.get("source_variant", ""),
        "stdout": stdout,
    }


def launch_glomap_job(payload: dict[str, Any]) -> dict[str, Any]:
    require_glomap_capability()
    staged_dataset_path = assert_allowed_path(str(payload.get("staged_dataset_path") or ""))
    matcher = str(payload.get("matcher") or "sequential").strip().lower()
    if matcher not in {"sequential", "vocab_tree"}:
        raise AppError("Matcher must be 'sequential' or 'vocab_tree'.")

    arguments = [
        "-StagedDatasetPath",
        str(staged_dataset_path),
        "-Matcher",
        matcher,
        "-SiftMaxImageSize",
        str(to_int(payload.get("sift_max_image_size"), default=2400, minimum=256, maximum=10000)),
        "-RandomSeed",
        str(to_int(payload.get("random_seed"), default=0, minimum=0, maximum=2147483647)),
    ]

    if to_bool(payload.get("use_gpu"), default=False):
        arguments.append("-UseGpu")

    if to_bool(payload.get("single_camera"), default=True):
        arguments.append("-SingleCamera")
    else:
        arguments.append("-SingleCamera:$false")

    try:
        stdout = run_powershell_script("Start-GlomapBenchmarkJob.ps1", arguments, timeout=120)
        parsed = parse_key_value_output(stdout)
        return {
            "message": "GLOMAP job started.",
            "job_id": parsed.get("job_id", ""),
            "job_root": parsed.get("job_root", ""),
            "run_root": parsed.get("run_root", ""),
            "stdout": stdout,
        }
    except subprocess.TimeoutExpired as exc:
        recovered = recover_detached_job(
            "glomap-",
            filters={
                "staged_dataset_path": str(staged_dataset_path),
                "matcher": matcher,
            },
        )
        if recovered:
            recovered["message"] = "GLOMAP job started after recovering a slow launcher response."
            recovered["stdout"] = str(exc.stdout or "")
            return recovered
        raise AppError("Timed out while waiting for the GLOMAP launcher to return a job id.", 500) from exc


def launch_lichtfeld_job(payload: dict[str, Any]) -> dict[str, Any]:
    require_lichtfeld_capability()
    staged_dataset_path = assert_allowed_path(str(payload.get("staged_dataset_path") or ""))
    sparse_model_path = assert_allowed_path(str(payload.get("sparse_model_path") or ""))
    strategy = str(payload.get("strategy") or "mcmc").strip().lower()
    if strategy not in {"mcmc", "adc"}:
        raise AppError("Strategy must be 'mcmc' or 'adc'.")

    images_mode = str(payload.get("images_mode") or "junction").strip().lower()
    if images_mode not in {"junction", "copy"}:
        raise AppError("Images mode must be 'junction' or 'copy'.")

    arguments = [
        "-StagedDatasetPath",
        str(staged_dataset_path),
        "-SparseModelPath",
        str(sparse_model_path),
        "-Strategy",
        strategy,
        "-ImagesMode",
        images_mode,
        "-Iterations",
        str(to_int(payload.get("iterations"), default=1000, minimum=1, maximum=500000)),
    ]

    try:
        stdout = run_powershell_script("Start-LichtFeldTrainingJob.ps1", arguments, timeout=120)
        parsed = parse_key_value_output(stdout)
        return {
            "message": "LichtFeld training job started.",
            "job_id": parsed.get("job_id", ""),
            "job_root": parsed.get("job_root", ""),
            "run_root": parsed.get("run_root", ""),
            "stdout": stdout,
        }
    except subprocess.TimeoutExpired as exc:
        recovered = recover_detached_job(
            "lichtfeld-",
            filters={
                "staged_dataset_path": str(staged_dataset_path),
                "sparse_model_path": str(sparse_model_path),
            },
        )
        if recovered:
            recovered["message"] = "LichtFeld training started after recovering a slow launcher response."
            recovered["stdout"] = str(exc.stdout or "")
            return recovered
        raise AppError("Timed out while waiting for the LichtFeld launcher to return a job id.", 500) from exc


def delete_staged_dataset(payload: dict[str, Any]) -> dict[str, Any]:
    stage_root = assert_allowed_path(str(payload.get("stage_root") or ""))
    if not stage_root.is_dir():
        raise AppError(f"Staged dataset path is not a folder: {stage_root}")
    if not any(is_under_root(stage_root, root) for root in managed_staged_roots()):
        raise AppError(f"Only managed staged datasets can be deleted from the app: {stage_root}")

    manifest_path = stage_root / "stage_manifest.json"
    if not manifest_path.exists():
        raise AppError(f"Stage manifest not found in staged dataset: {manifest_path}")

    latest_workflow = latest_workflow_state()
    latest_glomap = latest_glomap_status()
    latest_lichtfeld = latest_lichtfeld_status()
    if stage_root.resolve() in active_staged_paths(
        latest_workflow=latest_workflow,
        latest_glomap=latest_glomap,
        latest_lichtfeld=latest_lichtfeld,
    ):
        raise AppError("That staged dataset is currently in use and cannot be deleted right now.")

    shutil.rmtree(stage_root)
    return {
        "message": f"Deleted staged dataset: {stage_root.name}",
        "deleted_path": str(stage_root),
    }


def open_folder(payload: dict[str, Any]) -> dict[str, Any]:
    folder = assert_allowed_path(str(payload.get("path") or ""))
    subprocess.Popen(["explorer.exe", str(folder)])
    return {"message": f"Opened folder: {folder}"}


def open_lichtfeld() -> dict[str, Any]:
    return open_splat({})


def open_splat(payload: dict[str, Any]) -> dict[str, Any]:
    launcher = INSTALL_ROOT / "openlichtfeld.cmd"
    require_lichtfeld_capability()
    if not launcher.exists():
        raise AppError("LichtFeld Studio is not installed in this managed runtime.")

    splat_path_value = str(payload.get("splat_path") or "").strip()
    if splat_path_value:
        splat_path = assert_allowed_path(splat_path_value)
        if splat_path.suffix.lower() not in {".ply", ".sog", ".spz", ".resume"}:
            raise AppError(f"360GS can only open supported model files in LichtFeld Studio: {splat_path.name}")
        subprocess.Popen(["cmd.exe", "/c", str(launcher), "--view", str(splat_path)], cwd=str(INSTALL_ROOT))
        return {"message": f"Opening model in LichtFeld Studio: {splat_path.name}"}

    subprocess.Popen(["cmd.exe", "/c", str(launcher)], cwd=str(INSTALL_ROOT))
    return {"message": "Opening LichtFeld Studio."}


def run_self_test() -> int:
    checks: list[dict[str, Any]] = []

    def add_check(name: str, ok: bool, detail: str) -> None:
        checks.append({"name": name, "ok": ok, "detail": detail})

    required_files = [
        APP_ROOT / "main.py",
        WEB_ROOT / "index.html",
        WEB_ROOT / "app.css",
        WEB_ROOT / "app.js",
        BENCHMARK_ROOT / "Prepare-MediaDataset.ps1",
        BENCHMARK_ROOT / "Stage-Dataset.ps1",
        BENCHMARK_ROOT / "Start-GlomapBenchmarkJob.ps1",
        BENCHMARK_ROOT / "Start-LichtFeldTrainingJob.ps1",
        BENCHMARK_ROOT / "Get-BenchmarkJobStatus.ps1",
        BENCHMARK_ROOT / "Get-LichtFeldTrainingJobStatus.ps1",
        BENCHMARK_ROOT / "lib" / "Benchmark.Common.ps1",
    ]

    for path in required_files:
        add_check(path.name, path.exists(), str(path))

    try:
        resolved_registry = registry_path()
        add_check(resolved_registry.name, resolved_registry.exists(), str(resolved_registry))
    except AppError as exc:
        add_check("dataset-registry", False, str(exc))

    report = {
        "ok": all(item["ok"] for item in checks),
        "install_root": str(INSTALL_ROOT),
        "checks": checks,
    }
    print(json.dumps(report, indent=2))
    return 0 if report["ok"] else 2


class AppRequestHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args: Any, **kwargs: Any) -> None:
        super().__init__(*args, directory=str(WEB_ROOT), **kwargs)

    def log_message(self, format_text: str, *args: Any) -> None:
        sys.stdout.write("[app] " + format_text % args + "\n")

    def end_headers(self) -> None:
        # Avoid stale cached frontend assets after an in-place installed app update.
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        super().end_headers()

    def send_json(self, payload: dict[str, Any], status_code: int = 200) -> None:
        body = json.dumps(payload, indent=2).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def read_payload(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0:
            return {}
        data = self.rfile.read(length)
        if not data:
            return {}
        try:
            return json.loads(data.decode("utf-8"))
        except json.JSONDecodeError as exc:
            raise AppError("Request body must be valid JSON.") from exc

    def canonical_post_path(self, path: str) -> str:
        aliases = {
            "/api/inspect-folder": "/api/actions/inspect-folder",
            "/api/inspect-media": "/api/actions/inspect-media",
            "/api/create-splat": "/api/actions/create-splat",
            "/api/cancel-workflow": "/api/actions/cancel-workflow",
            "/api/prepare-media": "/api/actions/prepare-media",
            "/api/stage": "/api/actions/stage",
            "/api/start-glomap": "/api/actions/start-glomap",
            "/api/start-lichtfeld": "/api/actions/start-lichtfeld",
            "/api/delete-staged": "/api/actions/delete-staged",
            "/api/open-folder": "/api/actions/open-folder",
            "/api/open-lichtfeld": "/api/actions/open-lichtfeld",
            "/api/open-splat": "/api/actions/open-splat",
        }
        return aliases.get(path, path)

    def canonical_get_path(self, path: str) -> str:
        aliases = {
            "/api/status": "/api/overview",
            "/api/workflow/latest": "/api/workflows/latest",
        }
        return aliases.get(path, path)

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path.startswith("/api/"):
            self.handle_api_get(parsed.path)
            return
        self.path = "/index.html" if parsed.path in {"", "/"} else parsed.path
        super().do_GET()

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        if not parsed.path.startswith("/api/"):
            self.send_error(404)
            return
        try:
            payload = self.read_payload()
            path = self.canonical_post_path(parsed.path)
            if path == "/api/actions/inspect-folder":
                result = inspect_image_folder(payload)
            elif path == "/api/actions/inspect-media":
                result = inspect_media(payload)
            elif path == "/api/actions/create-splat":
                result = start_background_workflow(payload)
            elif path == "/api/actions/cancel-workflow":
                result = cancel_workflow(payload)
            elif path == "/api/actions/prepare-media":
                result = prepare_media_stage(payload)
            elif path == "/api/actions/stage":
                result = launch_stage_job(payload)
            elif path == "/api/actions/start-glomap":
                result = launch_glomap_job(payload)
            elif path == "/api/actions/start-lichtfeld":
                result = launch_lichtfeld_job(payload)
            elif path == "/api/actions/delete-staged":
                result = delete_staged_dataset(payload)
            elif path == "/api/actions/delete-workflow":
                result = delete_workflow_record(payload)
            elif path == "/api/actions/clear-workflow-history":
                result = clear_workflow_history(payload)
            elif path == "/api/actions/open-folder":
                result = open_folder(payload)
            elif path == "/api/actions/open-lichtfeld":
                result = open_lichtfeld()
            elif path == "/api/actions/open-splat":
                result = open_splat(payload)
            else:
                self.send_error(404)
                return
            self.send_json(result)
        except AppError as exc:
            self.send_json({"error": str(exc), "detail": exc.detail, "guidance": exc.guidance}, exc.status_code)
        except Exception as exc:  # pragma: no cover
            self.send_json({"error": str(exc)}, 500)

    def handle_api_get(self, path: str) -> None:
        try:
            canonical_path = self.canonical_get_path(path)
            if canonical_path == "/api/health":
                payload = {"ok": True, "install_root": str(INSTALL_ROOT), "app_root": str(APP_ROOT)}
            elif canonical_path == "/api/overview":
                payload = overview_payload()
            elif canonical_path == "/api/datasets":
                payload = {"items": dataset_entries()}
            elif canonical_path == "/api/staged":
                payload = {"items": staged_entries(active_paths=current_active_staged_paths())}
            elif canonical_path == "/api/sparse-results":
                payload = {"items": sparse_results()}
            elif canonical_path == "/api/status/glomap/latest":
                payload = {"item": latest_glomap_status()}
            elif canonical_path == "/api/status/lichtfeld/latest":
                payload = {"item": latest_lichtfeld_status()}
            elif canonical_path == "/api/workflows/latest":
                payload = {"item": latest_workflow_state()}
            elif canonical_path == "/api/workflows/active":
                payload = {"item": active_workflow_state()}
            elif canonical_path == "/api/workflows":
                payload = {"items": workflow_states(limit=20)}
            else:
                self.send_error(404)
                return
            self.send_json(payload)
        except AppError as exc:
            self.send_json({"error": str(exc), "detail": exc.detail, "guidance": exc.guidance}, exc.status_code)
        except Exception as exc:  # pragma: no cover
            self.send_json({"error": str(exc)}, 500)


def choose_port(host: str, preferred_port: int) -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            probe.bind((host, preferred_port))
            return preferred_port
        except OSError:
            probe.bind((host, 0))
            return int(probe.getsockname()[1])


def serve(host: str, port: int, open_browser: bool) -> int:
    resolved_port = choose_port(host, port)
    server = ThreadingHTTPServer((host, resolved_port), AppRequestHandler)
    url = f"http://{host}:{resolved_port}/"
    print(f"360GS operator app running at {url}")

    if open_browser:
        threading.Thread(target=lambda: (time.sleep(0.6), webbrowser.open(url)), daemon=True).start()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("Stopping 360GS operator app.")
    finally:
        server.server_close()
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="360GS operator app")
    parser.add_argument("--host", default="127.0.0.1", help="Bind address for the local operator app.")
    parser.add_argument("--port", type=int, default=36061, help="Preferred local port.")
    parser.add_argument("--no-browser", action="store_true", help="Do not open the browser automatically.")
    parser.add_argument("--self-test", action="store_true", help="Validate that the app payload is installed correctly.")
    parser.add_argument("--run-workflow", help="Run a background workflow state file.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.self_test:
        return run_self_test()
    if args.run_workflow:
        return run_background_workflow(Path(args.run_workflow))
    return serve(args.host, args.port, open_browser=not args.no_browser)


if __name__ == "__main__":
    raise SystemExit(main())

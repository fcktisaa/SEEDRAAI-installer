#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="9.0.0"
REPO_ID="${SEEDRA_REPO_ID:-SEEDRAAI/SEEDRAAI}"
REVISION="${SEEDRA_REVISION:-main}"
WORKERS="${SEEDRA_WORKERS:-}"
COMFY_DIR="${COMFY_DIR:-}"
HF_TOKEN="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}"
FORCE="${SEEDRA_FORCE:-0}"
COMPAT_ALIASES="${SEEDRA_COMPAT_ALIASES:-0}"
SKIP_EXTERNAL="${SEEDRA_SKIP_EXTERNAL:-0}"
SKIP_NODES="${SEEDRA_SKIP_NODES:-0}"
INSTALLER_BASE_URL="${SEEDRA_INSTALLER_BASE_URL:-https://raw.githubusercontent.com/fcktisaa/SEEDRAAI-installer/main}"
DRY_RUN=0
PACK="${SEEDRA_PACK:-full}"
SPEED_PROFILE="${SEEDRA_SPEED_PROFILE:-auto}"

usage() {
  cat <<'USAGE'
SEEDRAAI models + custom nodes installer

Usage:
  HF_TOKEN=hf_xxx bash install.sh --pack PACK [options]

Packs:
  full, motion, studio, social, nsfw, cinematic

Options:
  --pack PACK            Model pack to install (default: full)
  --hf-token TOKEN       Hugging Face read token for SEEDRAAI/SEEDRAAI
  --comfy-dir PATH       Path to ComfyUI (auto-detected by default)
  --workers N            Concurrent outer downloads (auto-tuned by default)
  --speed-profile MODE    Download tuning: auto, max, balanced (default: auto)
  --revision REV         SEEDRAAI repository branch/tag/commit (default: main)
  --compat-aliases       Also create old workflow filenames
  --skip-external        Do not download external Wan 2.2 Animate model
  --skip-nodes           Do not install workflow custom nodes
  --force                Replace conflicting destination files
  --dry-run              Show the plan without downloading or changing files
  -h, --help             Show help

Both forms are accepted: --pack motion and --pack=motion.

Environment equivalents:
  HF_TOKEN, COMFY_DIR, SEEDRA_PACK, SEEDRA_WORKERS, SEEDRA_REVISION,
  SEEDRA_COMPAT_ALIASES, SEEDRA_SKIP_EXTERNAL, SEEDRA_SKIP_NODES, SEEDRA_FORCE,
  SEEDRA_SPEED_PROFILE
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pack)
      [[ $# -ge 2 ]] || { echo "Error: --pack requires a value." >&2; exit 2; }
      PACK="$2"; shift 2 ;;
    --pack=*) PACK="${1#*=}"; shift ;;
    --hf-token)
      [[ $# -ge 2 ]] || { echo "Error: --hf-token requires a value." >&2; exit 2; }
      HF_TOKEN="$2"; shift 2 ;;
    --hf-token=*) HF_TOKEN="${1#*=}"; shift ;;
    --comfy-dir)
      [[ $# -ge 2 ]] || { echo "Error: --comfy-dir requires a value." >&2; exit 2; }
      COMFY_DIR="$2"; shift 2 ;;
    --comfy-dir=*) COMFY_DIR="${1#*=}"; shift ;;
    --workers)
      [[ $# -ge 2 ]] || { echo "Error: --workers requires a value." >&2; exit 2; }
      WORKERS="$2"; shift 2 ;;
    --workers=*) WORKERS="${1#*=}"; shift ;;
    --speed-profile)
      [[ $# -ge 2 ]] || { echo "Error: --speed-profile requires a value." >&2; exit 2; }
      SPEED_PROFILE="$2"; shift 2 ;;
    --speed-profile=*) SPEED_PROFILE="${1#*=}"; shift ;;
    --revision)
      [[ $# -ge 2 ]] || { echo "Error: --revision requires a value." >&2; exit 2; }
      REVISION="$2"; shift 2 ;;
    --revision=*) REVISION="${1#*=}"; shift ;;
    --compat-aliases) COMPAT_ALIASES=1; shift ;;
    --skip-external) SKIP_EXTERNAL=1; shift ;;
    --skip-nodes) SKIP_NODES=1; shift ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

PACK="${PACK,,}"
case "$PACK" in
  full|motion|studio|social|nsfw|cinematic) ;;
  *) echo "Error: invalid pack '$PACK'. Use: full, motion, studio, social, nsfw, cinematic." >&2; exit 2 ;;
esac

SPEED_PROFILE="${SPEED_PROFILE,,}"
case "$SPEED_PROFILE" in
  auto|max|balanced) ;;
  *) echo "Error: invalid --speed-profile '$SPEED_PROFILE'. Use: auto, max, balanced." >&2; exit 2 ;;
esac

# Auto-tune Xet for the machine. HF's high-performance mode is intended for
# high-bandwidth hosts with ~64 GiB+ RAM; below that we keep adaptive Xet
# enabled without the large HP buffers.
detect_ram_gib() {
  if [[ -r /proc/meminfo ]]; then
    awk '/MemTotal:/ {printf "%d\n", $2/1024/1024}' /proc/meminfo
  elif command -v sysctl >/dev/null 2>&1; then
    local bytes
    bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
    echo $(( bytes / 1024 / 1024 / 1024 ))
  else
    echo 0
  fi
}

RAM_GIB="$(detect_ram_gib)"
EFFECTIVE_SPEED_PROFILE="$SPEED_PROFILE"
if [[ "$EFFECTIVE_SPEED_PROFILE" == "auto" ]]; then
  if (( RAM_GIB >= 60 )); then
    EFFECTIVE_SPEED_PROFILE="max"
  else
    EFFECTIVE_SPEED_PROFILE="balanced"
  fi
fi

# Xet parallelizes range requests inside each large file. On high-bandwidth
# RunPod/NVMe hosts we also keep several files in flight to fill the pipe.
# All values remain overridable with --workers / SEEDRA_WORKERS.
if [[ -z "$WORKERS" ]]; then
  if [[ "$EFFECTIVE_SPEED_PROFILE" == "max" ]]; then
    WORKERS=16
  else
    WORKERS=8
  fi
fi

if ! [[ "$WORKERS" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: --workers must be a positive integer." >&2
  exit 2
fi

find_comfy() {
  local candidates=(
    "/workspace/ComfyUI"
    "/workspace/madapps/ComfyUI"
    "/root/ComfyUI"
    "/opt/ComfyUI"
    "/ComfyUI"
    "$PWD/ComfyUI"
    "$PWD"
  )
  local d
  for d in "${candidates[@]}"; do
    if [[ -f "$d/main.py" && -d "$d/models" ]]; then
      printf '%s\n' "$d"
      return 0
    fi
  done
  return 1
}

if [[ -z "$COMFY_DIR" ]]; then
  COMFY_DIR="$(find_comfy || true)"
fi

if [[ -z "$COMFY_DIR" || ! -f "$COMFY_DIR/main.py" ]]; then
  echo "Error: ComfyUI was not found." >&2
  echo "Run with: COMFY_DIR=/path/to/ComfyUI HF_TOKEN=... bash install.sh" >&2
  exit 1
fi

COMFY_DIR="$(cd "$COMFY_DIR" && pwd)"
STORE_DIR="${SEEDRA_STORE_DIR:-$COMFY_DIR/.seedraai_repository}"
LOG_DIR="$STORE_DIR/logs"
mkdir -p "$STORE_DIR" "$LOG_DIR"
LOG_FILE="$LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log"

exec > >(tee -a "$LOG_FILE") 2>&1

printf '\n=============================================\n'
printf ' SEEDRAAI installer v%s\n' "$VERSION"
printf ' Repository : %s @ %s\n' "$REPO_ID" "$REVISION"
printf ' Pack       : %s\n' "$PACK"
printf ' ComfyUI    : %s\n' "$COMFY_DIR"
printf ' Store      : %s\n' "$STORE_DIR"
printf ' Workers    : %s\n' "$WORKERS"
printf ' Speed mode : %s (RAM: %s GiB)\n' "$EFFECTIVE_SPEED_PROFILE" "$RAM_GIB"
printf ' Legacy aliases: %s\n' "$COMPAT_ALIASES"
printf ' Custom nodes : %s\n' "$([[ "$SKIP_NODES" == "1" ]] && echo skipped || echo enabled)"
if [[ "$SKIP_EXTERNAL" == "1" || "$PACK" == "social" || "$PACK" == "studio" || "$PACK" == "cinematic" ]]; then
  printf ' External Wan  : skipped\n'
else
  printf ' External Wan  : enabled\n'
fi
printf '=============================================\n\n'

if [[ "$DRY_RUN" != "1" && -z "$HF_TOKEN" ]]; then
  echo "Error: SEEDRAAI/SEEDRAAI is gated and requires HF_TOKEN." >&2
  exit 1
fi

find_comfy_python() {
  if [[ -n "${COMFY_PYTHON:-}" && -x "${COMFY_PYTHON}" ]]; then
    printf '%s\n' "$COMFY_PYTHON"
    return 0
  fi
  local candidates=(
    "$COMFY_DIR/.venv/bin/python"
    "$COMFY_DIR/venv/bin/python"
    "/workspace/venv/bin/python"
    "$COMFY_DIR/python_embeded/python.exe"
    "$COMFY_DIR/python_embeded/python"
  )
  local p
  for p in "${candidates[@]}"; do
    if [[ -x "$p" ]]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  command -v python3 || command -v python || return 1
}

PYTHON_BIN="$(find_comfy_python || true)"
if [[ -z "$PYTHON_BIN" ]]; then
  echo "Error: Python was not found." >&2
  exit 1
fi
printf ' Python     : %s\n' "$PYTHON_BIN"

if [[ "$DRY_RUN" != "1" ]]; then
  if ! "$PYTHON_BIN" -c 'import huggingface_hub, hf_xet' >/dev/null 2>&1; then
    echo "[1/7] Installing Hugging Face downloader..."
    if ! "$PYTHON_BIN" -m pip install -q -U 'huggingface_hub[hf_xet]'; then
      "$PYTHON_BIN" -m pip install -q -U --break-system-packages 'huggingface_hub[hf_xet]'
    fi
  else
    echo "[1/7] Hugging Face downloader is already installed."
  fi
else
  echo "[1/7] Dry run: dependency installation skipped."
fi

export HF_TOKEN
export SEEDRA_REPO_ID="$REPO_ID"
export SEEDRA_PACK="$PACK"
export SEEDRA_REVISION="$REVISION"
export SEEDRA_WORKERS="$WORKERS"
export SEEDRA_COMFY_DIR="$COMFY_DIR"
export SEEDRA_STORE_DIR="$STORE_DIR"
export SEEDRA_FORCE="$FORCE"
export SEEDRA_COMPAT_ALIASES="$COMPAT_ALIASES"
export SEEDRA_SKIP_EXTERNAL="$SKIP_EXTERNAL"
export SEEDRA_SKIP_NODES="$SKIP_NODES"
export SEEDRA_DRY_RUN="$DRY_RUN"
export SEEDRA_EFFECTIVE_SPEED_PROFILE="$EFFECTIVE_SPEED_PROFILE"

# ---------------------------------------------------------------------------
# Fast Hugging Face / Xet profile
# ---------------------------------------------------------------------------
# Keep the chunk cache disabled for one-shot installs. HF explicitly notes this
# is usually faster when downloading new data, especially on fast networks.
export HF_XET_CHUNK_CACHE_SIZE_BYTES="${HF_XET_CHUNK_CACHE_SIZE_BYTES:-0}"
export HF_HUB_DOWNLOAD_TIMEOUT="${HF_HUB_DOWNLOAD_TIMEOUT:-600}"
export HF_HUB_ETAG_TIMEOUT="${HF_HUB_ETAG_TIMEOUT:-60}"
export HF_HOME="${HF_HOME:-$STORE_DIR/.hf_home}"

# Let Xet's adaptive controller handle stream concurrency. For big RunPod-style
# machines, HP mode raises buffers/concurrency and the range-get fanout gives
# each huge safetensors file more parallel S3 work. All values remain overridable
# from the environment if a particular host behaves better with different limits.
export HF_XET_CLIENT_ENABLE_ADAPTIVE_CONCURRENCY="${HF_XET_CLIENT_ENABLE_ADAPTIVE_CONCURRENCY:-1}"
if [[ "$EFFECTIVE_SPEED_PROFILE" == "max" ]]; then
  export HF_XET_HIGH_PERFORMANCE="${HF_XET_HIGH_PERFORMANCE:-1}"
  export HF_XET_NUM_CONCURRENT_RANGE_GETS="${HF_XET_NUM_CONCURRENT_RANGE_GETS:-64}"
  export HF_XET_DATA_MAX_CONCURRENT_FILE_DOWNLOADS="${HF_XET_DATA_MAX_CONCURRENT_FILE_DOWNLOADS:-16}"
  export HF_XET_CLIENT_MAX_IDLE_CONNECTIONS="${HF_XET_CLIENT_MAX_IDLE_CONNECTIONS:-128}"
else
  export HF_XET_HIGH_PERFORMANCE="${HF_XET_HIGH_PERFORMANCE:-0}"
  export HF_XET_NUM_CONCURRENT_RANGE_GETS="${HF_XET_NUM_CONCURRENT_RANGE_GETS:-32}"
  export HF_XET_DATA_MAX_CONCURRENT_FILE_DOWNLOADS="${HF_XET_DATA_MAX_CONCURRENT_FILE_DOWNLOADS:-8}"
  export HF_XET_CLIENT_MAX_IDLE_CONNECTIONS="${HF_XET_CLIENT_MAX_IDLE_CONNECTIONS:-64}"
fi

printf ' Xet HP     : %s\n' "$HF_XET_HIGH_PERFORMANCE"
printf ' Xet ranges : %s/file\n' "$HF_XET_NUM_CONCURRENT_RANGE_GETS"

"$PYTHON_BIN" - <<'PY'
from __future__ import annotations

import json
import os
import shutil
import sys
import time
from pathlib import Path

repo_id = os.environ["SEEDRA_REPO_ID"]
pack = os.environ["SEEDRA_PACK"].lower()
revision = os.environ["SEEDRA_REVISION"]
workers = int(os.environ["SEEDRA_WORKERS"])
comfy = Path(os.environ["SEEDRA_COMFY_DIR"]).resolve()
store = Path(os.environ["SEEDRA_STORE_DIR"]).resolve()
force = os.environ.get("SEEDRA_FORCE", "0") == "1"
compat_aliases = os.environ.get("SEEDRA_COMPAT_ALIASES", "0") == "1"
skip_external = os.environ.get("SEEDRA_SKIP_EXTERNAL", "0") == "1"
dry_run = os.environ.get("SEEDRA_DRY_RUN", "0") == "1"
token = os.environ.get("HF_TOKEN") or None

# Wan 2.2 Animate is required only by full, motion, and NSFW packs.
include_external = (not skip_external) and pack in {"full", "motion", "nsfw"}

# Repository filename -> ComfyUI model folder. The filename is preserved exactly.
ALL_MODEL_FOLDERS: dict[str, str] = {
    "SEEDRA_ArcMotion_HIGH_Base.safetensors": "models/diffusion_models",
    "SEEDRA_ArcMotion_HIGH_V9.safetensors": "models/diffusion_models",
    "SEEDRA_ArcMotion_LOW_Base.safetensors": "models/diffusion_models",
    "SEEDRA_ArcMotion_LOW_V9.safetensors": "models/diffusion_models",
    "SEEDRA_AreolaTrace_Detector_v1.pt": "models/ultralytics/bbox",
    "SEEDRA_BloomScale_4x_SP.pth": "models/upscale_models",
    "SEEDRA_CelestialMotion_Ace.safetensors": "models/loras",
    "SEEDRA_CryoDetail_K7.safetensors": "models/loras",
    "SEEDRA_CrystalNode_D2.safetensors": "models/vae",
    "SEEDRA_DermaFlux_ULTRA_v4.safetensors": "models/diffusion_models",
    "SEEDRA_DetailBloom_LoRA_v1.safetensors": "models/loras",
    "SEEDRA_DetailForge_Crisp.safetensors": "models/loras",
    "SEEDRA_DetailForge_Soft.safetensors": "models/loras",
    "SEEDRA_DetailPulse_ITF_Lite_x1_v1.pth": "models/upscale_models",
    "SEEDRA_FLUX2_Core.safetensors": "models/diffusion_models",
    "SEEDRA_FLUX2_VAE.safetensors": "models/vae",
    "SEEDRA_FLUX_4B_Core.safetensors": "models/diffusion_models",
    "SEEDRA_FourStep_DMD2_SDXL_LoRA_FP16.safetensors": "models/loras",
    "SEEDRA_FrameForge_XGen.safetensors": "models/loras",
    "SEEDRA_HawkVision_W4.onnx": "models/detection",
    "SEEDRA_ImageScaleVAE_2X.safetensors": "models/vae",
    "SEEDRA_IntimateGate_Detector_v2.pt": "models/ultralytics/bbox",
    "SEEDRA_LanguageCore_Atlas_FP8_Mixed.safetensors": "models/text_encoders",
    "SEEDRA_LanguageCore_Aurora_FP8.safetensors": "models/text_encoders",
    "SEEDRA_LanguageCore_Eclipse_FP4_Mixed.safetensors": "models/text_encoders",
    "SEEDRA_LanguageCore_Quartz_Q6_K_XL.gguf": "models/text_encoders",
    "SEEDRA_LanguageCore_Qwen3.safetensors": "models/text_encoders",
    "SEEDRA_LanguageCore_Qwen4B_ZImage_Heretic_Q8.gguf": "models/text_encoders",
    "SEEDRA_LanguageCore_Qwen_Main.safetensors": "models/text_encoders",
    "SEEDRA_LipTrace_Detector_v1.pt": "models/ultralytics/bbox",
    "SEEDRA_MotionForge_Core_MXFP8.safetensors": "models/diffusion_models",
    "SEEDRA_MotionForge_Q4_K_S.gguf": "models/diffusion_models",
    "SEEDRA_MotionScale_1_5X_v1_0.safetensors": "models/latent_upscale_models",
    "SEEDRA_MotionScale_2X_v1_1.safetensors": "models/latent_upscale_models",
    "SEEDRA_MotionVAE_Comfy_BF16.safetensors": "models/vae",
    "SEEDRA_MotionVAE_Main.safetensors": "models/vae",
    "SEEDRA_MotionVAE_Prime_BF16.safetensors": "models/vae",
    "SEEDRA_Nightfall_SDXL.safetensors": "models/checkpoints",
    "SEEDRA_Nocturne_T9.safetensors": "models/text_encoders",
    "SEEDRA_NovaMind_X1.safetensors": "models/loras",
    "SEEDRA_ObsidianCore_FP8.safetensors": "models/diffusion_models",
    "SEEDRA_OpticTrace_V7.safetensors": "models/clip_vision",
    "SEEDRA_OriginScale_Upscaler.pth": "models/upscale_models",
    "SEEDRA_PhantomWeave_R5.safetensors": "models/loras",
    "SEEDRA_PoreDetail_FLUX_LoRA.safetensors": "models/loras",
    "SEEDRA_PreviewVAE_Lite.safetensors": "models/vae",
    "SEEDRA_Primary_VAE.safetensors": "models/vae",
    "SEEDRA_PrimeNet_v2.safetensors": "models/loras",
    "SEEDRA_PrismScale_4x.pth": "models/upscale_models",
    "SEEDRA_PromptLens_CLIP-L.safetensors": "models/text_encoders",
    "SEEDRA_QuantumScale_2x.pth": "models/upscale_models",
    "SEEDRA_RawFrame_R16.safetensors": "models/loras",
    "SEEDRA_RazorScale_4x_v2.pth": "models/upscale_models",
    "SEEDRA_SegmentCore_SAM3.pt": "models/sam3",
    "SEEDRA_SkinPulse_ZTurbo.safetensors": "models/diffusion_models",
    "SEEDRA_SolarFlare_L2.safetensors": "models/loras",
    "SEEDRA_SonicSplit_FP16.safetensors": "models/diffusion_models",
    "SEEDRA_SonicVAE_Main.safetensors": "models/vae",
    "SEEDRA_SonicVAE_Prime_BF16.safetensors": "models/vae",
    "SEEDRA_TextBridge_BF16.safetensors": "models/text_encoders",
    "SEEDRA_TextBridge_Prime_BF16.safetensors": "models/text_encoders",
    "SEEDRA_TextCore_UMT5_Main.safetensors": "models/text_encoders",
    "SEEDRA_TextCore_UMT5_XXL_FP8_Scaled.safetensors": "models/text_encoders",
    "SEEDRA_TitanCore_FP8.safetensors": "models/text_encoders",
    "SEEDRA_VelvetCore_Turbo_FP8.safetensors": "models/diffusion_models",
    "SEEDRA_VisionCore_Nova_FP8.safetensors": "models/text_encoders",
    "SEEDRA_VectorAxis_B6.onnx": "models/detection",
    "SEEDRA_VectorAxis_B7.bin": "models/detection",
    "SEEDRA_VelvetMuse_Luxe.safetensors": "models/loras",
    "SEEDRA_VelvetQuant_Q4.safetensors": "models/loras",
    "SEEDRA_ZImage_Core.safetensors": "models/diffusion_models",
    # Intentionally NOT renamed: workflows expect this exact filename.
    "qwen_image_vae.safetensors": "models/vae",
}

PACK_MODELS: dict[str, set[str]] = {
    "motion": {
        "SEEDRA_ArcMotion_HIGH_Base.safetensors",
        "SEEDRA_ArcMotion_LOW_Base.safetensors",
        "SEEDRA_CryoDetail_K7.safetensors",
        "SEEDRA_CrystalNode_D2.safetensors",
        "SEEDRA_DermaFlux_ULTRA_v4.safetensors",
        "SEEDRA_HawkVision_W4.onnx",
        "SEEDRA_LanguageCore_Qwen_Main.safetensors",
        "SEEDRA_Nocturne_T9.safetensors",
        "SEEDRA_NovaMind_X1.safetensors",
        "SEEDRA_OpticTrace_V7.safetensors",
        "SEEDRA_PhantomWeave_R5.safetensors",
        "SEEDRA_PoreDetail_FLUX_LoRA.safetensors",
        "SEEDRA_Primary_VAE.safetensors",
        "SEEDRA_PrismScale_4x.pth",
        "SEEDRA_PromptLens_CLIP-L.safetensors",
        "SEEDRA_QuantumScale_2x.pth",
        "SEEDRA_SkinPulse_ZTurbo.safetensors",
        "SEEDRA_SolarFlare_L2.safetensors",
        "SEEDRA_TextCore_UMT5_Main.safetensors",
        "SEEDRA_TextCore_UMT5_XXL_FP8_Scaled.safetensors",
        "SEEDRA_TitanCore_FP8.safetensors",
        "SEEDRA_VectorAxis_B6.onnx",
        "SEEDRA_VectorAxis_B7.bin",
        "SEEDRA_VelvetQuant_Q4.safetensors",
    },
    "studio": {
        "SEEDRA_CryoDetail_K7.safetensors",
        "SEEDRA_CrystalNode_D2.safetensors",
        "SEEDRA_DermaFlux_ULTRA_v4.safetensors",
        "SEEDRA_FLUX2_Core.safetensors",
        "SEEDRA_FLUX2_VAE.safetensors",
        "SEEDRA_FrameForge_XGen.safetensors",
        "SEEDRA_HawkVision_W4.onnx",
        "SEEDRA_LanguageCore_Qwen3.safetensors",
        "SEEDRA_LanguageCore_Qwen4B_ZImage_Heretic_Q8.gguf",
        "SEEDRA_LanguageCore_Qwen_Main.safetensors",
        "SEEDRA_Nocturne_T9.safetensors",
        "SEEDRA_NovaMind_X1.safetensors",
        "SEEDRA_OpticTrace_V7.safetensors",
        "SEEDRA_OriginScale_Upscaler.pth",
        "SEEDRA_PhantomWeave_R5.safetensors",
        "SEEDRA_PoreDetail_FLUX_LoRA.safetensors",
        "SEEDRA_Primary_VAE.safetensors",
        "SEEDRA_PrimeNet_v2.safetensors",
        "SEEDRA_PrismScale_4x.pth",
        "SEEDRA_PromptLens_CLIP-L.safetensors",
        "SEEDRA_SegmentCore_SAM3.pt",
        "SEEDRA_SkinPulse_ZTurbo.safetensors",
        "SEEDRA_SolarFlare_L2.safetensors",
        "SEEDRA_TitanCore_FP8.safetensors",
        "SEEDRA_VelvetCore_Turbo_FP8.safetensors",
        "SEEDRA_VisionCore_Nova_FP8.safetensors",
        "SEEDRA_VectorAxis_B6.onnx",
        "SEEDRA_VectorAxis_B7.bin",
        "SEEDRA_VelvetQuant_Q4.safetensors",
        "SEEDRA_ZImage_Core.safetensors",
        "qwen_image_vae.safetensors",
    },
    "social": {
        "SEEDRA_FLUX2_Core.safetensors",
        "SEEDRA_FLUX2_VAE.safetensors",
        "SEEDRA_FLUX_4B_Core.safetensors",
        "SEEDRA_LanguageCore_Qwen3.safetensors",
        "SEEDRA_LanguageCore_Qwen_Main.safetensors",
    },
    "nsfw": {
        "SEEDRA_ArcMotion_HIGH_Base.safetensors",
        "SEEDRA_ArcMotion_LOW_Base.safetensors",
        "SEEDRA_AreolaTrace_Detector_v1.pt",
        "SEEDRA_BloomScale_4x_SP.pth",
        "SEEDRA_CryoDetail_K7.safetensors",
        "SEEDRA_CrystalNode_D2.safetensors",
        "SEEDRA_DetailBloom_LoRA_v1.safetensors",
        "SEEDRA_DetailPulse_ITF_Lite_x1_v1.pth",
        "SEEDRA_FourStep_DMD2_SDXL_LoRA_FP16.safetensors",
        "SEEDRA_HawkVision_W4.onnx",
        "SEEDRA_IntimateGate_Detector_v2.pt",
        "SEEDRA_LanguageCore_Qwen_Main.safetensors",
        "SEEDRA_LipTrace_Detector_v1.pt",
        "SEEDRA_Nightfall_SDXL.safetensors",
        "SEEDRA_Nocturne_T9.safetensors",
        "SEEDRA_NovaMind_X1.safetensors",
        "SEEDRA_OpticTrace_V7.safetensors",
        "SEEDRA_PhantomWeave_R5.safetensors",
        "SEEDRA_QuantumScale_2x.pth",
        "SEEDRA_RazorScale_4x_v2.pth",
        "SEEDRA_SolarFlare_L2.safetensors",
        "SEEDRA_TextCore_UMT5_Main.safetensors",
        "SEEDRA_TextCore_UMT5_XXL_FP8_Scaled.safetensors",
        "SEEDRA_VectorAxis_B6.onnx",
        "SEEDRA_VectorAxis_B7.bin",
        "SEEDRA_VelvetQuant_Q4.safetensors",
        "SEEDRA_ZImage_Core.safetensors",
    },
    "cinematic": {
        "SEEDRA_CelestialMotion_Ace.safetensors",
        "SEEDRA_DetailForge_Crisp.safetensors",
        "SEEDRA_DetailForge_Soft.safetensors",
        "SEEDRA_LanguageCore_Eclipse_FP4_Mixed.safetensors",
        "SEEDRA_MotionForge_Core_MXFP8.safetensors",
        "SEEDRA_MotionForge_Q4_K_S.gguf",
        "SEEDRA_MotionScale_1_5X_v1_0.safetensors",
        "SEEDRA_MotionScale_2X_v1_1.safetensors",
        "SEEDRA_MotionVAE_Comfy_BF16.safetensors",
        "SEEDRA_MotionVAE_Main.safetensors",
        "SEEDRA_MotionVAE_Prime_BF16.safetensors",
        "SEEDRA_PreviewVAE_Lite.safetensors",
        "SEEDRA_RawFrame_R16.safetensors",
        "SEEDRA_SonicSplit_FP16.safetensors",
        "SEEDRA_SonicVAE_Main.safetensors",
        "SEEDRA_SonicVAE_Prime_BF16.safetensors",
        "SEEDRA_TextBridge_BF16.safetensors",
        "SEEDRA_TextBridge_Prime_BF16.safetensors",
        "SEEDRA_VelvetMuse_Luxe.safetensors",
    },
}

if len(ALL_MODEL_FOLDERS) != 72:
    raise RuntimeError(
        f"Internal manifest error: expected 72 files, got {len(ALL_MODEL_FOLDERS)}"
    )
selected_names = set(ALL_MODEL_FOLDERS) if pack == "full" else PACK_MODELS[pack]
unknown = selected_names.difference(ALL_MODEL_FOLDERS)
if unknown:
    raise RuntimeError(f"Internal pack manifest contains unknown files: {sorted(unknown)}")
MODEL_FOLDERS = {name: ALL_MODEL_FOLDERS[name] for name in sorted(selected_names)}

# Additional models referenced by the supplied workflows that intentionally keep their original names.
# Each entry: candidate repo filenames (first existing wins), final ComfyUI path.
# They are auto-included for --pack full when present in the SEEDRAAI repository.
WORKFLOW_EXTRA_CANDIDATES: list[tuple[list[str], str]] = [
    (["ae.safetensors"], "models/vae/ae.safetensors"),
    (["krea2_identity_edit_v1_2.safetensors"], "models/loras/krea2_identity_edit_v1_2.safetensors"),
    (["ltx-2.3-22b-dev-fp8.safetensors"], "models/checkpoints/ltx-2.3-22b-dev-fp8.safetensors"),
    (["ltx-2.3-22b-distilled-1.1-Q4_K_M.gguf"], "models/diffusion_models/ltx-2.3-22b-distilled-1.1-Q4_K_M.gguf"),
    (["ltx-2.3-id-lora-talkvid-3k.safetensors"], "models/loras/ltx-2.3-id-lora-talkvid-3k.safetensors"),
    (["qwen_3_4b.safetensors"], "models/text_encoders/qwen_3_4b.safetensors"),
    (["z_image_turbo_bf16.safetensors"], "models/diffusion_models/z_image_turbo_bf16.safetensors"),
    (["zimage_margotrobbie_v1.safetensors"], "models/loras/zimage_margotrobbie_v1.safetensors"),
    (["sam_vit_b_01ec64.pth"], "models/sams/sam_vit_b_01ec64.pth"),
    (["face_yolov8m.pt", "bbox/face_yolov8m.pt"], "models/ultralytics/bbox/face_yolov8m.pt"),
    (["hand_yolov8s.pt", "bbox/hand_yolov8s.pt"], "models/ultralytics/bbox/hand_yolov8s.pt"),
    (["Eyeful_v2-Paired.pt", "bbox/Eyeful_v2-Paired.pt"], "models/ultralytics/bbox/Eyeful_v2-Paired.pt"),
    (["controlnet-union-sdxl-promax.safetensors"], "models/controlnet/controlnet-union-sdxl-promax.safetensors"),
    (["seedvr2_ema_3b_fp8_e4m3fn.safetensors"], "models/SEEDVR2/seedvr2_ema_3b_fp8_e4m3fn.safetensors"),
    (["seedvr2_ema_7b-Q4_K_M.gguf"], "models/SEEDVR2/seedvr2_ema_7b-Q4_K_M.gguf"),
    (["ema_vae_fp16.safetensors"], "models/SEEDVR2/ema_vae_fp16.safetensors"),
    (["rife49.pth"], "models/frame_interpolation/rife49.pth"),
    (["ltx-2.3-22b-distilled-1.1_lora-dynamic_fro09_avg_rank_111_bf16.safetensors"], "models/loras/ltx-2.3-22b-distilled-1.1_lora-dynamic_fro09_avg_rank_111_bf16.safetensors"),
    (["64/SVI_v2_PRO_Wan2.2-I2V-A14B_HIGH_lora_rank_128_fp16.safetensors", "SVI_v2_PRO_Wan2.2-I2V-A14B_HIGH_lora_rank_128_fp16.safetensors"], "models/loras/64/SVI_v2_PRO_Wan2.2-I2V-A14B_HIGH_lora_rank_128_fp16.safetensors"),
]

# Old names used by the supplied legacy workflows. Disabled by default.
LEGACY_ALIASES: dict[str, str] = {
    "SEEDRA_ArcMotion_HIGH_Base.safetensors": "models/diffusion_models/High.safetensors",
    "SEEDRA_ArcMotion_HIGH_V9.safetensors": "models/diffusion_models/HighV9.safetensors",
    "SEEDRA_ArcMotion_LOW_Base.safetensors": "models/diffusion_models/Low.safetensors",
    "SEEDRA_ArcMotion_LOW_V9.safetensors": "models/diffusion_models/LowV9.safetensors",
    "SEEDRA_AreolaTrace_Detector_v1.pt": "models/ultralytics/bbox/nipple.pt",
    "SEEDRA_BloomScale_4x_SP.pth": "models/upscale_models/4x_NMKD-Superscale-SP_178000_G.pth",
    "SEEDRA_CelestialMotion_Ace.safetensors": "models/loras/LTX23-GalaxyAce.safetensors",
    "SEEDRA_CryoDetail_K7.safetensors": "models/loras/FrostByte_K7.safetensors",
    "SEEDRA_CrystalNode_D2.safetensors": "models/vae/GlassRoot_D2.safetensors",
    "SEEDRA_DermaFlux_ULTRA_v4.safetensors": "models/diffusion_models/HyperFleshUltrav4.safetensors",
    "SEEDRA_DetailBloom_LoRA_v1.safetensors": "models/loras/DetailedNipples.safetensors",
    "SEEDRA_DetailForge_Crisp.safetensors": "models/loras/LTX2.3_Crisp_Enhance.safetensors",
    "SEEDRA_DetailForge_Soft.safetensors": "models/loras/LTX2.3_Soft_Enhance.safetensors",
    "SEEDRA_DetailPulse_ITF_Lite_x1_v1.pth": "models/upscale_models/x1_ITF_SkinDiffDetail_Lite_v1.pth",
    "SEEDRA_FLUX2_Core.safetensors": "models/diffusion_models/flux-2.safetensors",
    "SEEDRA_FLUX2_VAE.safetensors": "models/vae/flux2-vae.safetensors",
    "SEEDRA_FLUX_4B_Core.safetensors": "models/diffusion_models/flux4b.safetensors",
    "SEEDRA_FourStep_DMD2_SDXL_LoRA_FP16.safetensors": "models/loras/dmd2_sdxl_4step_lora_fp16.safetensors",
    "SEEDRA_FrameForge_XGen.safetensors": "models/loras/x_gen_weights.safetensors",
    "SEEDRA_HawkVision_W4.onnx": "models/detection/yolov10m.onnx",
    "SEEDRA_ImageScaleVAE_2X.safetensors": "models/vae/Wan2.1_VAE_upscale2x_imageonly_real_v1.safetensors",
    "SEEDRA_IntimateGate_Detector_v2.pt": "models/ultralytics/bbox/pussyV2.pt",
    "SEEDRA_LanguageCore_Atlas_FP8_Mixed.safetensors": "models/text_encoders/qwen_3_8b_fp8mixed.safetensors",
    "SEEDRA_LanguageCore_Aurora_FP8.safetensors": "models/text_encoders/gemma4_4b_it_fp8_scaled.safetensors",
    "SEEDRA_LanguageCore_Eclipse_FP4_Mixed.safetensors": "models/text_encoders/gemma_3_12B_it_fp4_mixed.safetensors",
    "SEEDRA_LanguageCore_Quartz_Q6_K_XL.gguf": "models/text_encoders/gemma-3-12b-it-UD-Q6_K_XL.gguf",
    "SEEDRA_LanguageCore_Qwen3.safetensors": "models/text_encoders/qwen3.safetensors",
    "SEEDRA_LanguageCore_Qwen4B_ZImage_Heretic_Q8.gguf": "models/text_encoders/qwen-4b-zimage-heretic-q8.gguf",
    "SEEDRA_LanguageCore_Qwen_Main.safetensors": "models/text_encoders/qwen.safetensors",
    "SEEDRA_LipTrace_Detector_v1.pt": "models/ultralytics/bbox/lips_v1.pt",
    "SEEDRA_MotionForge_Core_MXFP8.safetensors": "models/diffusion_models/ltx-2.3-22b-distilled-1.1_transformer_only_mxfp8_block32.safetensors",
    "SEEDRA_MotionForge_Q4_K_S.gguf": "models/diffusion_models/ltx-2.3-22b-dev-Q4_K_S.gguf",
    "SEEDRA_MotionScale_1_5X_v1_0.safetensors": "models/latent_upscale_models/ltx-2.3-spatial-upscaler-x1.5-1.0.safetensors",
    "SEEDRA_MotionScale_2X_v1_1.safetensors": "models/latent_upscale_models/ltx-2.3-spatial-upscaler-x2-1.1.safetensors",
    "SEEDRA_MotionVAE_Comfy_BF16.safetensors": "models/vae/pruna_ltx23_vae_comfy_bf16.safetensors",
    "SEEDRA_MotionVAE_Main.safetensors": "models/vae/ltx-2.3-22b-dev_video_vae.safetensors",
    "SEEDRA_MotionVAE_Prime_BF16.safetensors": "models/vae/LTX23_video_vae_bf16.safetensors",
    "SEEDRA_Nightfall_SDXL.safetensors": "models/checkpoints/SDXLNSFW.safetensors",
    "SEEDRA_Nocturne_T9.safetensors": "models/text_encoders/EchoVault_T9.safetensors",
    "SEEDRA_NovaMind_X1.safetensors": "models/loras/NovaMind_X1.safetensors",
    "SEEDRA_ObsidianCore_FP8.safetensors": "models/diffusion_models/flux-2-klein-9b-fp8.safetensors",
    "SEEDRA_OpticTrace_V7.safetensors": "models/clip_vision/IronSight_V7.safetensors",
    "SEEDRA_OriginScale_Upscaler.pth": "models/upscale_models/upscale1.pth",
    "SEEDRA_PhantomWeave_R5.safetensors": "models/loras/PhantomWeave_R5.safetensors",
    "SEEDRA_PoreDetail_FLUX_LoRA.safetensors": "models/loras/VelvetPores_Flux.safetensors",
    "SEEDRA_PreviewVAE_Lite.safetensors": "models/vae/taeltx2_3.safetensors",
    "SEEDRA_Primary_VAE.safetensors": "models/vae/variational_encoder_primary.safetensors",
    "SEEDRA_PrimeNet_v2.safetensors": "models/loras/primary_net_v2.safetensors",
    "SEEDRA_PrismScale_4x.pth": "models/upscale_models/RealityGlass4x.pth",
    "SEEDRA_PromptLens_CLIP-L.safetensors": "models/text_encoders/clip_l.safetensors",
    "SEEDRA_QuantumScale_2x.pth": "models/upscale_models/RealESRGAN_x2.pth",
    "SEEDRA_RawFrame_R16.safetensors": "models/loras/AmateurHour_01_rank16.safetensors",
    "SEEDRA_RazorScale_4x_v2.pth": "models/upscale_models/4x-UltraSharpV2.pth",
    "SEEDRA_SegmentCore_SAM3.pt": "models/sam3/sam3.pt",
    "SEEDRA_SkinPulse_ZTurbo.safetensors": "models/diffusion_models/Z-TurboSkinForge.safetensors",
    "SEEDRA_SolarFlare_L2.safetensors": "models/loras/SolarFlint_L2.safetensors",
    "SEEDRA_SonicSplit_FP16.safetensors": "models/diffusion_models/MelBandRoformer_fp16.safetensors",
    "SEEDRA_SonicVAE_Main.safetensors": "models/vae/ltx-2.3-22b-dev_audio_vae.safetensors",
    "SEEDRA_SonicVAE_Prime_BF16.safetensors": "models/vae/LTX23_audio_vae_bf16.safetensors",
    "SEEDRA_TextBridge_BF16.safetensors": "models/text_encoders/ltx-23_text_projection_bf16.safetensors",
    "SEEDRA_TextBridge_Prime_BF16.safetensors": "models/text_encoders/ltx-2.3_text_projection_bf16.safetensors",
    "SEEDRA_TextCore_UMT5_Main.safetensors": "models/text_encoders/umt5.safetensors",
    "SEEDRA_TextCore_UMT5_XXL_FP8_Scaled.safetensors": "models/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors",
    "SEEDRA_TitanCore_FP8.safetensors": "models/text_encoders/TitanFP8.safetensors",
    "SEEDRA_VectorAxis_B6.onnx": "models/detection/vitpose_h_wholebody_model.onnx",
    "SEEDRA_VectorAxis_B7.bin": "models/detection/vitpose_h_wholebody_data.bin",
    "SEEDRA_VelvetMuse_Luxe.safetensors": "models/loras/Luxe_Sensual.safetensors",
    "SEEDRA_VelvetCore_Turbo_FP8.safetensors": "models/diffusion_models/krea2_turbo_fp8.safetensors",
    "SEEDRA_VisionCore_Nova_FP8.safetensors": "models/text_encoders/qwen3vl_4b_fp8_scaled.safetensors",
    "SEEDRA_VelvetQuant_Q4.safetensors": "models/loras/VelvetRush_Q4.safetensors",
    "SEEDRA_ZImage_Core.safetensors": "models/diffusion_models/zimage.safetensors",
}

# These aliases are retained because some custom nodes expect fixed filenames internally.
REQUIRED_ALIASES: dict[str, str] = {
    "SEEDRA_HawkVision_W4.onnx": "models/detection/yolov10m.onnx",
    "SEEDRA_ImageScaleVAE_2X.safetensors": "models/vae/Wan2.1_VAE_upscale2x_imageonly_real_v1.safetensors",
    "SEEDRA_VectorAxis_B6.onnx": "models/detection/vitpose_h_wholebody_model.onnx",
    "SEEDRA_VectorAxis_B7.bin": "models/detection/vitpose_h_wholebody_data.bin",
    "SEEDRA_SegmentCore_SAM3.pt": "models/sam3/sam3.pt",
}

EXTERNAL = {
    "repo_id": "Comfy-Org/Wan_2.2_ComfyUI_Repackaged",
    "revision": "main",
    "filename": "split_files/diffusion_models/wan2.2_animate_14B_bf16.safetensors",
    "destination": "models/diffusion_models/wan2.2_animate_14B_bf16.safetensors",
}

canonical_destinations = {
    name: str(Path(folder) / name) for name, folder in MODEL_FOLDERS.items()
}

print(f"[2/7] Pack: {pack} | Manifest: {len(MODEL_FOLDERS)} SEEDRAAI files")
for source, destination in canonical_destinations.items():
    print(f"  {source} -> {destination}")
if include_external:
    print(f"  + external: {EXTERNAL['filename']} -> {EXTERNAL['destination']}")
if compat_aliases:
    print(f"  + {len(LEGACY_ALIASES)} legacy aliases")

if dry_run:
    print("\nDry run complete. Nothing was downloaded or changed.")
    raise SystemExit(0)

from huggingface_hub import HfApi, hf_hub_download, snapshot_download

api = HfApi()

def repo_sizes(target_repo: str, target_revision: str, target_token: str | None) -> dict[str, int]:
    info = api.model_info(
        target_repo,
        revision=target_revision,
        token=target_token,
        files_metadata=True,
    )
    result: dict[str, int] = {}
    for sibling in info.siblings or []:
        name = getattr(sibling, "rfilename", None)
        size = getattr(sibling, "size", None)
        if name and isinstance(size, int):
            result[name] = size
    return result

try:
    main_sizes = repo_sizes(repo_id, revision, token)
except Exception as exc:
    print(f"ERROR: cannot access {repo_id}: {exc}", file=sys.stderr)
    raise SystemExit(1)

# Resolve original-name workflow assets from the user's repo without making them
# hard requirements for smaller packs. --pack full picks up every one that exists.
resolved_extras: dict[str, str] = {}
if pack == "full":
    for candidates, destination in WORKFLOW_EXTRA_CANDIDATES:
        source = next((candidate for candidate in candidates if candidate in main_sizes), None)
        if source:
            resolved_extras[source] = destination
        else:
            print(f"  INFO workflow extra not in repo (node may auto-download): {candidates[0]}")

missing_remote = [name for name in MODEL_FOLDERS if name not in main_sizes]
if missing_remote:
    print("ERROR: required files are missing from the SEEDRAAI repository:", file=sys.stderr)
    for name in missing_remote:
        print(f"  - {name}", file=sys.stderr)
    print("Upload/copy the missing canonical SEEDRA_* files to the repository, then rerun the installer.", file=sys.stderr)
    raise SystemExit(1)

external_size = 0
if include_external:
    try:
        ext_sizes = repo_sizes(EXTERNAL["repo_id"], EXTERNAL["revision"], None)
        external_size = ext_sizes[EXTERNAL["filename"]]
    except Exception as exc:
        print(f"ERROR: cannot inspect external Wan model: {exc}", file=sys.stderr)
        raise SystemExit(1)

store.mkdir(parents=True, exist_ok=True)
remaining = 0
download_sources = set(MODEL_FOLDERS) | set(resolved_extras)
for name in download_sources:
    local = store / name
    expected = main_sizes[name]
    actual = local.stat().st_size if local.exists() else 0
    if actual != expected:
        remaining += expected

external_store = store / "external" / "Comfy-Org__Wan_2.2_ComfyUI_Repackaged"
external_local = external_store / EXTERNAL["filename"]
if include_external:
    actual = external_local.stat().st_size if external_local.exists() else 0
    if actual != external_size:
        remaining += external_size

free = shutil.disk_usage(comfy).free
reserve = 5 * 1024**3
print(f"  Remaining download: {remaining / 1024**3:.1f} GiB")
print(f"  Free disk space   : {free / 1024**3:.1f} GiB")
if free < remaining + reserve:
    need = (remaining + reserve - free) / 1024**3
    print(f"ERROR: insufficient disk space. Add at least {need:.1f} GiB.", file=sys.stderr)
    raise SystemExit(1)

print("[3/7] Downloading SEEDRAAI files...")
snapshot_download(
    repo_id=repo_id,
    revision=revision,
    repo_type="model",
    local_dir=str(store),
    allow_patterns=sorted(download_sources),
    token=token,
    max_workers=workers,
)

if include_external:
    print("[4/7] Downloading Wan 2.2 Animate 14B...")
    external_store.mkdir(parents=True, exist_ok=True)
    downloaded = Path(
        hf_hub_download(
            repo_id=EXTERNAL["repo_id"],
            revision=EXTERNAL["revision"],
            repo_type="model",
            filename=EXTERNAL["filename"],
            local_dir=str(external_store),
            token=None,
        )
    )
    if downloaded.stat().st_size != external_size:
        raise RuntimeError("Wrong size for external Wan 2.2 Animate model")
else:
    print("[4/7] External Wan model skipped.")

for name in download_sources:
    expected = main_sizes[name]
    path = store / name
    if not path.is_file() or path.stat().st_size != expected:
        raise RuntimeError(f"Invalid downloaded file: {path}")

print("[5/7] Creating ComfyUI model links...")
created = skipped = replaced = removed_legacy = 0
link_modes: dict[str, int] = {"hardlink": 0, "symlink": 0}


def remove_existing_link(destination: Path, source: Path) -> bool:
    if not os.path.lexists(destination):
        return False
    try:
        if os.path.samefile(source, destination):
            destination.unlink()
            return True
    except OSError:
        return False
    return False


def link_file(source: Path, destination: Path, label: str) -> None:
    global created, skipped, replaced
    destination.parent.mkdir(parents=True, exist_ok=True)

    if os.path.lexists(destination):
        try:
            if os.path.samefile(source, destination):
                print(f"  OK   {label}")
                skipped += 1
                return
        except OSError:
            pass

        if destination.is_file() and not destination.is_symlink():
            if destination.stat().st_size == source.stat().st_size:
                print(f"  KEEP {label} (existing same-size file)")
                skipped += 1
                return

        if not force:
            raise RuntimeError(
                f"Destination already exists and conflicts: {destination}\n"
                "Rerun with --force only if it is safe to replace it."
            )

        backup = destination.with_name(destination.name + f".bak.{int(time.time())}")
        destination.rename(backup)
        print(f"  BAK  {label} -> {backup.name}")
        replaced += 1

    try:
        os.link(source, destination)
        mode = "hardlink"
    except OSError:
        relative_source = os.path.relpath(source, destination.parent)
        os.symlink(relative_source, destination)
        mode = "symlink"

    print(f"  LINK {label} [{mode}]")
    link_modes[mode] += 1
    created += 1


# Remove v1.0 legacy links when compatibility mode is disabled.
if not compat_aliases:
    for source_name, relative_alias in LEGACY_ALIASES.items():
        if relative_alias in REQUIRED_ALIASES.values():
            continue
        source = store / source_name
        alias = comfy / relative_alias
        if remove_existing_link(alias, source):
            print(f"  DEL  {relative_alias} [old alias]")
            removed_legacy += 1

# Canonical links use the exact filenames from the Hugging Face repository.
for source_name, relative_destination in canonical_destinations.items():
    link_file(store / source_name, comfy / relative_destination, relative_destination)

# Original-name assets used by the supplied workflows.
for source_name, relative_destination in sorted(resolved_extras.items()):
    link_file(store / source_name, comfy / relative_destination, relative_destination)

# Fixed aliases required by some custom nodes.
for source_name, relative_alias in REQUIRED_ALIASES.items():
    if source_name in MODEL_FOLDERS:
        link_file(store / source_name, comfy / relative_alias, relative_alias)

# Optional aliases for old workflow JSON files.
if compat_aliases:
    for source_name, relative_alias in LEGACY_ALIASES.items():
        if source_name in MODEL_FOLDERS:
            link_file(store / source_name, comfy / relative_alias, relative_alias)

if include_external:
    link_file(external_local, comfy / EXTERNAL["destination"], EXTERNAL["destination"])

manifest = {
    "installer_version": "9.0.0",
    "pack": pack,
    "repository": repo_id,
    "revision": revision,
    "installed_at_unix": int(time.time()),
    "comfy_dir": str(comfy),
    "store_dir": str(store),
    "canonical_destinations": canonical_destinations,
    "workflow_extra_destinations": resolved_extras,
    "required_aliases": REQUIRED_ALIASES,
    "legacy_aliases_enabled": compat_aliases,
    "external_wan_enabled": include_external,
    "external": EXTERNAL if include_external else None,
}
(store / "seedra-install-manifest.json").write_text(
    json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8"
)

print("\n=============================================")
print(" Installation completed")
print(f" Created       : {created}")
print(f" Existing      : {skipped}")
print(f" Replaced      : {replaced}")
print(f" Old aliases removed: {removed_legacy}")
print(f" Hardlinks: {link_modes['hardlink']} | Symlinks: {link_modes['symlink']}")
print(" Restart ComfyUI or press R to refresh models.")
print("=============================================")
PY


# ---------------------------------------------------------------------------
# Workflow custom nodes
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" == "1" ]]; then
  echo "[6/7] Dry run: custom-node installation skipped."
elif [[ "$SKIP_NODES" == "1" ]]; then
  echo "[6/7] Custom-node installation skipped (--skip-nodes)."
else
  echo "[6/7] Installing custom nodes required by the supplied workflow pack..."

  if ! command -v git >/dev/null 2>&1; then
    echo "ERROR: git is required to install ComfyUI custom nodes." >&2
    exit 1
  fi
  mkdir -p "$COMFY_DIR/custom_nodes"

  pip_install() {
    if ! "$PYTHON_BIN" -m pip install -q "$@"; then
      "$PYTHON_BIN" -m pip install -q --break-system-packages "$@"
    fi
  }

  # comfy-cli must be installed into the same Python environment as ComfyUI.
  if ! "$PYTHON_BIN" -c 'import comfy_cli' >/dev/null 2>&1; then
    echo "  Installing/updating comfy-cli in ComfyUI Python..."
    pip_install -U comfy-cli
  fi
  COMFY_CMD=""
  SCRIPTS_DIR="$($PYTHON_BIN - <<'PYCLI'
import sysconfig
print(sysconfig.get_path('scripts'))
PYCLI
)"
  [[ -x "$SCRIPTS_DIR/comfy" ]] && COMFY_CMD="$SCRIPTS_DIR/comfy"
  [[ -z "$COMFY_CMD" ]] && COMFY_CMD="$(command -v comfy || true)"
  if [[ -z "$COMFY_CMD" ]]; then
    echo "ERROR: comfy-cli is installed but the comfy executable was not found." >&2
    exit 1
  fi
  "$COMFY_CMD" tracking disable >/dev/null 2>&1 || true

  # Current Comfy Registry installs use `node registry-install`. The old v8
  # installer used `node install`, which can resolve packages as @unknown.
  # IDs below were audited from every supplied JSON workflow; core nodes omitted.
  NODE_IDS=(
    "cg-use-everywhere"
    "comfyliterals"
    "comfyui-aspect-ratio-crop-node"
    "comfyui_fearnworksnodes"
    "masquerade"
    "ComfyMath"
    "comfyui-custom-scripts"
    "comfyui-detail-daemon"
    "comfyui-easy-use"
    "comfyui-frame-interpolation"
    "ComfyUI-GGUF"
    "ComfyUI-MelBandRoFormer"
    "comfyui-impact-pack"
    "comfyui-impact-subpack"
    "comfyui-inpaint-cropandstitch"
    "comfyui-kjnodes"
    "comfyui-krea2edit"
    "comfyui-mxtoolkit"
    "comfyui-propost"
    "comfyui-rmbg"
    "comfyui-sam3"
    "comfyui-unload-model"
    "ComfyUI-segment-anything-2"
    "comfyui-videohelpersuite"
    "comfyui-wananimatepreprocess"
    "ComfyUI-WanVideoWrapper"
    "comfyui-workflow-encrypt"
    "ComfyUI_Comfyroll_CustomNodes"
    "comfyui_controlnet_aux"
    "comfyui_essentials"
    "comfyui_ipadapter_plus"
    "ComfyUI_JPS-Nodes"
    "comfyui_ultimatesdupscale"
    "crt-nodes"
    "efficiency-nodes-comfyui"
    "image-size-tools"
    "lanpaint"
    "masquerade-nodes-comfyui"
    "RES4LYF"
    "rgthree-comfy"
    "seedvarianceenhancer"
    "seedvr2_videoupscaler"
    "was-ns"
    "Z-Image-Turbo-Lora-Stack-V4"
  )

  # Git fallback metadata from workflow aux_id plus current upstream repos for
  # packages that have historically had stale/misattributed registry metadata.
  declare -A NODE_GIT_FALLBACK=(
    ["comfyliterals"]="https://github.com/YaserJaradeh/comfyui-yaser-nodes.git|comfyui-yaser-nodes"
    ["comfyui-aspect-ratio-crop-node"]="https://github.com/vrgamegirl19/comfyui-vrgamedevgirl.git|comfyui-vrgamedevgirl"
    ["ComfyMath"]="https://github.com/evanspearman/ComfyMath.git|ComfyMath"
    ["comfyui-custom-scripts"]="https://github.com/pythongosssss/ComfyUI-Custom-Scripts.git|ComfyUI-Custom-Scripts"
    ["comfyui-easy-use"]="https://github.com/yolain/ComfyUI-Easy-Use.git|ComfyUI-Easy-Use"
    ["comfyui-frame-interpolation"]="https://github.com/Fannovel16/ComfyUI-Frame-Interpolation.git|ComfyUI-Frame-Interpolation"
    ["ComfyUI-GGUF"]="https://github.com/city96/ComfyUI-GGUF.git|ComfyUI-GGUF"
    ["comfyui-impact-pack"]="https://github.com/ltdrdata/ComfyUI-Impact-Pack.git|ComfyUI-Impact-Pack"
    ["comfyui-impact-subpack"]="https://github.com/ltdrdata/ComfyUI-Impact-Subpack.git|ComfyUI-Impact-Subpack"
    ["comfyui-inpaint-cropandstitch"]="https://github.com/lquesada/ComfyUI-Inpaint-CropAndStitch.git|ComfyUI-Inpaint-CropAndStitch"
    ["comfyui-kjnodes"]="https://github.com/kijai/ComfyUI-KJNodes.git|ComfyUI-KJNodes"
    ["comfyui-krea2edit"]="https://github.com/lbouaraba/comfyui-krea2edit.git|comfyui-krea2edit"
    ["comfyui-propost"]="https://github.com/digitaljohn/comfyui-propost.git|comfyui-propost"
    ["comfyui-rmbg"]="https://github.com/1038lab/ComfyUI-RMBG.git|ComfyUI-RMBG"
    ["comfyui-sam3"]="https://github.com/PozzettiAndrea/ComfyUI-SAM3.git|ComfyUI-SAM3"
    ["ComfyUI-segment-anything-2"]="https://github.com/kijai/ComfyUI-segment-anything-2.git|ComfyUI-segment-anything-2"
    ["comfyui-videohelpersuite"]="https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git|ComfyUI-VideoHelperSuite"
    ["comfyui-wananimatepreprocess"]="https://github.com/kijai/ComfyUI-WanAnimatePreprocess.git|ComfyUI-WanAnimatePreprocess"
    ["ComfyUI-WanVideoWrapper"]="https://github.com/kijai/ComfyUI-WanVideoWrapper.git|ComfyUI-WanVideoWrapper"
    ["ComfyUI_Comfyroll_CustomNodes"]="https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes.git|ComfyUI_Comfyroll_CustomNodes"
    ["comfyui_controlnet_aux"]="https://github.com/Fannovel16/comfyui_controlnet_aux.git|comfyui_controlnet_aux"
    ["comfyui_essentials"]="https://github.com/cubiq/ComfyUI_essentials.git|ComfyUI_essentials"
    ["comfyui_ipadapter_plus"]="https://github.com/cubiq/ComfyUI_IPAdapter_plus.git|ComfyUI_IPAdapter_plus"
    ["comfyui_ultimatesdupscale"]="https://github.com/ssitu/ComfyUI_UltimateSDUpscale.git|ComfyUI_UltimateSDUpscale"
    ["crt-nodes"]="https://github.com/plugcrypt/CRT-Nodes.git|CRT-Nodes"
    ["lanpaint"]="https://github.com/scraed/LanPaint.git|LanPaint"
    ["RES4LYF"]="https://github.com/ClownsharkBatwing/RES4LYF.git|RES4LYF"
    ["rgthree-comfy"]="https://github.com/rgthree/rgthree-comfy.git|rgthree-comfy"
    ["seedvarianceenhancer"]="https://github.com/ChangeTheConstants/SeedVarianceEnhancer.git|SeedVarianceEnhancer"
    ["seedvr2_videoupscaler"]="https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler.git|seedvr2_videoupscaler"
    ["cg-use-everywhere"]="https://github.com/chrisgoringe/cg-use-everywhere.git|cg-use-everywhere"
    ["comfyui-detail-daemon"]="https://github.com/Jonseed/ComfyUI-Detail-Daemon.git|ComfyUI-Detail-Daemon"
    ["ComfyUI-MelBandRoFormer"]="https://github.com/kijai/ComfyUI-MelBandRoFormer.git|ComfyUI-MelBandRoFormer"
    ["comfyui-mxtoolkit"]="https://github.com/Smirnov75/ComfyUI-mxToolkit.git|ComfyUI-mxToolkit"
    ["comfyui-unload-model"]="https://github.com/SeanScripts/ComfyUI-Unload-Model.git|ComfyUI-Unload-Model"
    ["comfyui_fearnworksnodes"]="https://github.com/fearnworks/ComfyUI_FearnworksNodes.git|ComfyUI_FearnworksNodes"
    ["ComfyUI_JPS-Nodes"]="https://github.com/JPS-GER/ComfyUI_JPS-Nodes.git|ComfyUI_JPS-Nodes"
    ["efficiency-nodes-comfyui"]="https://github.com/jags111/efficiency-nodes-comfyui.git|efficiency-nodes-comfyui"
    ["image-size-tools"]="https://github.com/TheLustriVA/ComfyUI-Image-Size-Tools.git|ComfyUI-Image-Size-Tools"
    ["masquerade"]="https://github.com/BadCafeCode/masquerade-nodes-comfyui.git|masquerade-nodes-comfyui"
    ["masquerade-nodes-comfyui"]="https://github.com/BadCafeCode/masquerade-nodes-comfyui.git|masquerade-nodes-comfyui"
    ["was-ns"]="https://github.com/WASasquatch/was-node-suite-comfyui.git|was-node-suite-comfyui"
  )

  install_requirements_for_dir() {
    local dest="$1"
    if [[ -f "$dest/requirements.txt" ]]; then
      echo "       requirements: $(basename "$dest")"
      pip_install -r "$dest/requirements.txt"
    fi
    if [[ -f "$dest/install.py" ]]; then
      echo "       install.py: $(basename "$dest")"
      (cd "$dest" && "$PYTHON_BIN" install.py) || return 1
    fi
  }

  install_git_node() {
    local url="$1" dir="$2" dest="$COMFY_DIR/custom_nodes/$dir"
    if [[ -d "$dest/.git" ]]; then
      echo "  GIT  $dir (update)"
      git -C "$dest" pull --ff-only || true
    elif [[ -e "$dest" ]]; then
      echo "  KEEP $dir (directory already exists)"
    else
      echo "  GIT  $url"
      git clone --depth 1 "$url" "$dest"
    fi
    install_requirements_for_dir "$dest"
  }

  # Manager is a second installer fallback for registry edge cases.
  MANAGER_DIR="$COMFY_DIR/custom_nodes/ComfyUI-Manager"
  if [[ -d "$MANAGER_DIR/.git" ]]; then
    git -C "$MANAGER_DIR" pull --ff-only || true
  elif [[ -e "$MANAGER_DIR" ]]; then
    echo "  KEEP ComfyUI-Manager fallback (existing non-git directory)"
  else
    echo "  GIT  ComfyUI-Manager fallback"
    git clone --depth 1 https://github.com/Comfy-Org/ComfyUI-Manager.git "$MANAGER_DIR" || \
      git clone --depth 1 https://github.com/ltdrdata/ComfyUI-Manager.git "$MANAGER_DIR"
  fi
  install_requirements_for_dir "$MANAGER_DIR" || true

  NODE_FAILURES=()
  pushd "$COMFY_DIR" >/dev/null
  for node_id in "${NODE_IDS[@]}"; do
    echo "  NODE $node_id"
    if "$COMFY_CMD" --here node registry-install "$node_id"; then
      continue
    fi

    echo "       registry-install failed; trying Git/Manager fallback" >&2
    fallback="${NODE_GIT_FALLBACK[$node_id]:-}"
    if [[ -n "$fallback" ]]; then
      url="${fallback%%|*}"
      dir="${fallback#*|}"
      if install_git_node "$url" "$dir"; then
        continue
      fi
    fi

    if [[ -f "$MANAGER_DIR/cm-cli.py" ]] && \
       "$PYTHON_BIN" "$MANAGER_DIR/cm-cli.py" install "$node_id" --mode remote; then
      continue
    fi
    NODE_FAILURES+=("$node_id")
  done
  popd >/dev/null

  # Workflow aux_id references that do not map reliably to a single registry ID.
  AUX_REPOS=(
    "https://github.com/aining2022/ComfyUI_Swwan.git|ComfyUI_Swwan"
    "https://github.com/huchukato/ComfyUI-QwenVL-Mod.git|ComfyUI-QwenVL-Mod"
    "https://github.com/spacepxl/ComfyUI-VAE-Utils.git|ComfyUI-VAE-Utils"
    "https://github.com/YaserJaradeh/comfyui-yaser-nodes.git|comfyui-yaser-nodes"
    "https://github.com/vrgamegirl19/comfyui-vrgamedevgirl.git|comfyui-vrgamedevgirl"
  )
  for item in "${AUX_REPOS[@]}"; do
    install_git_node "${item%%|*}" "${item#*|}" || NODE_FAILURES+=("${item#*|}")
  done

  # NOIR ZIT uses the bundled INSTARAW custom-node pack shipped alongside this installer.
  INSTARAW_DEST="$COMFY_DIR/custom_nodes/ComfyUI_INSTARAW"
  if [[ -d "$INSTARAW_DEST" ]]; then
    echo "  KEEP ComfyUI_INSTARAW (already installed)"
  else
    echo "  BUNDLE ComfyUI_INSTARAW"
    tmp_bundle="$(mktemp --suffix=.tar.gz)"
    bundle_url="${SEEDRA_INSTARAW_URL:-$INSTALLER_BASE_URL/ComfyUI_INSTARAW.tar.gz}"
    if command -v curl >/dev/null 2>&1; then
      curl -fL --retry 4 --retry-delay 2 --connect-timeout 20 "$bundle_url" -o "$tmp_bundle"
    elif command -v wget >/dev/null 2>&1; then
      wget -qO "$tmp_bundle" "$bundle_url"
    else
      echo "ERROR: curl or wget is required to download ComfyUI_INSTARAW." >&2
      rm -f "$tmp_bundle"
      exit 1
    fi
    tar -xzf "$tmp_bundle" -C "$COMFY_DIR/custom_nodes"
    rm -f "$tmp_bundle"
  fi
  install_requirements_for_dir "$INSTARAW_DEST" || NODE_FAILURES+=("ComfyUI_INSTARAW")

  # If rife49.pth is present in the user's HF repo, place it into the VFI node's
  # actual ckpt directory now that the node exists. Otherwise VFI auto-downloads it.
  RIFE_STORE="$STORE_DIR/rife49.pth"
  RIFE_DEST="$COMFY_DIR/custom_nodes/ComfyUI-Frame-Interpolation/ckpts/rife/rife49.pth"
  if [[ -f "$RIFE_STORE" && -d "$COMFY_DIR/custom_nodes/ComfyUI-Frame-Interpolation" ]]; then
    mkdir -p "$(dirname "$RIFE_DEST")"
    if [[ ! -e "$RIFE_DEST" ]]; then
      ln "$RIFE_STORE" "$RIFE_DEST" 2>/dev/null || ln -s "$(realpath --relative-to="$(dirname "$RIFE_DEST")" "$RIFE_STORE")" "$RIFE_DEST"
      echo "  LINK custom_nodes/ComfyUI-Frame-Interpolation/ckpts/rife/rife49.pth"
    fi
  fi

  echo "[7/7] Custom-node phase complete."
  if (( ${#NODE_FAILURES[@]} > 0 )); then
    echo "ERROR: these custom nodes could not be installed after registry + fallback attempts:" >&2
    printf '  - %s\n' "${NODE_FAILURES[@]}" >&2
    echo "See the log above; installer is returning a failure instead of silently claiming success." >&2
    exit 1
  fi
fi

echo
echo "Log saved to: $LOG_FILE"

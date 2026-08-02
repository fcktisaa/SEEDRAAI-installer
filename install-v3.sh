#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="2.0.2"
REPO_ID="${SEEDRA_REPO_ID:-SEEDRAAI/SEEDRAAI}"
REVISION="${SEEDRA_REVISION:-main}"
WORKERS="${SEEDRA_WORKERS:-16}"
COMFY_DIR="${COMFY_DIR:-}"
HF_TOKEN="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}"
FORCE="${SEEDRA_FORCE:-0}"
COMPAT_ALIASES="${SEEDRA_COMPAT_ALIASES:-0}"
SKIP_EXTERNAL="${SEEDRA_SKIP_EXTERNAL:-0}"
DRY_RUN=0
PACK="${SEEDRA_PACK:-full}"

usage() {
  cat <<'USAGE'
SEEDRAAI model installer

Usage:
  HF_TOKEN=hf_xxx bash install.sh --pack PACK [options]

Packs:
  full, motion, studio, social, nsfw

Options:
  --pack PACK            Model pack to install (default: full)
  --hf-token TOKEN       Hugging Face read token for SEEDRAAI/SEEDRAAI
  --comfy-dir PATH       Path to ComfyUI (auto-detected by default)
  --workers N            Concurrent file downloads (default: 16)
  --revision REV         SEEDRAAI repository branch/tag/commit (default: main)
  --compat-aliases       Also create old workflow filenames
  --skip-external        Do not download external Wan 2.2 Animate model
  --force                Replace conflicting destination files
  --dry-run              Show the plan without downloading or changing files
  -h, --help             Show help

Both forms are accepted: --pack motion and --pack=motion.

Environment equivalents:
  HF_TOKEN, COMFY_DIR, SEEDRA_PACK, SEEDRA_WORKERS, SEEDRA_REVISION,
  SEEDRA_COMPAT_ALIASES, SEEDRA_SKIP_EXTERNAL, SEEDRA_FORCE
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
    --revision)
      [[ $# -ge 2 ]] || { echo "Error: --revision requires a value." >&2; exit 2; }
      REVISION="$2"; shift 2 ;;
    --revision=*) REVISION="${1#*=}"; shift ;;
    --compat-aliases) COMPAT_ALIASES=1; shift ;;
    --skip-external) SKIP_EXTERNAL=1; shift ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

PACK="${PACK,,}"
case "$PACK" in
  full|motion|studio|social|nsfw) ;;
  *) echo "Error: invalid pack '$PACK'. Use: full, motion, studio, social, nsfw." >&2; exit 2 ;;
esac

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
printf ' Legacy aliases: %s\n' "$COMPAT_ALIASES"
if [[ "$SKIP_EXTERNAL" == "1" || "$PACK" == "social" || "$PACK" == "studio" ]]; then
  printf ' External Wan  : skipped\n'
else
  printf ' External Wan  : enabled\n'
fi
printf '=============================================\n\n'

if [[ "$DRY_RUN" != "1" && -z "$HF_TOKEN" ]]; then
  echo "Error: SEEDRAAI/SEEDRAAI is gated and requires HF_TOKEN." >&2
  exit 1
fi

PYTHON_BIN="$(command -v python3 || command -v python || true)"
if [[ -z "$PYTHON_BIN" ]]; then
  echo "Error: Python was not found." >&2
  exit 1
fi

if [[ "$DRY_RUN" != "1" ]]; then
  if ! "$PYTHON_BIN" -c 'import huggingface_hub, hf_xet' >/dev/null 2>&1; then
    echo "[1/5] Installing Hugging Face downloader..."
    if ! "$PYTHON_BIN" -m pip install -q -U 'huggingface_hub[hf_xet]'; then
      "$PYTHON_BIN" -m pip install -q -U --break-system-packages 'huggingface_hub[hf_xet]'
    fi
  else
    echo "[1/5] Hugging Face downloader is already installed."
  fi
else
  echo "[1/5] Dry run: dependency installation skipped."
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
export SEEDRA_DRY_RUN="$DRY_RUN"

export HF_XET_HIGH_PERFORMANCE="${HF_XET_HIGH_PERFORMANCE:-1}"
export HF_XET_CHUNK_CACHE_SIZE_BYTES="${HF_XET_CHUNK_CACHE_SIZE_BYTES:-0}"
export HF_HUB_DOWNLOAD_TIMEOUT="${HF_HUB_DOWNLOAD_TIMEOUT:-600}"
export HF_HUB_ETAG_TIMEOUT="${HF_HUB_ETAG_TIMEOUT:-60}"
export HF_HOME="${HF_HOME:-$STORE_DIR/.hf_home}"

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
    "SEEDRA_CryoDetail_K7.safetensors": "models/loras",
    "SEEDRA_CrystalNode_D2.safetensors": "models/vae",
    "SEEDRA_DermaFlux_ULTRA_v4.safetensors": "models/diffusion_models",
    "SEEDRA_DetailBloom_LoRA_v1.safetensors": "models/loras",
    "SEEDRA_DetailPulse_ITF_Lite_x1_v1.pth": "models/upscale_models",
    "SEEDRA_FLUX2_Core.safetensors": "models/diffusion_models",
    "SEEDRA_FLUX2_VAE.safetensors": "models/vae",
    "SEEDRA_FLUX_4B_Core.safetensors": "models/diffusion_models",
    "SEEDRA_FourStep_DMD2_SDXL_LoRA_FP16.safetensors": "models/loras",
    "SEEDRA_FrameForge_XGen.safetensors": "models/loras",
    "SEEDRA_HawkVision_W4.onnx": "models/detection",
    "SEEDRA_IntimateGate_Detector_v2.pt": "models/ultralytics/bbox",
    "SEEDRA_LanguageCore_Qwen3.safetensors": "models/text_encoders",
    "SEEDRA_LanguageCore_Qwen4B_ZImage_Heretic_Q8.gguf": "models/text_encoders",
    "SEEDRA_LanguageCore_Qwen_Main.safetensors": "models/text_encoders",
    "SEEDRA_LipTrace_Detector_v1.pt": "models/ultralytics/bbox",
    "SEEDRA_Nightfall_SDXL.safetensors": "models/checkpoints",
    "SEEDRA_Nocturne_T9.safetensors": "models/text_encoders",
    "SEEDRA_NovaMind_X1.safetensors": "models/loras",
    "SEEDRA_OpticTrace_V7.safetensors": "models/clip_vision",
    "SEEDRA_OriginScale_Upscaler.pth": "models/upscale_models",
    "SEEDRA_PhantomWeave_R5.safetensors": "models/loras",
    "SEEDRA_PoreDetail_FLUX_LoRA.safetensors": "models/loras",
    "SEEDRA_Primary_VAE.safetensors": "models/vae",
    "SEEDRA_PrimeNet_v2.safetensors": "models/loras",
    "SEEDRA_PrismScale_4x.pth": "models/upscale_models",
    "SEEDRA_PromptLens_CLIP-L.safetensors": "models/text_encoders",
    "SEEDRA_QuantumScale_2x.pth": "models/upscale_models",
    "SEEDRA_RazorScale_4x_v2.pth": "models/upscale_models",
    "SEEDRA_SegmentCore_SAM3.pt": "models/sam3",
    "SEEDRA_SkinPulse_ZTurbo.safetensors": "models/diffusion_models",
    "SEEDRA_SolarFlare_L2.safetensors": "models/loras",
    "SEEDRA_TextCore_UMT5_Main.safetensors": "models/text_encoders",
    "SEEDRA_TextCore_UMT5_XXL_FP8_Scaled.safetensors": "models/text_encoders",
    "SEEDRA_TitanCore_FP8.safetensors": "models/text_encoders",
    "SEEDRA_VectorAxis_B6.onnx": "models/detection",
    "SEEDRA_VectorAxis_B7.bin": "models/detection",
    "SEEDRA_VelvetQuant_Q4.safetensors": "models/loras",
    "SEEDRA_ZImage_Core.safetensors": "models/diffusion_models",
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
        "SEEDRA_VectorAxis_B6.onnx",
        "SEEDRA_VectorAxis_B7.bin",
        "SEEDRA_VelvetQuant_Q4.safetensors",
        "SEEDRA_ZImage_Core.safetensors",
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
}

if len(ALL_MODEL_FOLDERS) != 45:
    raise RuntimeError(
        f"Internal manifest error: expected 45 files, got {len(ALL_MODEL_FOLDERS)}"
    )
selected_names = set(ALL_MODEL_FOLDERS) if pack == "full" else PACK_MODELS[pack]
unknown = selected_names.difference(ALL_MODEL_FOLDERS)
if unknown:
    raise RuntimeError(f"Internal pack manifest contains unknown files: {sorted(unknown)}")
MODEL_FOLDERS = {name: ALL_MODEL_FOLDERS[name] for name in sorted(selected_names)}

# Old names used by the supplied legacy workflows. Disabled by default.
LEGACY_ALIASES: dict[str, str] = {
    "SEEDRA_ArcMotion_HIGH_Base.safetensors": "models/diffusion_models/High.safetensors",
    "SEEDRA_ArcMotion_HIGH_V9.safetensors": "models/diffusion_models/HighV9.safetensors",
    "SEEDRA_ArcMotion_LOW_Base.safetensors": "models/diffusion_models/Low.safetensors",
    "SEEDRA_ArcMotion_LOW_V9.safetensors": "models/diffusion_models/LowV9.safetensors",
    "SEEDRA_AreolaTrace_Detector_v1.pt": "models/ultralytics/bbox/nipple.pt",
    "SEEDRA_BloomScale_4x_SP.pth": "models/upscale_models/4x_NMKD-Superscale-SP_178000_G.pth",
    "SEEDRA_CryoDetail_K7.safetensors": "models/loras/FrostByte_K7.safetensors",
    "SEEDRA_CrystalNode_D2.safetensors": "models/vae/GlassRoot_D2.safetensors",
    "SEEDRA_DermaFlux_ULTRA_v4.safetensors": "models/diffusion_models/HyperFleshUltrav4.safetensors",
    "SEEDRA_DetailBloom_LoRA_v1.safetensors": "models/loras/DetailedNipples.safetensors",
    "SEEDRA_DetailPulse_ITF_Lite_x1_v1.pth": "models/upscale_models/x1_ITF_SkinDiffDetail_Lite_v1.pth",
    "SEEDRA_FLUX2_Core.safetensors": "models/diffusion_models/flux-2.safetensors",
    "SEEDRA_FLUX2_VAE.safetensors": "models/vae/flux2-vae.safetensors",
    "SEEDRA_FLUX_4B_Core.safetensors": "models/diffusion_models/flux4b.safetensors",
    "SEEDRA_FourStep_DMD2_SDXL_LoRA_FP16.safetensors": "models/loras/dmd2_sdxl_4step_lora_fp16.safetensors",
    "SEEDRA_FrameForge_XGen.safetensors": "models/loras/x_gen_weights.safetensors",
    "SEEDRA_HawkVision_W4.onnx": "models/detection/yolov10m.onnx",
    "SEEDRA_IntimateGate_Detector_v2.pt": "models/ultralytics/bbox/pussyV2.pt",
    "SEEDRA_LanguageCore_Qwen3.safetensors": "models/text_encoders/qwen3.safetensors",
    "SEEDRA_LanguageCore_Qwen4B_ZImage_Heretic_Q8.gguf": "models/text_encoders/qwen-4b-zimage-heretic-q8.gguf",
    "SEEDRA_LanguageCore_Qwen_Main.safetensors": "models/text_encoders/qwen.safetensors",
    "SEEDRA_LipTrace_Detector_v1.pt": "models/ultralytics/bbox/lips_v1.pt",
    "SEEDRA_Nightfall_SDXL.safetensors": "models/checkpoints/SDXLNSFW.safetensors",
    "SEEDRA_Nocturne_T9.safetensors": "models/text_encoders/EchoVault_T9.safetensors",
    "SEEDRA_NovaMind_X1.safetensors": "models/loras/NovaMind_X1.safetensors",
    "SEEDRA_OpticTrace_V7.safetensors": "models/clip_vision/IronSight_V7.safetensors",
    "SEEDRA_OriginScale_Upscaler.pth": "models/upscale_models/upscale1.pth",
    "SEEDRA_PhantomWeave_R5.safetensors": "models/loras/PhantomWeave_R5.safetensors",
    "SEEDRA_PoreDetail_FLUX_LoRA.safetensors": "models/loras/VelvetPores_Flux.safetensors",
    "SEEDRA_Primary_VAE.safetensors": "models/vae/variational_encoder_primary.safetensors",
    "SEEDRA_PrimeNet_v2.safetensors": "models/loras/primary_net_v2.safetensors",
    "SEEDRA_PrismScale_4x.pth": "models/upscale_models/RealityGlass4x.pth",
    "SEEDRA_PromptLens_CLIP-L.safetensors": "models/text_encoders/clip_l.safetensors",
    "SEEDRA_QuantumScale_2x.pth": "models/upscale_models/RealESRGAN_x2.pth",
    "SEEDRA_RazorScale_4x_v2.pth": "models/upscale_models/4x-UltraSharpV2.pth",
    "SEEDRA_SegmentCore_SAM3.pt": "models/sam3/sam3.pt",
    "SEEDRA_SkinPulse_ZTurbo.safetensors": "models/diffusion_models/Z-TurboSkinForge.safetensors",
    "SEEDRA_SolarFlare_L2.safetensors": "models/loras/SolarFlint_L2.safetensors",
    "SEEDRA_TextCore_UMT5_Main.safetensors": "models/text_encoders/umt5.safetensors",
    "SEEDRA_TextCore_UMT5_XXL_FP8_Scaled.safetensors": "models/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors",
    "SEEDRA_TitanCore_FP8.safetensors": "models/text_encoders/TitanFP8.safetensors",
    "SEEDRA_VectorAxis_B6.onnx": "models/detection/vitpose_h_wholebody_model.onnx",
    "SEEDRA_VectorAxis_B7.bin": "models/detection/vitpose_h_wholebody_data.bin",
    "SEEDRA_VelvetQuant_Q4.safetensors": "models/loras/VelvetRush_Q4.safetensors",
    "SEEDRA_ZImage_Core.safetensors": "models/diffusion_models/zimage.safetensors",
}

# These aliases are retained because some custom nodes expect fixed filenames internally.
REQUIRED_ALIASES: dict[str, str] = {
    "SEEDRA_HawkVision_W4.onnx": "models/detection/yolov10m.onnx",
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

print(f"[2/5] Pack: {pack} | Manifest: {len(MODEL_FOLDERS)} SEEDRAAI files")
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

missing_remote = [name for name in MODEL_FOLDERS if name not in main_sizes]
if missing_remote:
    print("ERROR: files missing from the SEEDRAAI repository:", file=sys.stderr)
    for name in missing_remote:
        print(f"  - {name}", file=sys.stderr)
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
for name in MODEL_FOLDERS:
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

print("[3/5] Downloading SEEDRAAI files...")
snapshot_download(
    repo_id=repo_id,
    revision=revision,
    repo_type="model",
    local_dir=str(store),
    allow_patterns=list(MODEL_FOLDERS.keys()),
    token=token,
    max_workers=workers,
)

if include_external:
    print("[4/5] Downloading Wan 2.2 Animate 14B...")
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
    print("[4/5] External Wan model skipped.")

for name, expected in main_sizes.items():
    if name not in MODEL_FOLDERS:
        continue
    path = store / name
    if not path.is_file() or path.stat().st_size != expected:
        raise RuntimeError(f"Invalid downloaded file: {path}")

print("[5/5] Creating ComfyUI model links...")
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
    "installer_version": "2.0.2",
    "pack": pack,
    "repository": repo_id,
    "revision": revision,
    "installed_at_unix": int(time.time()),
    "comfy_dir": str(comfy),
    "store_dir": str(store),
    "canonical_destinations": canonical_destinations,
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

echo
echo "Log saved to: $LOG_FILE"

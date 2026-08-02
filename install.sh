#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="1.0.0"
REPO_ID="${SEEDRA_REPO_ID:-SEEDRAAI/SEEDRAAI}"
REVISION="${SEEDRA_REVISION:-main}"
WORKERS="${SEEDRA_WORKERS:-16}"
COMFY_DIR="${COMFY_DIR:-}"
HF_TOKEN="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}"
FORCE="${SEEDRA_FORCE:-0}"
DRY_RUN=0

usage() {
  cat <<'EOF'
SEEDRAAI model installer

Usage:
  HF_TOKEN=hf_xxx bash install_seedra.sh [options]

Options:
  --hf-token TOKEN       Hugging Face read token for the gated repository
  --comfy-dir PATH       Path to ComfyUI (auto-detected by default)
  --workers N            Concurrent file downloads (default: 16)
  --revision REV         Hugging Face branch/tag/commit (default: main)
  --force                Replace conflicting destination files
  --dry-run              Show the mapping without downloading
  -h, --help             Show help

Environment equivalents:
  HF_TOKEN, COMFY_DIR, SEEDRA_WORKERS, SEEDRA_REVISION, SEEDRA_FORCE
EOF
}

for arg in "$@"; do
  case "$arg" in
    --hf-token=*) HF_TOKEN="${arg#*=}" ;;
    --comfy-dir=*) COMFY_DIR="${arg#*=}" ;;
    --workers=*) WORKERS="${arg#*=}" ;;
    --revision=*) REVISION="${arg#*=}" ;;
    --force) FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

if ! [[ "$WORKERS" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: --workers must be a positive integer." >&2
  exit 2
fi

find_comfy() {
  local candidates=(
    "/workspace/ComfyUI"
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
  echo "Run with: COMFY_DIR=/path/to/ComfyUI HF_TOKEN=... bash install_seedra.sh" >&2
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
printf ' ComfyUI    : %s\n' "$COMFY_DIR"
printf ' Store      : %s\n' "$STORE_DIR"
printf ' Workers    : %s\n' "$WORKERS"
printf '=============================================\n\n'

if [[ "$DRY_RUN" != "1" && -z "$HF_TOKEN" ]]; then
  echo "Error: this Hugging Face repository is gated and requires HF_TOKEN." >&2
  echo "Accept access on the repository page, create a read token, then run:" >&2
  echo "HF_TOKEN='hf_...' bash install_seedra.sh" >&2
  exit 1
fi

PYTHON_BIN="$(command -v python3 || command -v python || true)"
if [[ -z "$PYTHON_BIN" ]]; then
  echo "Error: Python was not found." >&2
  exit 1
fi

if [[ "$DRY_RUN" != "1" ]]; then
  if ! "$PYTHON_BIN" -c 'import huggingface_hub, hf_xet' >/dev/null 2>&1; then
    echo "[1/4] Installing Hugging Face downloader..."
    if ! "$PYTHON_BIN" -m pip install -q -U 'huggingface_hub[hf_xet]'; then
      "$PYTHON_BIN" -m pip install -q -U --break-system-packages 'huggingface_hub[hf_xet]'
    fi
  else
    echo "[1/4] Hugging Face downloader is already installed."
  fi
else
  echo "[1/4] Dry run: dependency installation skipped."
fi

export HF_TOKEN
export SEEDRA_REPO_ID="$REPO_ID"
export SEEDRA_REVISION="$REVISION"
export SEEDRA_WORKERS="$WORKERS"
export SEEDRA_COMFY_DIR="$COMFY_DIR"
export SEEDRA_STORE_DIR="$STORE_DIR"
export SEEDRA_FORCE="$FORCE"
export SEEDRA_DRY_RUN="$DRY_RUN"

# Maximize throughput on Vast/RunPod NVMe machines and avoid an extra 10 GiB Xet chunk cache.
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
revision = os.environ["SEEDRA_REVISION"]
workers = int(os.environ["SEEDRA_WORKERS"])
comfy = Path(os.environ["SEEDRA_COMFY_DIR"]).resolve()
store = Path(os.environ["SEEDRA_STORE_DIR"]).resolve()
force = os.environ.get("SEEDRA_FORCE", "0") == "1"
dry_run = os.environ.get("SEEDRA_DRY_RUN", "0") == "1"
token = os.environ.get("HF_TOKEN") or None

# Repository filename -> path expected by the supplied ComfyUI workflows.
MAPPING: dict[str, str] = {
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

if len(MAPPING) != 45:
    raise RuntimeError(f"Internal manifest error: expected 45 files, got {len(MAPPING)}")

print(f"[2/4] Manifest: {len(MAPPING)} repository files")
if dry_run:
    for source, destination in MAPPING.items():
        print(f"  {source} -> {destination}")
    print("\nDry run complete. Nothing was downloaded or changed.")
    raise SystemExit(0)

from huggingface_hub import HfApi, snapshot_download

# Validate gated repository access and estimate the remaining download size.
remote_sizes: dict[str, int] = {}
try:
    info = HfApi().model_info(repo_id, revision=revision, token=token, files_metadata=True)
    for sibling in info.siblings or []:
        name = getattr(sibling, "rfilename", None)
        size = getattr(sibling, "size", None)
        if name and isinstance(size, int):
            remote_sizes[name] = size
except Exception as exc:
    print(f"ERROR: cannot access {repo_id}: {exc}", file=sys.stderr)
    print("Accept the repository conditions and use a Hugging Face read token.", file=sys.stderr)
    raise SystemExit(1)

missing_remote = [name for name in MAPPING if name not in remote_sizes]
if missing_remote:
    print("ERROR: files missing from the Hugging Face repository:", file=sys.stderr)
    for name in missing_remote:
        print(f"  - {name}", file=sys.stderr)
    raise SystemExit(1)

store.mkdir(parents=True, exist_ok=True)
remaining = 0
for name in MAPPING:
    local = store / name
    expected = remote_sizes[name]
    actual = local.stat().st_size if local.exists() else 0
    if actual != expected:
        remaining += expected

free = shutil.disk_usage(comfy).free
reserve = 5 * 1024**3
print(f"  Remaining download: {remaining / 1024**3:.1f} GiB")
print(f"  Free disk space   : {free / 1024**3:.1f} GiB")
if free < remaining + reserve:
    need = (remaining + reserve - free) / 1024**3
    print(f"ERROR: insufficient disk space. Add at least {need:.1f} GiB.", file=sys.stderr)
    raise SystemExit(1)

print("[3/4] Downloading from Hugging Face...")
snapshot_download(
    repo_id=repo_id,
    revision=revision,
    repo_type="model",
    local_dir=str(store),
    allow_patterns=list(MAPPING.keys()),
    token=token,
    max_workers=workers,
)

# Validate every completed file before creating links.
for name, expected in remote_sizes.items():
    if name not in MAPPING:
        continue
    path = store / name
    if not path.is_file():
        raise RuntimeError(f"Downloaded file is missing: {path}")
    if path.stat().st_size != expected:
        raise RuntimeError(
            f"Wrong size for {name}: {path.stat().st_size} bytes; expected {expected}"
        )

print("[4/4] Creating ComfyUI model links...")
created = 0
skipped = 0
replaced = 0
link_modes: dict[str, int] = {"hardlink": 0, "symlink": 0}

for source_name, relative_destination in MAPPING.items():
    source = store / source_name
    destination = comfy / relative_destination
    destination.parent.mkdir(parents=True, exist_ok=True)

    if os.path.lexists(destination):
        try:
            if os.path.samefile(source, destination):
                print(f"  OK   {relative_destination}")
                skipped += 1
                continue
        except OSError:
            pass

        if destination.is_file() and not destination.is_symlink():
            if destination.stat().st_size == source.stat().st_size:
                print(f"  KEEP {relative_destination} (existing same-size file)")
                skipped += 1
                continue

        if not force:
            raise RuntimeError(
                f"Destination already exists and conflicts: {destination}\n"
                "Rerun with --force only if it is safe to replace it."
            )

        backup = destination.with_name(destination.name + f".bak.{int(time.time())}")
        destination.rename(backup)
        print(f"  BAK  {relative_destination} -> {backup.name}")
        replaced += 1

    try:
        os.link(source, destination)
        mode = "hardlink"
    except OSError:
        relative_source = os.path.relpath(source, destination.parent)
        os.symlink(relative_source, destination)
        mode = "symlink"

    print(f"  LINK {relative_destination} [{mode}]")
    link_modes[mode] += 1
    created += 1

manifest = {
    "installer_version": "1.0.0",
    "repository": repo_id,
    "revision": revision,
    "installed_at_unix": int(time.time()),
    "comfy_dir": str(comfy),
    "store_dir": str(store),
    "mapping": MAPPING,
}
(store / "seedra-install-manifest.json").write_text(
    json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8"
)

print("\n=============================================")
print(" Installation completed")
print(f" Created : {created}")
print(f" Existing: {skipped}")
print(f" Replaced: {replaced}")
print(f" Hardlinks: {link_modes['hardlink']} | Symlinks: {link_modes['symlink']}")
print(" Restart ComfyUI or press R to refresh models.")
print("=============================================")
PY

echo
echo "Log saved to: $LOG_FILE"

#!/bin/bash
# Serverless worker entrypoint: materialize baked ComfyUI, point it at the
# network volume for models, then hand off to the runpod handler.
set -e

COMFYUI_DIR="/workspace/runpod-slim/ComfyUI"
BAKED="/opt/comfyui-baked"
VENV_DIR="$COMFYUI_DIR/.venv-${VENV_SUFFIX:-cu130}"

if [ ! -f "$COMFYUI_DIR/main.py" ]; then
    echo "Materializing baked ComfyUI into workspace..."
    mkdir -p "$COMFYUI_DIR"
    cp -a "$BAKED/." "$COMFYUI_DIR/"
fi

# Models live on the RunPod network volume — populated once by
# populate-volume.sh, shared across every serverless worker. Extra roots in
# ALT_MODEL_ROOTS (colon-separated) are registered too, so a volume already
# filled by a pod template is reused as-is: Hearmeman's comfyui-minimax pod
# keeps models at /workspace/ComfyUI/models, which serverless mounts at
# /runpod-volume/ComfyUI/models.
ALT_MODEL_ROOTS="${ALT_MODEL_ROOTS:-/runpod-volume/ComfyUI/models}"
export ALT_MODEL_ROOTS
model_paths_block() {
    cat << YAML
$1:
  base_path: $2
  checkpoints: checkpoints
  diffusion_models: |
    diffusion_models
    checkpoints
  unet: unet
  loras: loras
  vae: vae
  text_encoders: text_encoders
  clip_projections: clip_projections
  LLM: LLM
  clip: clip
  clip_vision: clip_vision
  vae_approx: vae_approx
  ultralytics_bbox: ultralytics/bbox
  ultralytics_segm: ultralytics/segm
  sams: sams
  upscale_models: upscale_models
  latent_upscale_models: latent_upscale_models
YAML
}
{
    model_paths_block runpod_volume /runpod-volume/models
    i=0
    IFS=: read -ra alt_roots <<< "$ALT_MODEL_ROOTS"
    for root in "${alt_roots[@]}"; do
        [ -d "$root" ] || continue
        i=$((i + 1))
        echo "entrypoint: also loading models from $root" >&2
        model_paths_block "alt_volume_$i" "$root"
    done
} > "$COMFYUI_DIR/extra_model_paths.yaml"

# sam_vit_b_01ec64.pth is a legacy-tar checkpoint — PyTorch >= 2.6 defaults
# torch.load to weights_only=True which rejects it. Impact Pack's SAMLoader
# calls segment_anything.build_sam → torch.load(f) with no override, so patch
# the lib in place (baked /opt copy and venv both covered by the find roots).
find /usr /opt -name build_sam.py -exec sed -i 's|torch\.load(f)|torch.load(f, weights_only=False)|' {} +

# An early download of sam_vit_b (from dl.fbaipublicfiles.com) left a corrupt
# tar on the volume — populate would skip it as "present". Check the exact
# byte size of the known-good HF copy and force a re-download on mismatch.
[ "$(stat -c%s /runpod-volume/models/sams/sam_vit_b_01ec64.pth 2>/dev/null)" != "375042383" ] && rm -f /runpod-volume/models/sams/sam_vit_b_01ec64.pth

# Auto-populate the network volume on first boot (models-manifest.txt).
# Concurrent cold workers serialize on a flock inside populate-volume.sh;
# disable with VOLUME_AUTOPOPULATE=false.
if [ "${VOLUME_AUTOPOPULATE:-true}" = "true" ]; then
    /opt/serverless/populate-volume.sh || echo "entrypoint: volume populate failed — jobs may error on missing models" >&2
fi

# Flag truncated files in the alt roots (e.g. LoRAs a pod sync never finished
# copying) — ComfyUI would only fail on them mid-job.
for root in "${alt_roots[@]}"; do
    [ -d "$root" ] || continue
    find "$root" -name '*.safetensors' -type f -print0 \
        | xargs -0 -r python3 /opt/serverless/check-safetensors.py \
        | sed 's/^/entrypoint: incomplete model (ignored unless used): /' >&2 || true
done

# CivitAI LoRAs / checkpoints by version ID — same env names as the
# Hearmeman pod template (legacy spellings + CIVITAI_API_KEY accepted).
# Checkpoints land in models/checkpoints, which is also registered as a
# diffusion_models dir above so the graphs' UNETLoaders can pick them.
[ -z "${CIVITAI_LORAS:-}" ] || [ "$CIVITAI_LORAS" = "replace_with_ids" ] && CIVITAI_LORAS="${LORAS_IDS_TO_DOWNLOAD:-}"
[ -z "${CIVITAI_CHECKPOINTS:-}" ] || [ "$CIVITAI_CHECKPOINTS" = "replace_with_ids" ] \
    && CIVITAI_CHECKPOINTS="${CHECKPOINT_IDS_TO_DOWNLOAD:-${SDXL_MODEL_IDS_TO_DOWNLOAD:-}}"
[ -z "${CIVITAI_TOKEN:-}" ] && CIVITAI_TOKEN="${civitai_token:-${CIVITAI_API_KEY:-}}"
export CIVITAI_LORAS CIVITAI_CHECKPOINTS CIVITAI_TOKEN
if [ -d /runpod-volume ]; then
    # Serialize concurrent cold workers so they don't download the same file.
    ( flock 8; python3 /opt/serverless/civitai-download.py ) 8>/runpod-volume/.civitai.lock \
        || echo "entrypoint: some CivitAI downloads failed — jobs using them will error" >&2
fi

# TensorRT engines: the *-TensorRT-Auto nodes compile engines lazily on first
# use under models/tensorrt/ — which lives on ephemeral container disk, so
# every cold worker would rebuild them (minutes). Redirect to the network
# volume so the build happens once ever. Caveat: engines are arch-specific —
# safe because the endpoint is pinned to one GPU pool (BLACKWELL_96).
if [ -d /runpod-volume ]; then
    mkdir -p /runpod-volume/models/tensorrt "$COMFYUI_DIR/models"
    dest="$COMFYUI_DIR/models/tensorrt"
    [ -d "$dest" ] && [ ! -L "$dest" ] && rm -rf "$dest"
    ln -sfn /runpod-volume/models/tensorrt "$dest"
fi

export PATH="$VENV_DIR/bin:$PATH"
exec python3 /opt/serverless/handler.py

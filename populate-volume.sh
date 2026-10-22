#!/bin/bash
# Downloads every file listed in models-manifest.txt onto the network volume.
# Idempotent (skips existing files) and safe for concurrent workers: a flock
# on $VOL_ROOT/.populate.lock serializes the pass, so cold workers racing to
# populate a fresh volume queue up instead of downloading in parallel.
#
# Env:
#   VOL_ROOT   mount point of the network volume   (default /runpod-volume)
#   MANIFEST   path to models-manifest.txt         (default: next to this script)
#   HF_TOKEN   optional Hugging Face token for gated repos
#   ALT_MODEL_ROOTS  colon-separated extra models/ roots already on the volume
#              (default /runpod-volume/ComfyUI/models); a file found there
#              counts as present and is not downloaded again
set -uo pipefail

VOL_ROOT="${VOL_ROOT:-/runpod-volume}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${MANIFEST:-$SCRIPT_DIR/models-manifest.txt}"
M="$VOL_ROOT/models"
IFS=: read -ra ALT_ROOTS <<< "${ALT_MODEL_ROOTS:-$VOL_ROOT/ComfyUI/models}"

if [ ! -d "$VOL_ROOT" ]; then
    echo "populate: $VOL_ROOT not mounted — nothing to do"
    exit 0
fi
if [ ! -f "$MANIFEST" ]; then
    echo "populate: manifest not found at $MANIFEST" >&2
    exit 1
fi

# Serialize concurrent populators on the shared volume
exec 9>"$VOL_ROOT/.populate.lock"
flock 9

# Downloads stage under $STAGE, outside every models/ folder: ComfyUI scans
# those recursively, and a half-downloaded file (or its temp dir vanishing
# mid-scan) breaks its file lists. Per-worker subdirs, because flock on the
# network volume may not serialize across machines.
STAGE="$VOL_ROOT/.populate-tmp"
WORKER_STAGE="$STAGE/$(hostname)-$$"
mkdir -p "$WORKER_STAGE"
trap 'rm -rf "$WORKER_STAGE"' EXIT
# Leftovers from workers killed mid-download (no file touched for an hour),
# plus the in-folder .tmp_hf_* dirs older versions of this script left.
for d in "$STAGE"/*/ "$M"/*/.tmp_hf_*/ "$M"/*/*/.tmp_hf_*/; do
    [ -d "$d" ] && [ "${d%/}" != "$WORKER_STAGE" ] || continue
    find "$d" -type f -mmin -60 2>/dev/null | grep -q . || { echo "populate: removing stale ${d%/}"; rm -rf "$d"; }
done

echo "populate: free space on $VOL_ROOT: $(df -h "$VOL_ROOT" | awk 'NR==2{print $4" of "$2}')"
total=$(grep -vc '^\s*\(#\|$\)' "$MANIFEST")
done_n=0
mkdir -p "$M"

while IFS=$'\t' read -r sub name url; do
    case "$sub" in ''|\#*) continue;; esac
    done_n=$((done_n + 1))
    dest="$M/$sub/$name"
    if [ -f "$dest" ]; then
        echo "populate: [$done_n/$total] skip $name (present)"
        continue
    fi
    alt=""
    for root in "${ALT_ROOTS[@]}"; do
        [ -f "$root/$sub/$name" ] || continue
        # Only trust a complete copy: an interrupted pod sync leaves truncated
        # files there. A good copy lands in $M, which ComfyUI searches first.
        if python3 "$SCRIPT_DIR/check-safetensors.py" "$root/$sub/$name"; then
            alt="$root"; break
        fi
        echo "populate: [$done_n/$total] $root/$sub/$name is incomplete — downloading a fresh copy"
    done
    if [ -n "$alt" ]; then
        echo "populate: [$done_n/$total] skip $name (present in $alt)"
        continue
    fi
    echo "populate: [$done_n/$total] downloading $name -> models/$sub/"
    mkdir -p "$M/$sub"
    ok=0
    if command -v hf >/dev/null 2>&1 && [[ "$url" =~ ^https://huggingface\.co/ ]]; then
        # Plain hf_transfer HTTP path — xet stages chunks on the container
        # disk (30GB cap) and dies with EDQUOT on multi-GB files.
        repo_id=$(echo "$url" | awk -F/ '{print $4"/"$5}')
        repo_path=$(echo "$url" | sed -E 's#https?://[^/]+/[^/]+/[^/]+/resolve/[^/]+/(.+)#\1#')
        tmp_dir="$WORKER_STAGE/$name"
        rm -rf "$tmp_dir"; mkdir -p "$tmp_dir"
        export HF_HUB_ENABLE_HF_TRANSFER=1 HF_HUB_DISABLE_XET=1
        if hf download "$repo_id" "$repo_path" --local-dir "$tmp_dir" && [ -f "$tmp_dir/$repo_path" ]; then
            mv -f "$tmp_dir/$repo_path" "$dest"; ok=1
        fi
        rm -rf "$tmp_dir"
    fi
    if [ "$ok" = 0 ]; then
        hdr=()
        [ -n "${HF_TOKEN:-}" ] && hdr=(--header="Authorization: Bearer $HF_TOKEN")
        if wget -q --continue --tries=5 --timeout=60 "${hdr[@]}" -O "$dest.tmp" "$url"; then
            mv "$dest.tmp" "$dest"; ok=1
        else
            echo "populate: FAILED $name (kept .tmp for resume) — free space: $(df -h "$M" | awk 'NR==2{print $4}')" >&2
        fi
    fi
done < "$MANIFEST"

echo "populate: done — $M"

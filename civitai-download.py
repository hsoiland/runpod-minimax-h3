#!/usr/bin/env python3
"""Download CivitAI model versions onto the network volume (stdlib only).

Same env contract as the Hearmeman comfyui-minimax pod template, so a saved
pod config carries over:

    CIVITAI_LORAS        comma-separated LoRA version IDs  -> models/loras
    CIVITAI_CHECKPOINTS  comma-separated checkpoint IDs    -> models/checkpoints
    CIVITAI_TOKEN        API token (needed for gated / early-access models)

Legacy names (LORAS_IDS_TO_DOWNLOAD, CHECKPOINT_IDS_TO_DOWNLOAD,
SDXL_MODEL_IDS_TO_DOWNLOAD, CIVITAI_API_KEY) are resolved by the entrypoint.

Idempotent: a file already present under models/<kind>/ or any
ALT_MODEL_ROOTS/<kind>/ (e.g. the pod's /workspace/ComfyUI/models) is
skipped. Every resolved ID is recorded in models/<kind>/.civitai/<id>.json so
jobs can reference a LoRA/checkpoint by its version ID.
"""
import json
import os
import sys
import urllib.parse
import urllib.request
from pathlib import Path

VOL_ROOT = Path(os.environ.get("VOL_ROOT", "/runpod-volume"))
MODELS = VOL_ROOT / "models"
ALT_ROOTS = [Path(r) for r in os.environ.get(
    "ALT_MODEL_ROOTS", str(VOL_ROOT / "ComfyUI/models")).split(":") if r]
TOKEN = os.environ.get("CIVITAI_TOKEN") or os.environ.get("civitai_token") or ""
API = "https://civitai.com/api/v1/model-versions/{}"
UA = {"User-Agent": "runpod-minimax-h3"}


def _ids(value):
    if not value or value == "replace_with_ids":
        return []
    return [v.strip() for v in value.split(",") if v.strip()]


def _with_token(url):
    if not TOKEN:
        return url
    sep = "&" if urllib.parse.urlparse(url).query else "?"
    return f"{url}{sep}token={urllib.parse.quote(TOKEN)}"


def _version(vid):
    req = urllib.request.Request(API.format(vid), headers=UA)
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def _pick_file(files):
    """The primary model file, preferring safetensors over pickles."""
    models = [f for f in files if f.get("type", "Model") == "Model"] or files
    return (next((f for f in models if f.get("primary")), None)
            or next((f for f in models if f["name"].endswith(".safetensors")), None)
            or models[0])


def _download(url, dest):
    part = dest.with_name(dest.name + ".part")
    have = part.stat().st_size if part.exists() else 0
    headers = dict(UA)
    if have:
        headers["Range"] = f"bytes={have}-"
    req = urllib.request.Request(_with_token(url), headers=headers)
    with urllib.request.urlopen(req, timeout=120) as r:
        if have and r.status != 206:  # server ignored the range — restart
            have = 0
        with open(part, "ab" if have else "wb") as f:
            while chunk := r.read(8 << 20):
                f.write(chunk)
    part.rename(dest)


def fetch(kind, vid):
    target = MODELS / kind
    index = target / ".civitai"
    target.mkdir(parents=True, exist_ok=True)
    index.mkdir(exist_ok=True)
    meta = _version(vid)
    file = _pick_file(meta.get("files") or [])
    name = file["name"]
    (index / f"{vid}.json").write_text(json.dumps({
        "id": vid, "file": name,
        "model": (meta.get("model") or {}).get("name"),
        "version": meta.get("name"),
        "trained_words": meta.get("trainedWords") or [],
    }))
    for root in (MODELS, *ALT_ROOTS):
        if (root / kind / name).is_file():
            print(f"civitai: skip {kind}/{name} (present in {root})", flush=True)
            return
    print(f"civitai: downloading {vid} -> models/{kind}/{name} "
          f"({file.get('sizeKB', 0) / 1024 / 1024:.1f} GB)", flush=True)
    _download(file.get("downloadUrl") or f"https://civitai.com/api/download/models/{vid}",
              target / name)


def main():
    jobs = [("loras", v) for v in _ids(os.environ.get("CIVITAI_LORAS"))]
    jobs += [("checkpoints", v) for v in _ids(os.environ.get("CIVITAI_CHECKPOINTS"))]
    if not jobs:
        print("civitai: no CIVITAI_LORAS / CIVITAI_CHECKPOINTS set — skipping", flush=True)
        return 0
    if not VOL_ROOT.is_dir():
        print(f"civitai: {VOL_ROOT} not mounted — skipping", flush=True)
        return 0
    failed = 0
    for kind, vid in jobs:
        try:
            fetch(kind, vid)
        except Exception as e:  # one bad ID must not block the rest or the boot
            failed += 1
            hint = " (gated? set CIVITAI_TOKEN)" if "401" in str(e) or "403" in str(e) else ""
            print(f"civitai: FAILED {kind} {vid}: {e}{hint}", file=sys.stderr, flush=True)
    print(f"civitai: done — {len(jobs) - failed}/{len(jobs)} ok", flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

# Voxtral STT sidecar

Python helper process that runs Voxtral-Mini-4B-Realtime locally and provides a second STT backend for Voxflow. Apple Speech is the default; Voxtral kicks in when the user picks `voxtral` in Settings (or sets `VOXFLOW_STT_BACKEND=voxtral`) AND the sidecar is reachable.

## Why a sidecar

- The model is ~8 GB and lives in PyTorch / transformers, which doesn't link cleanly into a Swift app.
- Loading happens once at app launch (~30 s the first time, ~3 s after that), then each dictation reuses the warm model.
- Swift talks to it over a JSONL stdin/stdout protocol — see the docstring at the top of `voxtral_sidecar.py` for the exact messages.

## Install

```bash
python3 -m venv ~/.voxflow/venv
source ~/.voxflow/venv/bin/activate
pip install -r Sources/python/requirements.txt

# point Voxflow at this interpreter
launchctl setenv VOXFLOW_VOXTRAL_PYTHON ~/.voxflow/venv/bin/python
# (or set it in your shell profile and relaunch the app from a terminal)
```

## Test the sidecar standalone

```bash
~/.voxflow/venv/bin/python Sources/python/voxtral_sidecar.py
# wait for {"event":"ready"}, then send:
{"action":"start"}
# ... base64 PCM chunks via {"action":"audio","data":"...","sample_rate":16000} ...
{"action":"finalize"}
# expect {"event":"final","text":"..."}
{"action":"shutdown"}
```

## Why it might not start

- `pip install` failed (no internet, missing build tools, no GPU). Run the install command manually and watch the output.
- `VOXFLOW_VOXTRAL_PYTHON` isn't set or doesn't exist. The Swift side falls back to Apple Speech in that case and logs the reason in the menu-bar status.
- Model download blocked. First launch fetches ~8 GB from Hugging Face; if you're behind a proxy, set `HF_HUB_ENDPOINT` accordingly before launching.

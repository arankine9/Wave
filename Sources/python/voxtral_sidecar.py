#!/usr/bin/env python3
"""
Voxflow Voxtral STT sidecar.

Protocol: line-delimited JSON on stdin/stdout. Each line is one message.

Inbound (Swift -> sidecar):
    {"action": "start"}
    {"action": "audio", "data": "<base64-encoded-int16-pcm>", "sample_rate": 16000}
    {"action": "finalize"}
    {"action": "shutdown"}

Outbound (sidecar -> Swift):
    {"event": "ready"}
    {"event": "partial", "text": "..."}
    {"event": "final",   "text": "..."}
    {"event": "error",   "message": "..."}

Design notes
------------
- The sidecar is a one-process-per-app-launch helper, NOT per-dictation. The
  model load (~30s on first launch) happens once at startup; each dictation
  reuses the warm model.
- Audio chunks are accumulated until "finalize", then run through the model
  in one pass. A streaming variant is plausible (Voxtral supports incremental
  decoding) but adds complexity.
- "shutdown" is a clean exit; on receiving it we flush any pending output and
  exit 0. The Swift side also handles SIGTERM as a fallback.

Install
-------
    python3 -m venv ~/.voxflow/venv
    source ~/.voxflow/venv/bin/activate
    pip install -r Sources/python/requirements.txt
    export VOXFLOW_VOXTRAL_PYTHON=~/.voxflow/venv/bin/python

The Swift VoxtralBackend reads VOXFLOW_VOXTRAL_PYTHON to find this interpreter.
If unset, it falls back to the default whisper.cpp backend (no Python required).
"""
from __future__ import annotations

import base64
import json
import sys
import traceback
from typing import Any


def emit(payload: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def fatal(message: str) -> None:
    emit({"event": "error", "message": message})
    sys.exit(2)


def load_pipeline():
    """Import-and-load Voxtral. Raises with a friendly message on missing deps."""
    try:
        import torch  # noqa: F401
        from transformers import (  # type: ignore
            VoxtralForConditionalGeneration,
            AutoProcessor,
        )
    except ImportError as exc:
        fatal(
            "Voxtral deps missing. Install with: "
            "pip install -r Sources/python/requirements.txt"
            f" (underlying error: {exc})"
        )
        return None  # unreachable

    model_id = "mistralai/Voxtral-Mini-4B-Realtime-2602"
    try:
        processor = AutoProcessor.from_pretrained(model_id)
        model = VoxtralForConditionalGeneration.from_pretrained(
            model_id, torch_dtype="auto", device_map="auto"
        )
    except Exception as exc:  # broad: surface any HF/torch error
        fatal(f"Voxtral model load failed: {exc}")
        return None
    return processor, model


def main() -> None:
    pair = load_pipeline()
    if pair is None:
        return  # fatal() already exited
    processor, model = pair
    emit({"event": "ready"})

    audio_buffer: list[int] = []
    sample_rate = 16000

    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError as exc:
            emit({"event": "error", "message": f"bad json: {exc}"})
            continue

        action = msg.get("action")
        if action == "start":
            audio_buffer = []
            sample_rate = int(msg.get("sample_rate", 16000))

        elif action == "audio":
            try:
                chunk = base64.b64decode(msg["data"])
            except Exception as exc:
                emit({"event": "error", "message": f"audio decode: {exc}"})
                continue
            # Treat chunk as int16 little-endian PCM.
            import array
            samples = array.array("h")
            samples.frombytes(chunk)
            audio_buffer.extend(samples)

        elif action == "finalize":
            if not audio_buffer:
                emit({"event": "final", "text": ""})
                continue
            try:
                import numpy as np  # type: ignore
                import torch  # type: ignore

                arr = np.array(audio_buffer, dtype=np.float32) / 32768.0
                inputs = processor(
                    audio=arr, sampling_rate=sample_rate, return_tensors="pt"
                ).to(model.device)
                with torch.no_grad():
                    out = model.generate(**inputs, max_new_tokens=200)
                text = processor.batch_decode(out, skip_special_tokens=True)[0]
                emit({"event": "final", "text": text.strip()})
            except Exception:
                emit({"event": "error", "message": traceback.format_exc()})
            finally:
                audio_buffer = []

        elif action == "shutdown":
            return

        else:
            emit({"event": "error", "message": f"unknown action: {action}"})


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    except Exception:
        emit({"event": "error", "message": traceback.format_exc()})
        sys.exit(1)

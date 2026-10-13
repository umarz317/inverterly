"""Lay the spoken lines onto one track at the times the director chose.

    python3.14 Tools/demo-video/mix.py <out-dir>

Reads <out-dir>/timeline.json and <out-dir>/voice/<id>.wav, writes <out-dir>/narration.wav.
"""
import json, os, sys, wave

import numpy as np

out_dir = sys.argv[1]
timeline = json.load(open(os.path.join(out_dir, "timeline.json")))
rate = None
clips = []
for shot in timeline["shots"]:
    with wave.open(os.path.join(out_dir, "voice", shot["id"] + ".wav"), "rb") as w:
        rate = rate or w.getframerate()
        assert w.getframerate() == rate and w.getnchannels() == 1 and w.getsampwidth() == 2
        clips.append((shot["speechAt"], np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float32)))

track = np.zeros(int(timeline["duration"] * rate) + rate // 2, dtype=np.float32)
for start, samples in clips:
    begin = int(start * rate)
    track[begin:begin + len(samples)] += samples[: len(track) - begin]
track = np.clip(track, -32767, 32767).astype("<i2")
with wave.open(os.path.join(out_dir, "narration.wav"), "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate); w.writeframes(track.tobytes())
print(f"narration.wav {len(track) / rate:.1f}s at {rate} Hz")

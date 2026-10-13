"""Voice the InverterBar demo video: one spoken line per shot, offline, with Kokoro.

    python3.14 Tools/demo-video/narrate.py <out-dir>

Writes <out-dir>/voice/<id>.wav and <out-dir>/lines.json (id, text, seconds). The same lines
are the video's subtitles. Kokoro (kokoro-onnx) runs locally; point KOKORO_MODEL and
KOKORO_VOICES at its two files if they are not in ~/.cache/hyperframes/tts.
"""
import json, os, sys, wave

import numpy as np
from kokoro_onnx import Kokoro

# (shot id, what is said and shown). The ids are the ones the Swift director uses.
LINES = [
    ("intro",    "My solar inverter only talks to a phone app. I wanted it on my Mac."),
    ("icon",     "So now it sits in the menu bar. A sun, and a bar that is the battery."),
    ("open",     "Click it, and the panel opens."),
    ("sunny",    "Midday. The panels run the house and charge the battery with what is left."),
    ("evening",  "Evening. The sun is nearly gone, so the battery takes over."),
    ("night",    "At night the grid runs the house and tops the battery up."),
    ("outage",   "When the grid drops, it says so, and a low battery turns red."),
    ("today",    "Today's solar and load are one click down."),
    ("details",  "Every number the inverter reports is under Details."),
    ("styles",   "There are three ways to draw it. The inverter, a flow map, and the house."),
    ("readonly", "It only reads. Nothing in it can change an inverter setting."),
    ("end",      "That is InverterBar."),
]

HOME = os.path.expanduser("~/.cache/hyperframes/tts")
MODEL = os.environ.get("KOKORO_MODEL", os.path.join(HOME, "models", "kokoro-v1.0.onnx"))
VOICES = os.environ.get("KOKORO_VOICES", os.path.join(HOME, "voices", "voices-v1.0.bin"))
VOICE = os.environ.get("KOKORO_VOICE", "af_heart")
SPEED = float(os.environ.get("KOKORO_SPEED", "1.05"))


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "renders"
    voice_dir = os.path.join(out_dir, "voice")
    for p in (MODEL, VOICES):
        if not os.path.exists(p):
            sys.exit(f"missing {p}: set KOKORO_MODEL and KOKORO_VOICES")
    os.makedirs(voice_dir, exist_ok=True)
    tts = Kokoro(MODEL, VOICES)
    lines = []
    for key, text in LINES:
        samples, rate = tts.create(text, voice=VOICE, speed=SPEED, lang="en-us")
        pcm = (np.clip(samples, -1, 1) * 32767).astype("<i2")
        with wave.open(os.path.join(voice_dir, f"{key}.wav"), "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate); w.writeframes(pcm.tobytes())
        seconds = len(pcm) / rate
        lines.append({"id": key, "text": text, "seconds": round(seconds, 3), "rate": rate})
        print(f"{key:9s} {seconds:5.2f}s  {text}")
    with open(os.path.join(out_dir, "lines.json"), "w") as f:
        json.dump(lines, f, indent=2)
    print(f"total speech {sum(l['seconds'] for l in lines):.1f}s")


if __name__ == "__main__":
    main()

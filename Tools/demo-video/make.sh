#!/bin/zsh
# Builds the demo video end to end. Nothing is captured from the screen: the frames are
# rendered from the app's own views at made-up readings.
#
#   Tools/demo-video/make.sh [work-dir] [output.mp4]
#
# Needs ffmpeg, and python3.14 with kokoro-onnx and numpy for the voice.
set -eu
set -o pipefail
cd "$(dirname "$0")/../.."
WORK="${1:-.build/demo-video}"
OUT="${2:-docs/inverterbar-demo.mp4}"
mkdir -p "$WORK" "$(dirname "$OUT")"

python3.14 Tools/demo-video/narrate.py "$WORK"                 # voice/<id>.wav, lines.json
swift run -c release DemoVideo "$WORK/lines.json" "$WORK"      # frames/, timeline.json
python3.14 Tools/demo-video/mix.py "$WORK"                     # narration.wav

ffmpeg -hide_banner -loglevel error -y \
  -framerate 30 -i "$WORK/frames/%05d.png" -i "$WORK/narration.wav" \
  -af "loudnorm=I=-16:TP=-1.5:LRA=11,aresample=48000" \
  -c:v libx264 -preset slow -crf 17 -pix_fmt yuv420p -r 30 \
  -c:a aac -b:a 160k -movflags +faststart -shortest "$OUT"
echo "wrote $OUT"

#!/bin/zsh
# Cleans up a screen recording's voice track and speeds the whole thing up a little.
#
#   Tools/demo-video/polish-recording.sh <input.mov> <output.mp4> [speed=1.2] [width=1920] [audio]
#
# Audio, in order:
#   1. fold to mono and cut rumble below 95 Hz;
#   2. learn the room's noise from the quietest 1.35 s of the recording itself and subtract it
#      (a generic denoiser did almost nothing on a test recording; a sampled one took 11 dB off);
#   3. soften what noise is left in the pauses;
#   4. a little clarity and air, and a gentle levelling of the voice;
#   5. speed up, keeping the pitch;
#   6. set loudness to -16 LUFS in two passes, so the gain is one fixed amount.
# The video is sped up to match and scaled to a web-friendly width.
# A fifth argument of "audio" writes only <output>.wav, for checking the sound quickly.
set -eu
set -o pipefail
IN="$1"; OUT="$2"; SPEED="${3:-1.2}"; WIDTH="${4:-1920}"; MODE="${5:-}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Find the quietest 1.35 s: that is the room on its own.
ffmpeg -hide_banner -loglevel error -y -i "$IN" -vn -ac 1 -ar 8000 -c:a pcm_s16le "$WORK/scan.wav"
NOISE_AT=$(/usr/bin/python3 - "$WORK/scan.wav" <<'PY'
import array, sys, wave
w = wave.open(sys.argv[1]); rate = w.getframerate()
samples = array.array("h"); samples.frombytes(w.readframes(w.getnframes()))
step = rate // 10                                   # 100 ms windows
levels = [sum(v * v for v in samples[i:i + step]) / step for i in range(0, len(samples) - step, step)]
span = 14                                           # 1.4 s
best = min(range(len(levels) - span), key=lambda i: max(levels[i:i + span]))
print(f"{best / 10 + 0.02:.2f}")
PY
)
NOISE_END=$(printf '%.2f' $(( NOISE_AT + 1.35 )))

CLEAN="highpass=f=95,asendcmd=c='0.02 afftdn sn start;1.30 afftdn sn stop',afftdn=nr=18:nf=-50,atrim=start=1.35,asetpts=N/SR/TB,agate=threshold=0.0045:ratio=1.5:attack=6:release=240:range=0.4:knee=5"
TONE="equalizer=f=250:t=q:w=1.1:g=-2,equalizer=f=3200:t=q:w=1.0:g=3.5,highshelf=f=6500:g=3,acompressor=threshold=-22dB:ratio=2.2:attack=8:release=160:makeup=1.5:knee=5"
# The noise sample is played first so the denoiser can learn it, then trimmed off again.
# Back to two identical channels before loudness is measured: the same sound on both channels
# reads 3 LU louder than on one, and it is the stereo file that has to land on the target.
VOICE="[0:a]pan=mono|c0=0.5*c0+0.5*c1,asplit[s0][s1];[s0]atrim=start=${NOISE_AT}:end=${NOISE_END},asetpts=N/SR/TB[noise];[s1]asetpts=N/SR/TB[all];[noise][all]concat=n=2:v=0:a=1,${CLEAN},${TONE},atempo=${SPEED},pan=stereo|c0=c0|c1=c0"
TARGET="I=-16:TP=-1.5:LRA=9"

# Pass 1: measure the cleaned track.
STATS=$(ffmpeg -hide_banner -nostats -i "$IN" -filter_complex "${VOICE},loudnorm=${TARGET}:print_format=json[m]" -map "[m]" -f null - 2>&1 | sed -n '/^{/,/^}/p')
stat() { echo "$STATS" | sed -n "s/.*\"$1\" *: *\"\\([^\"]*\\)\".*/\\1/p"; }
NORM="loudnorm=${TARGET}:measured_I=$(stat input_i):measured_TP=$(stat input_tp):measured_LRA=$(stat input_lra):measured_thresh=$(stat input_thresh):offset=$(stat target_offset):linear=true"
AUDIO="${VOICE},${NORM},alimiter=limit=0.84:level=false,aresample=48000[a]"
echo "room noise sampled at ${NOISE_AT}s; cleaned track measured $(stat input_i) LUFS before the final gain"

if [[ "$MODE" == "audio" ]]; then
  ffmpeg -hide_banner -loglevel error -y -i "$IN" -filter_complex "$AUDIO" -map "[a]" "${OUT%.*}.wav"
  echo "wrote ${OUT%.*}.wav"
  exit 0
fi

# Pass 2: the video sped up to match, with the cleaned audio.
ffmpeg -hide_banner -loglevel error -y -i "$IN" \
  -filter_complex "[0:v]setpts=PTS/${SPEED},scale=${WIDTH}:-2:flags=lanczos,fps=60[v];${AUDIO}" \
  -map "[v]" -map "[a]" \
  -c:v libx264 -preset medium -crf 21 -pix_fmt yuv420p \
  -c:a aac -b:a 192k -movflags +faststart "$OUT"
echo "wrote $OUT"

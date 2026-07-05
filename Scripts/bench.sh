#!/usr/bin/env bash
#
# bench.sh — headless local-decode benchmark, both local engines.
#
# With no args, synthesizes three clips with say(1) (short ~2 s, medium ~6 s,
# long ~15 s), converts them to 16 kHz mono WAV, and runs SkylarkBench over both
# the Parakeet and Whisper engines on the same clips, then prints a comparison
# table. Pass file paths to benchmark your own audio instead. On first run this
# downloads the Parakeet TDT v3 model (~483 MB) AND the Whisper large-v3-turbo
# model (~626 MB) into the app's models dir — expected.
#
# Fully headless: say(1) needs no microphone or GUI.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BENCH_DIR=".build/bench"

if [ "$#" -gt 0 ]; then
    FILES=("$@")
else
    mkdir -p "$BENCH_DIR"
    echo "→ Synthesizing benchmark clips with say(1)…"

    SHORT_TEXT="The quick brown fox jumps over the lazy dog."
    MEDIUM_TEXT="Skylark is a native macOS dictation app that runs entirely on device. \
It listens while you hold a key, then pastes the transcript wherever your cursor is."
    LONG_TEXT="Latency is the product, so every stage of the pipeline is measured and \
budgeted. When you release the key, the audio clip is finalized, the Parakeet model \
decodes it on the neural engine in well under a tenth of a second, the dictionary \
correction map runs, and the raw text is inserted at the cursor, all comfortably \
inside the three hundred millisecond target that makes dictation feel instant."

    synth() {
        local name="$1" text="$2"
        local aiff="$BENCH_DIR/$name.aiff" wav="$BENCH_DIR/$name.wav"
        say -o "$aiff" "$text"
        # 16 kHz mono signed-16 little-endian WAV.
        afconvert -f WAVE -d LEI16@16000 -c 1 "$aiff" "$wav"
        rm -f "$aiff"
        echo "$wav"
    }

    SHORT_WAV="$(synth short "$SHORT_TEXT")"
    MEDIUM_WAV="$(synth medium "$MEDIUM_TEXT")"
    LONG_WAV="$(synth long "$LONG_TEXT")"
    FILES=("$SHORT_WAV" "$MEDIUM_WAV" "$LONG_WAV")
fi

echo "→ swift build -c release --product SkylarkBench"
swift build -c release --product SkylarkBench

RESULTS="$BENCH_DIR/results.tsv"
mkdir -p "$BENCH_DIR"
: > "$RESULTS"

for ENGINE in parakeet whisper; do
    echo ""
    echo "→ Running SkylarkBench (engine: $ENGINE)"
    # Tee the run so RESULT lines are collected for the comparison table while
    # the per-engine table still streams to the console.
    swift run -c release SkylarkBench --engine "$ENGINE" "${FILES[@]}" \
        | tee >(grep '^RESULT' >> "$RESULTS")
done

echo ""
echo "══ Two-engine comparison (median decode ms · RTFx) ══"
awk -F'\t' '
    { file[$3]=$3
      dur[$3]=$4
      ms[$2","$3]=$5
      rtfx[$2","$3]=$6
      seen[$3]=1 }
    END {
        printf "%-28s %8s %12s %8s %12s %8s\n", "file", "dur(s)", "parakeet ms", "RTFx", "whisper ms", "RTFx"
        printf "%s\n", "--------------------------------------------------------------------------------"
        for (f in seen) {
            printf "%-28s %8s %12s %8s %12s %8s\n", substr(f,1,28), dur[f], \
                (("parakeet," f) in ms ? ms["parakeet," f] : "-"), \
                (("parakeet," f) in rtfx ? rtfx["parakeet," f] : "-"), \
                (("whisper," f) in ms ? ms["whisper," f] : "-"), \
                (("whisper," f) in rtfx ? rtfx["whisper," f] : "-")
        }
    }
' "$RESULTS"

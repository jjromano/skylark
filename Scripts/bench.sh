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
#
# Regression gate (ARCHITECTURE.md §8: "regressions block merge"): after the
# run, each (engine, file) median decode time is compared against
# Scripts/bench-baseline.tsv. Anything more than BENCH_TOLERANCE_PCT slower
# than its recorded baseline fails the script (exit 1) with the offending
# numbers named. Only applies to the default synthesized clips — custom file
# args have no baseline entry and are reported without gating. Update the
# baseline deliberately (not to silence a real regression) after confirming a
# slower number is expected, e.g. a bigger model or a slower machine.

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

# --- Regression gate vs the checked-in baseline -----------------------------
#
# Generous tolerance by default: say(1) synthesis + a shared dev machine under
# variable thermal/background load is noisier than CI, and the point is to
# catch a real regression (a slower model, a broken fast path), not thermal
# jitter. Override with BENCH_TOLERANCE_PCT=<n> for a tighter local check.
BASELINE_FILE="$REPO_ROOT/Scripts/bench-baseline.tsv"
TOLERANCE_PCT="${BENCH_TOLERANCE_PCT:-25}"

if [ ! -f "$BASELINE_FILE" ]; then
    echo ""
    echo "⚠ No baseline at $BASELINE_FILE — skipping regression gate."
    exit 0
fi

echo ""
echo "══ Regression check vs $(basename "$BASELINE_FILE") (tolerance ${TOLERANCE_PCT}%) ══"
REGRESSED=0
CHECKED=0
while IFS=$'\t' read -r BASE_ENGINE BASE_NAME BASELINE_MS; do
    case "$BASE_ENGINE" in
        ''|'#'*) continue ;;
    esac
    MEASURED_MS="$(awk -F'\t' -v e="$BASE_ENGINE" -v n="$BASE_NAME" '$2==e && $3==n {print $5}' "$RESULTS")"
    if [ -z "$MEASURED_MS" ]; then
        continue # custom file args this run — no matching (engine, file); not gated
    fi
    CHECKED=$((CHECKED + 1))
    read -r OVER LIMIT PCT <<< "$(awk -v m="$MEASURED_MS" -v b="$BASELINE_MS" -v t="$TOLERANCE_PCT" \
        'BEGIN { limit = b * (1 + t / 100); pct = b > 0 ? (m - b) / b * 100 : 0
                 printf "%d %.1f %+.1f", (m > limit), limit, pct }')"
    if [ "$OVER" = "1" ]; then
        echo "✘ REGRESSION  $BASE_ENGINE/$BASE_NAME: ${MEASURED_MS} ms vs baseline ${BASELINE_MS} ms (${PCT}%, limit is +${TOLERANCE_PCT}% = ${LIMIT} ms)"
        REGRESSED=1
    else
        echo "✔ ok  $BASE_ENGINE/$BASE_NAME: ${MEASURED_MS} ms (baseline ${BASELINE_MS} ms, ${PCT}%)"
    fi
done < "$BASELINE_FILE"

if [ "$CHECKED" -eq 0 ]; then
    echo "(no baseline entries matched this run's files — nothing gated)"
elif [ "$REGRESSED" -eq 1 ]; then
    echo ""
    echo "✗ Latency regression detected — see ARCHITECTURE.md §8 (regressions block merge)."
    exit 1
else
    echo "✓ No latency regressions vs baseline."
fi

#!/usr/bin/env bash
#
# Scripts/run-tests.sh — the verification gate for Cecilia's Notes.
#
# Run this after ANY code change, before pushing. It runs every suite
# that has ever caught a real regression in this project, in the order
# fast → slow, and prints one PASS/FAIL table at the end.
#
# Usage
#   Scripts/run-tests.sh            # FULL gate: unit + UI + Mac + Release (~20-30 min)
#   Scripts/run-tests.sh quick      # unit tests only (~4 min) — for tight iterations
#   Scripts/run-tests.sh unit       # same as quick
#   Scripts/run-tests.sh ui         # UI tests only
#   Scripts/run-tests.sh mac        # Mac build + tests only
#   Scripts/run-tests.sh release    # iOS Release build only (archivability)
#
# Why each stage exists (all were real incidents):
#   unit     — 181 logic tests incl. regression guards (undo LIFO, archive
#              round-trip incl. a real 22MB user file, summarizer, thumbnails).
#   ui       — full XCUITest bundle: draw strokes, undo/redo, lasso,
#              dictation flow, voice notes, onboarding, settings. Catches
#              interaction-layer breaks that unit tests can't see.
#   mac      — CeciliasNotesMac compiles + tests. Shared-group edits have
#              broken the Mac target silently while iOS stayed green
#              (TrashService notification names, 2026-07).
#   release  — Release-config build. The Swift optimizer has crashed on
#              code that Debug compiles fine (EarlyPerfInliner on a
#              generic UIHostingController deinit, 2026-07). A change that
#              can't archive is not shippable.
#
# Simulator: requires an iPad simulator on iOS >= 26.4 (the app's
# deployment target — an 18.x/26.1 sim REFUSES to run the tests).
# Auto-picks the newest available iPad Pro; override with
#   CECILIASNOTES_TEST_UDID=<udid> Scripts/run-tests.sh
#
# Known flake signatures (rerun the stage solo before blaming code):
#   - "RequestDenied by SBMainWorkspace" runner launch denial
#   - AudioToolbox _ReportRPCTimeout abort (wedged sim audio server)
#   If a UI failure persists across a solo rerun, it's real.
#
# Exit codes: 0 all selected stages passed · 1 a stage failed.

set -uo pipefail
cd "$(dirname "$0")/.."

PROJECT="CeciliasNotes/CeciliasNotes.xcodeproj"
CACHE="${HOME}/Library/Caches/CeciliasNotes-verify"
mkdir -p "$CACHE"

MODE="${1:-full}"
case "$MODE" in
    quick|unit) STAGES=(unit) ;;
    ui)         STAGES=(ui) ;;
    mac)        STAGES=(mac) ;;
    release)    STAGES=(release) ;;
    full|all|"") STAGES=(unit ui mac release) ;;
    *) echo "Unknown mode: $MODE (expected: quick|unit|ui|mac|release|full)" >&2; exit 1 ;;
esac

if [[ -t 1 ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BOLD=''; NC=''
fi

# ---- Simulator resolution (iOS >= 26.4, newest first, prefer iPad Pro) ----
resolve_udid() {
    if [[ -n "${CECILIASNOTES_TEST_UDID:-}" ]]; then
        echo "$CECILIASNOTES_TEST_UDID"
        return
    fi
    xcrun simctl list devices available | python3 -c '
import re, sys
runtime, best = None, []   # best: (version, is_pro, name, udid)
for line in sys.stdin:
    m = re.match(r"^-- iOS ([\d.]+) --", line.strip())
    if m:
        runtime = tuple(int(x) for x in m.group(1).split("."))
        continue
    if runtime and runtime >= (26, 4) and line.strip().startswith("iPad"):
        m = re.search(r"\(([0-9A-F]{8}-[0-9A-F-]{27})\)", line)
        if m:
            name = line[: m.start()].strip()
            best.append((runtime, "Pro" in name, name, m.group(1)))
if not best:
    sys.exit(1)
best.sort(key=lambda t: (t[0], t[1]), reverse=True)
print(best[0][3])
'
}

UDID=""
NEED_SIM=false
for s in "${STAGES[@]}"; do
    [[ "$s" == "unit" || "$s" == "ui" ]] && NEED_SIM=true
done
if $NEED_SIM; then
    UDID=$(resolve_udid) || {
        echo "${RED}No iPad simulator on iOS >= 26.4 found.${NC} Install one in Xcode (Settings > Platforms) or set CECILIASNOTES_TEST_UDID." >&2
        exit 1
    }
    SIMNAME=$(xcrun simctl list devices | grep "$UDID" | sed -E 's/^\s*(.*) \([0-9A-F-]{36}.*/\1/' | head -1)
    echo "${BOLD}Simulator:${NC} ${SIMNAME:-$UDID} ($UDID)"
fi

# ---- Stage runner ----
declare -a RESULTS=()
OVERALL=0
START_ALL=$(date +%s)

run_stage() {
    local name="$1"; shift
    local log; log=$(mktemp -t cn-verify-"$name".XXXXXX)
    local start; start=$(date +%s)
    echo
    echo "${BOLD}▶ ${name}${NC} — $*"
    xcodebuild "$@" >"$log" 2>&1
    local dur=$(( $(date +%s) - start ))

    local passed failed verdict
    passed=$(grep -icE "Test case .* passed" "$log" || true)
    failed=$(grep -icE "Test case .* failed" "$log" || true)
    if grep -qE "\*\* TEST SUCCEEDED \*\*|\*\* BUILD SUCCEEDED \*\*" "$log" && [[ "$failed" -eq 0 ]]; then
        verdict="${GREEN}PASS${NC}"
    else
        verdict="${RED}FAIL${NC}"
        OVERALL=1
        echo "${RED}--- failures / errors (${name}) ---${NC}"
        grep -iE "Test case .* failed|error:|\*\* (TEST|BUILD) FAILED" "$log" | head -20
        echo "${YELLOW}full log: $log${NC}"
    fi
    local detail=""
    [[ "$passed" -gt 0 || "$failed" -gt 0 ]] && detail="${passed} passed, ${failed} failed, "
    RESULTS+=("$(printf '%-8s %b  (%s%ss)' "$name" "$verdict" "$detail" "$dur")")
    [[ "$verdict" == *PASS* ]] && rm -f "$log"
}

for s in "${STAGES[@]}"; do
    case "$s" in
        unit)
            run_stage unit \
                -project "$PROJECT" -scheme CeciliasNotes -configuration Debug \
                -destination "platform=iOS Simulator,id=$UDID" \
                -only-testing:CeciliasNotesTests \
                -derivedDataPath "$CACHE/ios" test
            ;;
        ui)
            run_stage ui \
                -project "$PROJECT" -scheme CeciliasNotes -configuration Debug \
                -destination "platform=iOS Simulator,id=$UDID" \
                -only-testing:CeciliasNotesUITests \
                -derivedDataPath "$CACHE/ios" test
            ;;
        mac)
            run_stage mac \
                -project "$PROJECT" -scheme CeciliasNotesMac -configuration Debug \
                -destination "platform=macOS" \
                -derivedDataPath "$CACHE/mac" test
            ;;
        release)
            run_stage release \
                -project "$PROJECT" -scheme CeciliasNotes -configuration Release \
                -destination "generic/platform=iOS" \
                -derivedDataPath "$CACHE/release" \
                CODE_SIGNING_ALLOWED=NO build
            ;;
    esac
done

echo
echo "${BOLD}════════ VERIFICATION SUMMARY ════════${NC}"
for r in "${RESULTS[@]}"; do echo "  $r"; done
echo "  total: $(( $(date +%s) - START_ALL ))s"
if [[ "$OVERALL" -eq 0 ]]; then
    echo "${GREEN}${BOLD}ALL STAGES PASSED — safe to push.${NC}"
else
    echo "${RED}${BOLD}GATE FAILED — do not push.${NC}"
    echo "  UI flakes (RequestDenied launch denial / sim audio abort) are"
    echo "  known: rerun the failed stage solo before blaming the change."
fi
exit "$OVERALL"

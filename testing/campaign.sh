#!/bin/sh
# Evaluates one phase of the flight campaign in test-plan.yaml against the phone's
# log. The phases arrive on the balloon's schedule, not ours, so this exists to be
# run the moment one happens rather than reconstructed afterwards.
#
#   testing/campaign.sh C-3-BURST-AND-DESCENT [HH:MM:SS] [HH:MM:SS]
#
# The optional times bound the phase - where it began and, for a phase already
# over, where it ended. Without them the last 15 minutes are examined. Only the machine-checkable observations are decided here - the ones
# that need eyes on the map are printed as questions for the operator.

set -u
here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
app_id=HB9BLA.BalloonHunter
phase=${1:-}
since=${2:-}
until=${3:-}

if [ -z "$phase" ]; then
    echo "usage: campaign.sh <phase-id> [HH:MM:SS]"
    ruby -ryaml -e 'YAML.load_file(ARGV[0])["campaign"].each{|c| puts "  #{c["id"]}\t#{c["phase"]}"}' "$here/test-plan.yaml"
    exit 1
fi

dev=$(xcodebuild -project "$repo/ios/BalloonHunter.xcodeproj" -scheme BalloonHunter \
      -showdestinations 2>/dev/null | grep 'platform:iOS,' | grep -v placeholder \
      | sed -n 's/.*id:\([0-9A-Fa-f-]*\),.*/\1/p' | head -1)
[ -z "$dev" ] && { echo "campaign: no iPhone connected"; exit 1; }

full=$(mktemp -t balloonhunter-campaign)
xcrun devicectl device copy from --device "$dev" \
    --domain-type appDataContainer --domain-identifier "$app_id" --user mobile \
    --source Documents/balloonhunter.log.csv --destination "$full" >/dev/null 2>&1
[ -s "$full" ] || { echo "campaign: no log on the phone"; exit 1; }

[ -z "$since" ] && since=$(date -v-15M +%H:%M:%S 2>/dev/null || date +%H:%M:%S)
win=$(mktemp -t balloonhunter-window)
if [ -n "$until" ]; then
    awk -F, -v a="$since" -v b="$until" '$1>a && $1<b' "$full" > "$win"
    echo "campaign: $phase, log $since..$until ($(wc -l < "$win" | tr -d ' ') lines)"
else
    awk -F, -v a="$since" '$1>a' "$full" > "$win"
    echo "campaign: $phase, log from $since ($(wc -l < "$win" | tr -d ' ') lines)"
fi

status=0
# present <regex> <what it proves>   - the phase claims this line exists
present() {
    if grep -qE "$1" "$win"; then
        echo "  ok      $2"
        grep -E "$1" "$win" | tail -1 | cut -c1-150 | sed 's/^/          /'
    else
        echo "  MISSING $2"; status=1
    fi
}
# absent <regex> <the must_not it would violate>
absent() {
    if grep -qE "$1" "$win"; then
        echo "  FAIL    $2"
        grep -E "$1" "$win" | tail -1 | cut -c1-150 | sed 's/^/          /'
        status=1
    else
        echo "  ok      not seen: $2"
    fi
}
# ask <question> - needs eyes, and is not decided here
ask() { echo "  ASK     $1"; }

serial=$(grep -o "Starting to track sonde '[A-Z0-9]*'" "$full" | tail -1 | sed "s/.*'\([A-Z0-9]*\)'.*/\1/")
echo "  hunted: ${serial:-unknown}"

case "$phase" in
C-1-APRS-ONLY)
    present "autoSelect|Starting to track sonde" "a sonde was settled on without the picker"
    present "duration=30m \(poll - latest only\)" "APRS polling uses the delta window"
    present "Triggering route calculation|Route calculated successfully" "a route exists with no BLE involved"
    absent  "📡 BLE \(" "BLE telemetry arrived - this is not the APRS-only phase"
    absent  "Already tracking" "selection returned early"
    ask     "Do the red track, the landing marker and the route all show on the map?"
    ;;
C-2-BLE-ACQUIRES)
    present "DataState: aprsFlying → liveBLEFlying" "the handover happened in flight, not at launch"
    present "📡 BLE \(" "BLE telemetry for the hunted serial"
    absent  "is a test sonde" "the hunted serial was refused as a test sonde"
    # A selection at launch is not the defect; a selection triggered BY the handover
    # is. So these two are judged only on what follows the transition.
    handover=$(grep -m1 "DataState: aprsFlying → liveBLEFlying" "$win" | cut -d, -f1)
    if [ -n "$handover" ]; then
        awk -F, -v t="$handover" '$1>=t' "$win" > "$win.after"
        mv "$win.after" "$win"
        echo "          (the two checks below start at the handover, $handover)"
    fi
    absent  "=== Starting to track sonde" "a second selection ran when BLE arrived"
    absent  "Clearing all old sonde data" "the track was cleared because a new source arrived"
    ask     "Did the track extend continuously, with no jump and no doubled leg?"
    ;;
C-3-BURST-AND-DESCENT)
    # The phase turning is the burst. "Burst point found at index" is the highest
    # point of the track so far and is printed throughout the climb, so it proves
    # nothing on its own.
    present "Phase:descending" "the detector turned the flight to descending"
    present "v=-[0-9]" "the vertical speed turned negative"
    present "Renewing route - landing point moved: yes" "the route follows the landing point"
    absent  "Landing detected - locking position" "a landing was declared during the descent"
    absent  "Landed by silence" "a landing was declared while telemetry was arriving"
    ask     "Does the descent rate in the panel match the log, and does the predicted-descent line stay drawn?"
    ;;
C-4-BLE-LOST)
    present "Telemetry LOST" "the app noticed the signal stop"
    present "DataState: liveBLEFlying → aprsFlying" "it fell back to APRS rather than to nothing"
    absent  "=== Starting to track sonde" "the hunt was redefined on BLE loss"
    absent  "Clearing all old sonde data" "collected BLE points were discarded"
    absent  "Landing detected" "silence was read as a landing"
    ask     "Is the same serial still hunted, and did the track keep its BLE points?"
    ;;
C-5-LAST-APRS)
    present "Landed by silence \(aprsStale\) - keeping predicted landing" "silence was read as landed-but-unknown"
    present "Triggering route calculation" "the route leads to the estimate"
    absent  "Landing detected - locking position" "a touchdown was confirmed from silence alone"
    ask     "Is the landing marker on the prediction rather than the last-heard position, and has it stopped moving?"
    ask     "What altitude did the last APRS frame carry? It should still be in the air."
    ;;
*)
    echo "campaign: unknown phase $phase"; exit 1 ;;
esac

if [ "$status" -eq 0 ]; then
    echo "campaign: the machine-checkable part of $phase holds. Answer the ASK lines before marking it passed."
else
    echo "campaign: $phase does NOT hold - see FAIL and MISSING above."
fi
exit "$status"

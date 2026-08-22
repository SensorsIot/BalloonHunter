#!/bin/sh
# Watches the flight and evaluates each campaign phase the moment it happens.
#
#   testing/watch-flight.sh [minutes]
#
# The phases of a real flight arrive once and cannot be replayed: the burst is a
# single second, and the last APRS frame is only recognisable afterwards. So this
# polls the phone's log, and when it sees a phase begin it runs campaign.sh for
# that phase and appends the verdict to testing/evidence/campaign-results.txt.
#
# It stops when every phase it can reach has been decided, or when the time runs
# out. What it cannot reach is the hunt itself - see the campaign notes.

set -u
here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
app_id=HB9BLA.BalloonHunter
minutes=${1:-180}
results="$here/evidence/campaign-results.txt"
mkdir -p "$here/evidence"

dev=$(xcodebuild -project "$repo/ios/BalloonHunter.xcodeproj" -scheme BalloonHunter \
      -showdestinations 2>/dev/null | grep 'platform:iOS,' | grep -v placeholder \
      | sed -n 's/.*id:\([0-9A-Fa-f-]*\),.*/\1/p' | head -1)
[ -z "$dev" ] && { echo "watch: no iPhone connected"; exit 1; }

full=$(mktemp -t balloonhunter-watch-full)
log=$(mktemp -t balloonhunter-watch)
# The log on the phone spans days. Only what happens from now on is this flight's
# phase; an earlier flight's descent sitting in the same file would fire every
# trigger the moment the watcher starts.
started=$(date +%H:%M:%S)
# And only this flight. The app may be pointed at another sonde mid-run - a
# sonde-change test does exactly that - and a serial that landed last week will
# happily supply a "Landed by silence" line that has nothing to do with the
# flight being followed.
subject=${SUBJECT:-}
pull() {
    xcrun devicectl device copy from --device "$dev" \
        --domain-type appDataContainer --domain-identifier "$app_id" --user mobile \
        --source Documents/balloonhunter.log.csv --destination "$full" >/dev/null 2>&1
    awk -F, -v t="$started" '$1>t' "$full" > "$log"
    if [ -n "$subject" ]; then
        # Keep only the stretches while the subject sonde is the hunted one.
        awk -F, -v s="$subject" '
            /Starting to track sonde/ { hunting = ($0 ~ ("\x27" s "\x27")) }
            hunting { print }
        ' "$log" > "$log.subject" 2>/dev/null
        [ -s "$log.subject" ] && mv "$log.subject" "$log"
    fi
}

record() {   # record <phase> <since>
    echo "" >> "$results"
    echo "=== $1  detected $(date +%H:%M:%S), phase from $2 ===" >> "$results"
    "$here/campaign.sh" "$1" "$2" >> "$results" 2>&1
    echo "watch: $1 evaluated -> $(tail -1 "$results")"
}

done_burst=0; done_loss=0; done_stale=0
deadline=$(( $(date +%s) + minutes * 60 ))
echo "watch: started $started${subject:+, subject $subject}, watching only lines after it, for up to $minutes min"

while [ "$(date +%s)" -lt "$deadline" ]; do
    pull
    if [ -s "$log" ]; then
        # C-3: the burst. The detector's phase turning from ascending to one of the
        # descending ones is the event. "Burst point found at index" is NOT it: the
        # track service prints that for the highest point it holds so far, which
        # during a climb is simply the newest frame.
        if [ "$done_burst" -eq 0 ]; then
            t=$(grep -E "Phase:descending" "$log" | head -1 | cut -d, -f1)
            if [ -n "$t" ]; then
                record C-3-BURST-AND-DESCENT "$t"; done_burst=1
            fi
        fi
        # C-4: BLE goes quiet while the sonde is still up.
        if [ "$done_loss" -eq 0 ]; then
            t=$(grep "DataState: liveBLEFlying → aprsFlying" "$log" | tail -1 | cut -d, -f1)
            if [ -n "$t" ]; then
                record C-4-BLE-LOST "$t"; done_loss=1
            fi
        fi
        # C-5: SondeHub loses it too.
        if [ "$done_stale" -eq 0 ]; then
            t=$(grep "Landed by silence" "$log" | tail -1 | cut -d, -f1)
            if [ -n "$t" ]; then
                record C-5-LAST-APRS "$t"; done_stale=1
            fi
        fi
    fi
    [ "$done_burst" -eq 1 ] && [ "$done_loss" -eq 1 ] && [ "$done_stale" -eq 1 ] && break
    sleep 60
done

echo "watch: finished $(date +%H:%M:%S) - burst=$done_burst bleLoss=$done_loss lastAPRS=$done_stale"
echo "watch: verdicts in testing/evidence/campaign-results.txt"

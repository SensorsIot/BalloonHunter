#!/bin/sh
# Runs the simulator tier of the workflows in test-plan.yaml and then reads the
# app's own log as the evidence for them.
#
# The UI test proves the app can be driven; the log proves what it did while being
# driven. Neither alone is a workflow result, which is why they are one command.
#
#   testing/ui-cycle.sh [-only-testing:BalloonHunterUITests/SomeClass]
#   testing/ui-cycle.sh --device [-only-testing:...]
#
# Without --device it drives a simulator, which is what the pre-push gate runs.
# With --device it drives the connected iPhone and copies the log back over
# devicectl - the same assertions, against real hardware, BLE and GPS.
#
# Exit status is the gate: non-zero if a test failed or a must_not line appears.

set -u
here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
proj="$repo/ios/BalloonHunter.xcodeproj"
app_id=HB9BLA.BalloonHunter
evidence="$here/evidence"
tier=simulator
if [ "${1:-}" = "--device" ]; then tier=device; shift; fi
[ "$#" -eq 0 ] && set -- -only-testing:BalloonHunterUITests
log=$(mktemp -t balloonhunter-log)
status=0

if [ "$tier" = "device" ]; then
    # The hardware id, not the devicectl UUID - they are different identifiers for
    # the same phone and xcodebuild accepts only the first.
    dev=$(xcodebuild -project "$proj" -scheme BalloonHunter -showdestinations 2>/dev/null \
          | grep 'platform:iOS,' | grep -v placeholder \
          | sed -n 's/.*id:\([0-9A-Fa-f-]*\),.*/\1/p' | head -1)
    if [ -z "$dev" ]; then
        echo "ui-cycle: no iPhone connected"
        exit 1
    fi
    echo "ui-cycle: iPhone $dev"
    # The device tier can afford the dwell the background workflow actually needs.
    TEST_RUNNER_BACKGROUND_SECONDS=${BACKGROUND_SECONDS:-70}
    TEST_RUNNER_SETTLE_SECONDS=${SETTLE_SECONDS:-40}
    export TEST_RUNNER_BACKGROUND_SECONDS TEST_RUNNER_SETTLE_SECONDS
    # The install is left alone here. Wiping a phone's container would take the
    # hunter's settings with it, so the device tier does not claim a cold start.
    xcodebuild -project "$proj" -scheme BalloonHunter \
        -destination "platform=iOS,arch=arm64,id=$dev" \
        "$@" -allowProvisioningUpdates build test 2>&1 \
        | grep -E "Test Case|error:|Executed [0-9]+ test|TEST SUCCEEDED|TEST FAILED" \
        | grep -v "Executed 0 tests" || status=1

    xcrun devicectl device copy from --device "$dev" \
        --domain-type appDataContainer --domain-identifier "$app_id" --user mobile \
        --source Documents/balloonhunter.log.csv --destination "$log" >/dev/null 2>&1

    # XCUITest terminates the app under test when the run ends. On the phone that
    # would leave the hunter looking at a home screen, so it is put back.
    xcrun devicectl device process launch --device "$dev" "$app_id" >/dev/null 2>&1 \
        && echo "ui-cycle: app relaunched on the phone"
else
    udid=$(xcodebuild -project "$proj" -scheme BalloonHunter -showdestinations 2>/dev/null \
           | grep 'platform:iOS Simulator' | grep 'name:iPhone' | grep -v placeholder \
           | sed -n 's/.*id:\([0-9A-Fa-f-]*\),.*/\1/p' | head -1)
    if [ -z "$udid" ]; then
        echo "ui-cycle: no iPhone simulator available"
        exit 1
    fi
    echo "ui-cycle: simulator $udid"

    # A cold start is part of what W-STARTUP claims, so the previous install goes
    # first: an app container carrying yesterday's settings is a different test.
    xcrun simctl boot "$udid" >/dev/null 2>&1
    xcrun simctl uninstall "$udid" "$app_id" >/dev/null 2>&1

    xcodebuild -project "$proj" -scheme BalloonHunter \
        -destination "platform=iOS Simulator,id=$udid" \
        "$@" CODE_SIGNING_ALLOWED=NO build test 2>&1 \
        | grep -E "Test Case|error:|Executed [0-9]+ test|TEST SUCCEEDED|TEST FAILED" \
        | grep -v "Executed 0 tests" || status=1

    container=$(xcrun simctl get_app_container "$udid" "$app_id" data 2>/dev/null)
    cp "$container/Documents/balloonhunter.log.csv" "$log" 2>/dev/null
fi

if [ ! -s "$log" ]; then
    echo "ui-cycle: the app wrote no log - there is no evidence for this run"
    exit 1
fi

mkdir -p "$evidence"
stamp=$(date +%Y%m%d-%H%M%S)
cp "$log" "$evidence/ui-cycle-$tier-$stamp.csv"
echo "ui-cycle: log kept at testing/evidence/ui-cycle-$tier-$stamp.csv ($(wc -l < "$log" | tr -d ' ') lines)"

# ---------------------------------------------------------------- log assertions
# Each one is a must_not or an observe from testing/test-plan.yaml. A line the app
# never printed is as much a failure as one it should not have.
fail() { echo "ui-cycle: FAIL - $1"; status=1; }

# The phone keeps its log across runs and its install across tests, so a startup
# claim there would be read from lines an earlier session wrote.
if [ "$tier" = "device" ]; then
    [ "$status" -eq 0 ] && echo "ui-cycle: PASS - tests green on the phone; log kept as evidence"
    exit "$status"
fi

# W-STARTUP: the resume sequence belongs to a resume, never to a launch. A run
# that includes the background workflow resumes on purpose, so the test is not
# "did a resume happen" but "did one happen before the app was ever backgrounded".
first_resume=$(grep -n "Foreground Resume Sequence Started" "$log" | head -1 | cut -d: -f1)
first_background=$(grep -n "Entered background" "$log" | head -1 | cut -d: -f1)
if [ -n "$first_resume" ]; then
    if [ -z "$first_background" ] || [ "$first_resume" -lt "$first_background" ]; then
        fail "the foreground-resume sequence ran during a cold launch"
    fi
fi
# W-STARTUP: and the symptom that race produced.
if grep -q "Polling already active, ignoring start request" "$log"; then
    fail "APRS polling was started twice - two sequences are running"
fi
# W-STARTUP: settings only, no sonde data, before a sonde is chosen.
grep -q "Step 1 - Settings only" "$log" \
    || fail "startup did not report loading settings only"
grep -q "Step 3 - Nothing injected" "$log" \
    || fail "startup did not report that nothing sonde-specific was injected"
# FSD *What runs in the background*: the poll is stopped on the way out and started
# again on the way back, and those two are a pair. The background workflow leaves
# the app away for over a minute, so both halves are visible in one run.
bg_line=$(grep -n "Entered background" "$log" | head -1 | cut -d: -f1)
resume_line=$(grep -n "Foreground Resume Sequence Started" "$log" | head -1 | cut -d: -f1)
if [ -n "$bg_line" ] && [ -n "$resume_line" ] && [ "$resume_line" -gt "$bg_line" ]; then
    polls=$(sed -n "${bg_line},${resume_line}p" "$log" | grep -c "GET https://api.v2.sondehub.org/sondes/telemetry")
    if [ "$polls" -gt 0 ]; then
        fail "$polls SondeHub polls fired while the app was in the background"
    else
        echo "  ok: no SondeHub polling while backgrounded"
    fi
    after=$(sed -n "${resume_line},\$p" "$log" | grep -c "GET https://api.v2.sondehub.org/sondes/telemetry")
    if [ "$after" -eq 0 ]; then
        fail "no SondeHub request after resuming - the app came back deaf"
    else
        echo "  ok: polling resumed ($after requests after the resume)"
    fi
    # Coming back means all four are current again, not that a fetch was issued.
    tail_after=$(sed -n "${resume_line},\$p" "$log")
    printf '%s\n' "$tail_after" | grep -q "Context read for" \
        || fail "no context read after resuming - the position and track were not refreshed"
    printf '%s\n' "$tail_after" | grep -qE "Added [0-9]+ points|TRACK EXTENT" \
        || fail "the track was not extended after resuming"
    printf '%s\n' "$tail_after" | grep -qE "Prediction completed|landing point|Landing point" \
        || fail "no landing estimate after resuming"
    printf '%s\n' "$tail_after" | grep -qE "Route calculated successfully|Route hidden" \
        || fail "the route was neither rebuilt nor deliberately hidden after resuming"
fi

# The retired persistence files must not come back.
if grep -qE "balloontrack\.json|sondeName\.json|landingPoints\.json" "$log"; then
    fail "a retired persistence file was read or written"
fi
# The whole-archive endpoint is 383 MB for one serial and must never be requested.
if grep -qE "GET https://[^,]*/sonde/[A-Z]" "$log"; then
    fail "the /sonde/{serial} archive endpoint was requested"
fi

[ "$status" -eq 0 ] && echo "ui-cycle: PASS - tests green and the log agrees"
exit "$status"

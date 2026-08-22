#!/bin/sh
# Reads the app's log off the connected iPhone, says which situation of
# test-plan.yaml is actually present, and lists the tests that situation allows.
#
#   testing/situation.sh          report only
#   testing/situation.sh --run    report, then run the device tests it allows
#
# A test run outside its situation is not a pass, it is a test that did not run -
# which is why the runner asks the phone rather than the operator.

set -u
here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
app_id=HB9BLA.BalloonHunter
log=$(mktemp -t balloonhunter-situation)

dev=$(xcodebuild -project "$repo/ios/BalloonHunter.xcodeproj" -scheme BalloonHunter \
      -showdestinations 2>/dev/null | grep 'platform:iOS,' | grep -v placeholder \
      | sed -n 's/.*id:\([0-9A-Fa-f-]*\),.*/\1/p' | head -1)
if [ -z "$dev" ]; then
    echo "situation: no iPhone connected"
    exit 1
fi

xcrun devicectl device copy from --device "$dev" \
    --domain-type appDataContainer --domain-identifier "$app_id" --user mobile \
    --source Documents/balloonhunter.log.csv --destination "$log" >/dev/null 2>&1
if [ ! -s "$log" ]; then
    echo "situation: no log on the phone - launch the app first"
    exit 1
fi

# Only the recent tail speaks for now. Older lines describe a world that has moved.
recent=$(tail -400 "$log")
last_state=$(printf '%s\n' "$recent" | grep -o "DataState: [a-zA-Z]* → [a-zA-Z]*" | tail -1 | sed 's/.*→ //')
ble_seen=$(printf '%s\n' "$recent" | grep -c "📡 BLE (")
ble_link=$(printf '%s\n' "$recent" | grep -c "SUCCESSFULLY CONNECTED")
sondes=$(printf '%s\n' "$recent" | grep -o "([0-9]* available)" | tail -1 | tr -dc '0-9')
[ -z "$sondes" ] && sondes=$(printf '%s\n' "$recent" | grep -c "APRS position received")

case "$last_state" in
    liveBLEFlying|liveBLELanded) situation=S-FLIGHT-BLE ;;
    aprsFlying)  situation=S-FLIGHT ;;
    aprsLanded)  situation=S-LANDED ;;
    *)
        if [ "$ble_seen" -gt 0 ]; then situation=S-RECEIVER
        elif [ "$sondes" -gt 0 ]; then situation=S-SONDE
        else situation=S-ANY
        fi ;;
esac

echo "situation: $situation   (state=${last_state:-none}, BLE frames=$ble_seen, receiver connected=$([ "$ble_link" -gt 0 ] && echo yes || echo "not in this window"))"

# Which capabilities the observed situation supplies, and therefore which tests
# can run. Blocked is computed there, never typed into the plan.
allowed=$(ruby "$here/lib/runnable.rb" "$here/test-plan.yaml" "$situation")

printf '%s\n' "$allowed" | while IFS="$(printf '\t')" read -r id tier verdict; do
    printf '  %-22s %-7s %s\n' "$id" "$tier" "$verdict"
done

[ "${1:-}" = "--run" ] || exit 0

runnable=$(printf '%s\n' "$allowed" | awk -F"\t" '$2=="device" && $3=="RUNNABLE" {print $1}')
if [ -z "$runnable" ]; then
    echo "situation: nothing on the device tier is runnable here"
    exit 0
fi
echo "situation: running $(printf '%s ' $runnable)"
exec "$here/ui-cycle.sh" --device

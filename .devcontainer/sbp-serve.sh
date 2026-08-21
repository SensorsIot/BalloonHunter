#!/usr/bin/env bash
# Keep the Swiss-Balloon-Predictor HTTP service alive in this container.
#
# Started by postStartCommand on every container start. Self-bootstrapping:
# a container rebuild wipes /home/dev (predictor NFR-14.3), so this script
# re-clones and re-creates the venv when they are missing, then supervises
# sbp-server, restarting it if it ever exits. Logs: /tmp/sbp-server.log.

set -u
REPO_DIR="$HOME/Swiss-Balloon-Predictor"
REPO_URL="https://github.com/SensorsIot/Swiss-Balloon-Predictor.git"
PORT=8060

if [ ! -d "$REPO_DIR/.git" ]; then
    git clone "$REPO_URL" "$REPO_DIR" || exit 1
fi

cd "$REPO_DIR" || exit 1

if [ ! -x .venv/bin/python ]; then
    python3 -m venv .venv || exit 1
    ./.venv/bin/pip install --quiet --upgrade pip
    # editable install: the venv follows the working copy, and the sbp-server
    # entry point lands on PATH inside the venv
    ./.venv/bin/pip install --quiet -e . || exit 1
fi

# the entry point may be missing if the venv predates the server module
[ -x .venv/bin/sbp-server ] || ./.venv/bin/pip install --quiet -e .

echo "$(date -u +%FT%TZ) supervisor starting on port $PORT"
while true; do
    ./.venv/bin/sbp-server --host 0.0.0.0 --port "$PORT"
    echo "$(date -u +%FT%TZ) sbp-server exited ($?); restarting in 5 s"
    sleep 5
done

#!/usr/bin/env bash
# JupyterLab with RTC on and the MCP endpoint deliberately OFF.
#
# THE EXTENSION MUST STAY DISABLED.  Installing jupyter-mcp-server into this
# venv auto-enables a Jupyter server extension -- the wheel ships a file into
# etc/jupyter/jupyter_server_config.d/ and there is no opt-in step.  With it
# loaded the MCP tools run in JUPYTER_SERVER mode, where a cell write rewrites
# the .ipynb on disk whenever the notebook is not currently open in a browser,
# behind RTC's back.  Two layers of defense: the kit's install step overwrites
# the shipped config.d file with an explicit disable, and this script passes
# the disable flag as well.  Measured: /mcp returns 404 with the flag set.
#
# RTC STATE STAYS IN THE CONTAINER, NEVER ON THE BIND MOUNT.  Both paths below
# are absolute and under /home/agent, which is overlay: they survive stop/start
# together and die with `sbx rm` together.  Splitting their lifetimes is what
# corrupts notebooks (jupyter_server_ydoc rebuilds rooms from disk with a
# hardcoded Doc(client_id=0); a stale peer plus a rebuilt room is an identity
# collision, not a merge).  Absolute paths also mean the working directory no
# longer decides where the ystore lands.
set -uo pipefail

VENV=${JUPYTER_VENV:-/opt/jupyter}
PORT=${JUPYTER_PORT:-8888}
RTC=${JUPYTER_RTC_STATE:-$HOME/.local/state/jupyter-rtc}
ROOT=${WORKSPACE_DIR:-$HOME/workspace}

mkdir -p "$RTC" "$ROOT"

# ONE TOKEN PER SANDBOX, shared with every other kit in this repo (the desktop
# uses the same string as its VNC password). Whichever kit's install step ran
# first created it. Fail loudly rather than starting an unauthenticated
# JupyterLab: an empty --IdentityProvider.token disables authentication.
TOKEN_FILE=${SBX_TOKEN_FILE:-$HOME/.sbx-token}
if [[ ! -s "$TOKEN_FILE" ]]; then
    echo "[jupyter-svc] $TOKEN_FILE is missing or empty; refusing to start" >&2
    exit 1
fi
TOKEN=$(cat "$TOKEN_FILE")

# Launch from the workspace so the server process cwd IS the notebook root.
# root_dir (below) already governs where notebooks and kernels open, but a
# JupyterLab *terminal* inherits the server process cwd when the frontend
# doesn't pin one -- and the detached startup dispatcher starts this script
# in /home/agent/workspace, an unrelated image dir.  Without this cd a
# terminal would open there while kernels open in the workspace mount.
cd "$ROOT" || exit 1

delay=1
while true; do
    start=$SECONDS
    # --ip='*' is jupyter_server's spelling for "bind all interfaces, BOTH
    # address families" (it maps '*' to an empty bind address, and Tornado
    # then binds v4 and v6).  Not 0.0.0.0: that is v4-only, and sbx publishes
    # the host port on v4 AND v6 -- macOS tries ::1 first, reaches the host
    # listener, and the forward dies inside the sandbox where nothing
    # listens on v6.  Not loopback either: the published port arrives on
    # eth0, which a loopback-bound server never sees.
    "$VENV/bin/jupyter" lab \
        --ip='*' --port="$PORT" --no-browser \
        --IdentityProvider.token="$TOKEN" \
        --ServerApp.root_dir="$ROOT" \
        --ServerApp.allow_remote_access=True \
        --ServerApp.jpserver_extensions="{'jupyter_mcp_server': False}" \
        --SQLiteYStore.db_path="$RTC/ystore.db" \
        --YDocExtension.session_store_path="$RTC/collaboration_sessions.json"
    rc=$?
    (( SECONDS - start > 30 )) && delay=1
    echo "[jupyter-svc] exited rc=$rc after $((SECONDS-start))s; restart in ${delay}s" >&2
    sleep "$delay"
    (( delay = delay * 2 )); (( delay > 60 )) && delay=60
done

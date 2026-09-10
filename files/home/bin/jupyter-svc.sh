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
TOKEN=$(cat "$HOME/.jupyter-token")

delay=1
while true; do
    start=$SECONDS
    # 0.0.0.0, or a published port forwards to nothing: publishing reaches the
    # sandbox on eth0, and a loopback-bound server never sees it.
    "$VENV/bin/jupyter" lab \
        --ip=0.0.0.0 --port="$PORT" --no-browser \
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

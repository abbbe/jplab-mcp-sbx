#!/usr/bin/env bash
# The stdio MCP server Claude Code spawns.
#
# NOTHING MAY EVER BE WRITTEN TO STDOUT HERE.  stdio is the MCP transport; a
# single stray line of output corrupts the protocol and the failure looks like
# a broken server, not a chatty script.  Diagnostics go to stderr only.
#
# Startup commands are fired by a detached dispatcher that races the interactive
# session, so JupyterLab may not be listening yet when Claude makes its first
# tool call.  Waiting here is cheaper than teaching every tool to retry.
#
# --start-new-code-sandbox false is REQUIRED: the CLI default is "True" (it
# disagrees with JupyterMCPConfig's False), and the server would otherwise spawn
# a kernel of its own at boot instead of using this Jupyter server's.
set -uo pipefail

VENV=${JUPYTER_VENV:-/opt/jupyter}
PORT=${JUPYTER_PORT:-8888}

export JUPYTER_URL="http://127.0.0.1:$PORT"
JUPYTER_TOKEN=$(cat "${SBX_TOKEN_FILE:-$HOME/.sbx-token}")
export JUPYTER_TOKEN

for _ in $(seq 1 60); do
    timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$PORT" 2>/dev/null && break
    sleep 1
done

exec "$VENV/bin/jupyter-mcp-server" start \
    --transport stdio --start-new-code-sandbox false

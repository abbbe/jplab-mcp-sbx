# jplab-mcp-sbx

A mixin kit for [Docker Sandboxes](https://docs.docker.com/) (`sbx`) that adds
**JupyterLab with real-time collaboration (RTC)** and a **correctly-wired
`jupyter-mcp-server`** to the stock `claude` agent sandbox. No custom image, no
Dockerfile, no fork of anything.

TLDR:
```console
$ git clone https://github.com/abbbe/jplab-mcp-sbx ~/.sbx/jplab-mcp-sbx
$ sbx create claude --name jlcc . --kit ~/.sbx/jplab-mcp-sbx -p 8888:8888
$ sbx run --name jlcc
...

$ sbx exec jlcc cat /home/agent/.jupyter-token
KV***mL
```

Open `http://localhost:12345/lab?token=<token>`.

## Why this exists

A data-corruption incident: a notebook was silently emptied and
`yrs-0.27.4/src/types/text.rs:845` panicked while an agent and a browser tab
were both connected to one Jupyter server.

**Root cause is upstream.** `jupyter_server_ydoc/rooms.py:261` rebuilds a room
from disk using a hardcoded `Doc(client_id=0)`. Two documents built from
*different* disk content both claim Yjs client id 0 with overlapping clocks —
an identity collision, not a merge. Reproduced 4/4 with an MCP write and 5/5
with no MCP involvement at all. `pycrdt 0.14.4`, `yrs 0.27.4` and
`jupyter-collaboration 5.0.2` are all affected; no pin helps.

This kit cannot fix upstream, but it makes the collision **structurally
unreachable** in a sandbox:

1. **The MCP server runs in `MCP_SERVER` mode over stdio** — a real CRDT peer
   with its own client id that never writes the `.ipynb` file. The unsafe
   alternative is the package's Jupyter *server extension* (`JUPYTER_SERVER`
   mode), where a cell write rewrites the file on disk whenever the notebook
   isn't open in a browser at that moment, behind RTC's back — and the file
   watcher then pulls that write into any live room wholesale, discarding
   unsaved browser edits.

   **The trap:** merely installing `jupyter-mcp-server` auto-enables that
   extension (the wheel ships a `jupyter_server_config.d` file; there is no
   opt-in and no documented opt-out). This kit disables it twice: the install
   step overwrites the shipped config file with an explicit
   `"jupyter_mcp_server": false`, and the supervised launcher passes
   `--ServerApp.jpserver_extensions="{'jupyter_mcp_server': False}"`.
   Verified: `POST /mcp` returns **404**.

2. **RTC state (ystore + session store) lives in the container overlay** at
   `/home/agent/.local/state/jupyter-rtc`, with absolute paths — never on the
   bind-mounted workspace, never in a persistent volume, never cwd-relative.
   The two stores therefore share one lifetime:
   - *stop → start*: both survive; rooms restore from the ystore
     (`loaded_from_store`) and the `client_id=0` loader never runs.
   - *rm → create*: both vanish; a stale browser tab presents an unknown
     session id, gets a clean 1003 close with `[Continue] [Reload]`, and
     nothing merges silently.

3. **One stdio MCP server per Claude Code session** sidesteps the upstream
   process-global `notebook_manager` (`server.py:363`, no lock, no caller
   identity) that all clients of one shared MCP process would share.

## Design

```
┌─ sandbox ─────────────────────────────────────────────┐
│  claude ──stdio──> jupyter-mcp.sh                     │
│                      └─> jupyter-mcp-server           │
│                          (ServerMode.MCP_SERVER)      │
│                              │ HTTP + RTC websocket   │
│                              v                        │
│  jupyter-svc.sh ──> jupyter lab :8888                 │
│                     RTC on, /mcp extension OFF        │
│                                                       │
│  /home/agent/.local/state/jupyter-rtc/   (overlay)    │
│      ystore.db + collaboration_sessions.json          │
│  $WORKSPACE_DIR  ──> host project, bind-mounted       │
└───────────────────────────────────────────────────────┘
```

- **One venv** (`/opt/jupyter`): `jupyter-mcp-server` hard-depends on
  `jupyter-collaboration>=5` → `jupyterlab>=4.6`, so a single
  `uv pip install jupyter-mcp-server` yields the whole stack. (The stock image
  is Ubuntu 26.04 → PEP 668, so a bare `pip install` fails; the venv is
  mandatory. `uv` ships in the image; PyPI is allowed by the `balanced`
  network preset.)
- **MCP registration happens at install time**, not startup: install commands
  run synchronously at create, before the CLI attaches and launches Claude.
  Startup commands are fired by a detached dispatcher that races the
  interactive session. `claude mcp add … || true` because `add` is not
  idempotent (exits 1 on an existing name).
- **`jupyter-mcp.sh` (the stdio wrapper)** reads the per-sandbox token at
  spawn time (never baked into config), waits up to 60 s for JupyterLab to
  listen, keeps stdout protocol-clean, and passes
  `--start-new-code-sandbox false` so the server uses this Jupyter's kernel
  instead of spawning its own.
- **`jupyter-svc.sh` supervises JupyterLab** (restart loop with backoff — a
  single `background: true` startup command is otherwise unsupervised) and
  binds all interfaces on **both address families** (`--ip='*'`). Not
  `0.0.0.0`: sbx publishes the host port on IPv4 *and* IPv6, macOS tries
  `::1` first, and with a v4-only listener that connection reaches the host
  forwarder but dies inside the sandbox.

## Files

```
spec.yaml                       kit spec (schemaVersion "2", kind mixin)
files/home/bin/jupyter-svc.sh   supervised JupyterLab, all safety flags
files/home/bin/jupyter-mcp.sh   stdio MCP wrapper, waits for Jupyter
```

Schema note: v2 is the current kit spec (v1 still loads but is deprecated).
The one non-obvious spelling: published ports are declared under top-level
`ports:` (entries: `container`, optional `protocol`, `name`; there is no
`hostPort` — pinning a host port is a create-time `-p` / runtime
`sbx ports --publish` operation). `sbx kit validate .` is the arbiter.

## Verification

In order, each with a pass condition (`<s>` = sandbox name):

1. **Kit valid** — `sbx kit validate .` → `VALID`, no warnings.
2. **PyPI reachable** — `sbx policy check network pypi.org` → allowed.
3. **Stack installed** —
   `sbx exec <s> /opt/jupyter/bin/python -c "import jupyterlab, jupyter_server_ydoc, pycrdt, jupyter_mcp_server; print('ok')"`
4. **THE EXTENSION IS OFF** (the single most important check):
   ```
   sbx exec <s> sh -c 'T=$(cat ~/.jupyter-token); curl -s -o /dev/null -w "%{http_code}\n" \
     -X POST -H "Authorization: token $T" http://127.0.0.1:8888/mcp'
   ```
   → **must print `404`** (without the token you get `403` from the auth
   layer, which proves nothing either way). Cross-check:
   `sbx exec <s> /opt/jupyter/bin/jupyter server extension list` must show
   `jupyter_mcp_server disabled`. Anything else means the sandbox is in the
   unsafe mode and the kit has failed its purpose.
5. **RTC on** — `/api/collaboration/session/<path>` answers;
   `~/.local/state/jupyter-rtc/ystore.db` appears once a notebook is opened.
6. **RTC state only in the container** — from the host,
   `find <project> -name 'ystore.db' -o -name 'collaboration_sessions.json'`
   returns nothing.
7. **MCP in the right mode** — `sbx exec <s> /home/agent/bin/jupyter-mcp.sh`
   logs `Server mode initialized: ServerMode.MCP_SERVER` on stderr (Ctrl-C
   out; it waits for stdio input).
8. **Claude sees it** — `claude mcp list` in the sandbox shows `jupyter`;
   `list_notebooks` / `use_notebook` work.
9. **The real regression test** — open a notebook in a host browser, have
   Claude `insert_cell`; the cell must appear in the open tab **without a
   reload**. Appearing only after reopening means the write went to disk and
   the topology is wrong.
10. **Collision structurally absent** — leave a notebook open in a host
    browser, `sbx rm` + recreate the sandbox. The tab must show
    `[Continue] [Reload]` rather than silently merging, and the host file
    must be intact.
11. **Supervision** — `sbx exec <s> pkill -f '[j]upyter-lab'` (the bracket
    keeps pkill from matching its own command line and killing the exec);
    `/lab` answers again within a few seconds.

## Out of scope

- Fixing the upstream bugs (issue drafts live in the incident workdir).
- Claude Code state persistence beyond what the stock claude kit provides.

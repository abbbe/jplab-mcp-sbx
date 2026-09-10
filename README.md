# jplab-mcp-sbx

A mixin kit for [Docker Sandboxes](https://docs.docker.com/) (`sbx`) that adds
JupyterLab with Real-Time Collaboration and a correctly-wired Datalayer 
`jupyter-mcp-server` to the stock `claude` agent sandbox.

```console
$ git clone https://github.com/abbbe/jplab-mcp-sbx ~/.sbx/jplab-mcp-sbx
$ sbx create claude --name jlcc . --kit ~/.sbx/jplab-mcp-sbx -p 8888:8888
$ sbx run --name jlcc
...
$ sbx exec jlcc cat /home/agent/.jupyter-token
KV***mL
```

Open `http://localhost:12345/lab?token=<token>`.

Note: sbx auto-stops a sandbox ~30 s after its last session disconnects —
exiting `sbx run` (Claude) counts; browser traffic, Jupyter kernels, and any
background work inside do NOT hold it open. The fix is the undocumented
`--detached` flag **at creation time** (confirmed by a Docker maintainer in
[docker/sbx-releases#75](https://github.com/docker/sbx-releases/issues/75)):

```console
$ sbx run --detached claude --name jlcc . --kit ~/.sbx/jplab-mcp-sbx -p 8888:8888
```

This marks the runtime permanently detached (`session disconnected (detached;
not auto-stopping)` in the daemon log): it keeps running with no session, and
later `sbx run --name jlcc` / `sbx exec` sessions come and go without
re-arming auto-stop. Stop it explicitly with `sbx stop jlcc`. For a sandbox
already created without the flag, either recreate it, or hold a session open
while background work runs: `sbx exec jlcc sleep infinity` (Ctrl-C when
done; auto-stop resumes 30 s later). Stopping is harmless data-wise: RTC
state survives stop/start by design and JupyterLab relaunches on every
container start — but it kills in-flight kernels and background jobs.
Related upstream issues: waking a stopped sandbox via `sbx exec` skips MCP
gateway provisioning ([#479](https://github.com/docker/sbx-releases/issues/479));
`sbx exec -d` hangs on long commands ([#505](https://github.com/docker/sbx-releases/issues/505)).

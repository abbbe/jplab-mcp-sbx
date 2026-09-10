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
exiting `sbx run` (Claude) counts, browser traffic to the published port does
not. To keep JupyterLab up without an open agent session, hold a session open:
`sbx exec jlcc sleep infinity` (Ctrl-C it when done). Stopping is harmless
here: RTC state survives stop/start by design, and the kit's startup command
relaunches JupyterLab on every container start — any session (`sbx run`,
`sbx exec`) wakes the sandbox back up.

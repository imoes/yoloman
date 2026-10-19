"""Publish the Windows agent and update it on a registered Windows host — through Bossman and the agent itself.

    .venv-host/bin/python -m bossman.tools.deploy_windows_agent [--host bossman-wintest] [--port 18780] [--skip-publish]

HOW. No WinRM, no SMB, no RDP: the host is reached the way every managed host is, through Bossman's tool API.
  1. `dotnet publish` the host (net10.0-windows, win-x64) and zip it together with packaging/*.ps1;
  2. serve the zip for a few minutes from this machine (the Windows host already reaches it — it enrolled here);
  3. the agent's own `powershell` module downloads and unpacks it and registers a ONE-SHOT scheduled task that runs
     packaging/update-agent.ps1 as SYSTEM. Detached on purpose: the update stops the agent's service, and a script
     started inside that service would be killed half-way;
  4. wait until Bossman reads the new version from the host's /healthz, then show update.log.
update-agent.ps1 reads the installed configuration (name, token, port, write gate) from the service's registry
environment, so the host keeps its identity and Bossman keeps its access.
"""

from __future__ import annotations

import argparse
import functools
import http.server
import os
import re
import shutil
import subprocess
import tempfile
import threading
import time
import zipfile
from pathlib import Path

import httpx

REPO = Path(__file__).resolve().parents[3]
AGENT = REPO / "windows-agent"
API = os.environ.get("BOSSMAN_API", "http://127.0.0.1:8123")
LAN_IP = os.environ.get("DEPLOY_LAN_IP", "192.0.2.130")


def bossman() -> httpx.Client:
    c = httpx.Client(base_url=API, timeout=300, trust_env=False)
    tok = c.post("/api/v1/auth/login", json={"username": os.environ.get("BOSSMAN_USER", "admin"),
                                             "password": os.environ.get("BOSSMAN_PASSWORD", "admin123")}).json()
    c.headers["Authorization"] = f"Bearer {tok['access_token']}"
    return c


def agent_id(c: httpx.Client, name: str) -> str:
    agents = c.get("/api/v1/agents").json()
    agents = agents.get("items", agents) if isinstance(agents, dict) else agents
    for a in agents:
        if a.get("name") == name:
            return a["id"]
    raise SystemExit(f"no agent named {name} in Bossman")


def ps(c: httpx.Client, aid: str, script: str, timeout: int = 60) -> dict:
    # timeout_seconds: Bossman waits 30 s for a tool by default; downloading 60 MB onto the host takes longer.
    r = c.post(f"/api/v1/agents/{aid}/tools/powershell", json={"params": {"script": script}, "timeout_seconds": timeout},
               timeout=timeout + 30)
    body = r.json()
    res = body.get("result", body)
    if r.status_code >= 400 or "output" not in (res.get("data") or {}):
        raise SystemExit(f"powershell on the host failed: {str(body)[:500]}")
    return res


def version() -> str:
    m = re.search(r"<Version>([^<]+)</Version>", (AGENT / "AgenticMcp.Agent.Host/AgenticMcp.Agent.Host.csproj").read_text())
    return m.group(1) if m else "0.0.0"


def publish(out: Path) -> Path:
    env = {**os.environ, "PATH": f"{Path.home()}/.dotnet:{os.environ['PATH']}", "DOTNET_CLI_TELEMETRY_OPTOUT": "1"}
    pub = out / "publish"
    subprocess.run([f"{Path.home()}/.dotnet/dotnet", "publish", str(AGENT / "AgenticMcp.Agent.Host"), "-f",
                    "net10.0-windows", "-r", "win-x64", "-c", "Release", "-o", str(pub)], check=True, env=env)
    for ps1 in (AGENT / "packaging").glob("*.ps1"):
        shutil.copy2(ps1, pub / ps1.name)
    z = out / f"agentic-mcp-agent-{version()}.zip"
    with zipfile.ZipFile(z, "w", zipfile.ZIP_DEFLATED) as zf:
        for f in pub.rglob("*"):
            if f.is_file():
                zf.write(f, f.relative_to(pub))
    return z


def serve(directory: Path, port: int) -> http.server.ThreadingHTTPServer:
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(directory))
    srv = http.server.ThreadingHTTPServer(("0.0.0.0", port), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="bossman-wintest")
    ap.add_argument("--port", type=int, default=18780)
    ap.add_argument("--same-version", action="store_true",
                    help="redeploy although the host already reports this version (the wait cannot tell old from new)")
    args = ap.parse_args()
    c = bossman()
    aid = agent_id(c, args.host)
    want = version()
    running = c.get(f"/api/v1/agents/{aid}").json().get("agent_version")
    if running == want and not args.same_version:
        # ONE NUMBER PER BUILD: under the same number the wait below sees "done" at once and reads the log while
        # the agent is still restarting — and two different builds would answer to one name (2026-10-17).
        raise SystemExit(f"{args.host} already runs {want}: bump <Version> in AgenticMcp.Agent.Host.csproj for a new "
                         "build (or pass --same-version to reinstall the same one)")
    with tempfile.TemporaryDirectory() as tmp:
        z = publish(Path(tmp))
        print(f"published {z.name} ({z.stat().st_size // 1024 // 1024} MB)")
        srv = serve(z.parent, args.port)
        try:
            url = f"http://{LAN_IP}:{args.port}/{z.name}"
            stage = rf"C:\ProgramData\agentic-mcp\update\{want}"
            res = ps(c, aid, f"""
$ErrorActionPreference = 'Stop'
$stage = '{stage}'
# Earlier stages go first: each is the package plus its unpacked copy (~200 MB), and keeping them filled the test
# host's C: to 0 bytes after 19 rollouts — the next download then failed mid-transfer (measured 2026-10-18).
Get-ChildItem (Split-Path $stage) -Directory -ErrorAction SilentlyContinue | Where-Object {{ $_.FullName -ne $stage }} |
    ForEach-Object {{ Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }}
if (Test-Path $stage) {{ Remove-Item -Recurse -Force $stage }}
New-Item -ItemType Directory -Force -Path $stage | Out-Null
$zip = Join-Path $stage 'agent.zip'
# Direct, not through the machine's corporate proxy: it answered 503 for this LAN address (measured 2026-10-17).
$wc = New-Object Net.WebClient
$wc.Proxy = $null
$wc.DownloadFile('{url}', $zip)
# .NET, not Expand-Archive: the agent's PowerShell host cannot load the Archive script module under the
# machine's execution policy (measured 2026-10-17).
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($zip, (Join-Path $stage 'agent'))
$script = Join-Path $stage 'agent\\update-agent.ps1'
# schtasks.exe, not the ScheduledTasks cmdlets: that CIM module is not loadable in the agent's PowerShell host either.
$tr = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script"
schtasks.exe /Create /TN agentic-mcp-update /SC ONCE /ST 23:59 /RU SYSTEM /RL HIGHEST /TR $tr /F | Out-Null
if ($LASTEXITCODE -ne 0) {{ throw "schtasks /Create failed: $LASTEXITCODE" }}
schtasks.exe /Run /TN agentic-mcp-update | Out-Null
if ($LASTEXITCODE -ne 0) {{ throw "schtasks /Run failed: $LASTEXITCODE" }}
"update task started: $script"
""", timeout=900)
            print([o.get("value") for o in res["data"]["output"]])
            deadline = time.time() + 600
            seen = None
            while time.time() < deadline:
                time.sleep(10)
                try:
                    a = c.get(f"/api/v1/agents/{aid}").json()
                except (httpx.HTTPError, ValueError):
                    continue
                seen = a.get("agent_version")
                if seen == want:
                    break
            log = ps(c, aid, rf"Get-Content '{stage}\agent\update.log' -Tail 15")
            print("\n".join(str(o.get("value")) for o in log["data"]["output"]))
            print(f"host reports version {seen}, wanted {want}")
            return 0 if seen == want else 1
        finally:
            srv.shutdown()


if __name__ == "__main__":
    raise SystemExit(main())

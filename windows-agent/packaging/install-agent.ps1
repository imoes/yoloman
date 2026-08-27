# Saved as UTF-8 WITH BOM on purpose: powershell.exe 5.1 reads a BOM-less file as ANSI and then
# mis-parses every non-ASCII character in this file. Do not strip it.
<#
.SYNOPSIS
    Installs (or updates) the yoloman Windows agent as a Windows service.

.DESCRIPTION
    THE DIFFERENCE BETWEEN COPIED AND INSTALLED. Until this script existed the agent was started with
    Start-Process from an interactive session: it worked, and it died with the session and did not come back
    after a reboot. A host that is managed only until it restarts is not managed.

    Idempotent by design, because the second run is the normal one: an update stops the service, replaces the
    binaries, keeps the state directory (the TLS certificate and Bossman's pinned public key live there — a new
    certificate means a re-pin on the server) and starts it again. Nothing is asked twice, and re-running with
    the same arguments changes nothing but the files.

    WHAT IT DELIBERATELY DOES NOT DO: enrol. The agent enrols itself on start when BOSSMAN_URL is set, which
    is the same path the Linux package takes — one enrolment implementation, not two.

.PARAMETER Source
    The published agent folder (or a .zip of one). Defaults to the directory this script sits in.

.PARAMETER InstallDir
    Where the binaries go. C:\Program Files\agentic-mcp by default.

.PARAMETER StateDir
    Where the TLS certificate and the Bossman pin live. Kept across updates; ProgramData by default, which is
    the location Windows intends for per-machine state that is not part of the program.

.PARAMETER Name
    The name Bossman knows this host by. Defaults to the machine name.

.PARAMETER Token
    The bearer token Bossman must present. Generated and printed once if omitted — printed, because a token
    nobody wrote down is a host nobody can poll.

.PARAMETER Listen
    host:port to bind. 0.0.0.0:8051 by default (the Go agent's port, so one firewall rule fits both).

.PARAMETER Address
    The host:port Bossman can reach. Defaults to <this machine's FQDN>:<port of Listen>.

.PARAMETER BossmanUrl
    Enrol against this Bossman on start. Omit to install a listener that waits to be registered manually.

.PARAMETER Write
    Open the write gate. WITHOUT THIS THE AGENT IS READ-ONLY, which is the right default for an install: a
    host that can be changed by whoever reaches it, before anybody has decided that, is not a safe default.

.EXAMPLE
    .\install-agent.ps1 -BossmanUrl http://bossman.example:8123 -Name web01 -Write
#>
[CmdletBinding()]
param(
    [string]$Source = $PSScriptRoot,
    [string]$InstallDir = "$env:ProgramFiles\agentic-mcp",
    [string]$StateDir = "$env:ProgramData\agentic-mcp\state",
    [string]$Name = $env:COMPUTERNAME,
    [string]$Token,
    [string]$Listen = "0.0.0.0:8051",
    [string]$Address,
    [string]$BossmanUrl,
    [switch]$Write
)

$ErrorActionPreference = "Stop"
$ServiceName = "agentic-mcp-agent"
$Exe = "AgenticMcp.Agent.Host.exe"

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        # Named rather than attempted: every step below (service, Program Files, firewall) needs it, and
        # failing halfway through leaves a host in a state neither this script nor an operator can describe.
        throw "This installer needs an elevated session: it creates a service, writes under Program Files and adds a firewall rule."
    }
}

Assert-Admin

# ---- 1. The payload ---------------------------------------------------------
if ($Source -like "*.zip") {
    $staging = Join-Path $env:TEMP ("agentic-mcp-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    Expand-Archive -Path $Source -DestinationPath $staging -Force
    $Source = $staging
}
if (-not (Test-Path (Join-Path $Source $Exe))) {
    throw "No $Exe in $Source — point -Source at a published agent folder or its .zip."
}

# ---- 2. Stop the running service, if any -----------------------------------
$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "stopping $ServiceName (was $($existing.Status))"
    if ($existing.Status -ne "Stopped") {
        Stop-Service -Name $ServiceName -Force
        # Wait for the process to actually let go of the files. A copy into a directory whose exe is still
        # mapped fails with a sharing violation, and the retry loop that would hide that is worse than waiting.
        $existing.WaitForStatus("Stopped", (New-TimeSpan -Seconds 30))
    }
}

# ---- 3. Files --------------------------------------------------------------
New-Item -ItemType Directory -Path $InstallDir, $StateDir -Force | Out-Null
Write-Host "installing to $InstallDir"
Copy-Item -Path (Join-Path $Source "*") -Destination $InstallDir -Recurse -Force

if (-not $Address) {
    $port = ($Listen -split ":")[-1]
    $fqdn = try { [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName } catch { $env:COMPUTERNAME }
    $Address = "${fqdn}:${port}"
}
if (-not $Token) {
    $bytes = New-Object byte[] 24
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $Token = -join ($bytes | ForEach-Object { $_.ToString("x2") })
    $generatedToken = $true
}

# ---- 4. The service and its environment ------------------------------------
# The environment goes on the SERVICE's registry key, not into the machine environment: these values belong to
# this service, and a machine-wide AGENT_TOKEN would be readable by everything on the host and would follow any
# other process that happens to look for it.
$env_lines = @(
    "AGENT_NAME=$Name",
    "AGENT_TOKEN=$Token",
    "AGENT_LISTEN=$Listen",
    "AGENT_ADDRESS=$Address",
    "AGENT_STATE_DIR=$StateDir",
    # ONE STRING, and the parentheses are load-bearing: in an array literal PowerShell binds the comma
    # LOOSER than +, so `"a", "AGENT_WRITE=" + $x` parses as `("a", "AGENT_WRITE=") + $x` — an array with
    # "AGENT_WRITE=" and "true" as SEPARATE entries. Measured on the real host: a `-Write` install produced
    # `AGENT_WRITE=` (empty) in the service environment, the agent came up read-only, and its tool listing
    # said "this agent's write gate is closed" for fifteen modules while the installer had printed
    # "write gate True". The installer and the host disagreed, and the installer was wrong.
    "AGENT_WRITE=$( ([bool]$Write).ToString().ToLower() )"
)
if ($BossmanUrl) { $env_lines += "BOSSMAN_URL=$BossmanUrl" }

$binaryPath = '"' + (Join-Path $InstallDir $Exe) + '"'
if ($existing) {
    Write-Host "updating the existing service definition"
    & sc.exe config $ServiceName binPath= $binaryPath start= auto | Out-Null
} else {
    Write-Host "creating service $ServiceName"
    New-Service -Name $ServiceName -BinaryPathName $binaryPath -DisplayName "yoloman agent (agentic-mcp)" `
        -Description "Reports this host to Bossman and executes its modules. Read-only unless AGENT_WRITE=true." `
        -StartupType Automatic | Out-Null
}
# RESTART ON FAILURE, three times, then leave it alone: an agent that crash-loops forever is a host that looks
# alive to the SCM and answers nothing, and the poller's "unreachable" is the honest signal for that.
& sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/15000/restart/60000 | Out-Null
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName" -Name Environment `
    -Value $env_lines -Type MultiString

# ---- 5. Start and PROVE it answers -----------------------------------------
Start-Service -Name $ServiceName
$port = ($Listen -split ":")[-1]
# PROVE IT ANSWERS, with curl.exe — which ships in system32 on Server 2019+ and does the one thing needed
# here: speak HTTPS to a certificate nobody should verify. The agent's certificate is self-signed on purpose
# (Bossman pins the public key; the trust runs the other way).
#
# Measured on the real host, and the reason this is not Invoke-RestMethod: under powershell.exe 5.1 — the
# shell that drives a Server 2022 install — the local probe failed with "the underlying connection was
# closed" against an agent that was answering perfectly (curl from another machine got 200 at the same
# moment). A probe that reports a working install as broken is worse than no probe, so the check uses the
# tool that works and falls back to pwsh's own client only where curl.exe is absent.
$probe = $null
$curl = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source
foreach ($attempt in 1..15) {
    Start-Sleep -Seconds 2
    try {
        if ($curl) {
            $body = & $curl -sk --max-time 6 "https://127.0.0.1:$port/healthz" 2>$null
            if ($LASTEXITCODE -eq 0 -and $body) { $probe = $body | ConvertFrom-Json; break }
        } elseif ($PSVersionTable.PSVersion.Major -ge 6) {
            $probe = Invoke-RestMethod -Uri "https://127.0.0.1:$port/healthz" -SkipCertificateCheck -TimeoutSec 5
            break
        } else {
            # No curl.exe and no pwsh: the port is the most this shell can honestly establish, and the
            # message below says exactly that rather than claiming a health check happened.
            $tcp = Test-NetConnection -ComputerName 127.0.0.1 -Port $port -InformationLevel Quiet -ErrorAction SilentlyContinue
            if ($tcp) { $probe = [pscustomobject]@{ status = "listening (port only — no HTTPS client on this host)"; agent = $Name }; break }
        }
    } catch { }
}

$svc = Get-Service -Name $ServiceName
if (-not $probe) {
    # The service being "Running" is not evidence that the agent answers — this is the same
    # "the exit code is a claim, the state is the evidence" rule the modules follow.
    throw ("service $ServiceName is $($svc.Status) but https://127.0.0.1:$port/healthz did not answer. " +
           "Look at the Application event log (source $ServiceName) and at $StateDir.")
}

Write-Host ""
Write-Host "installed: $ServiceName is $($svc.Status), /healthz says $($probe.status) as '$($probe.agent)'"
Write-Host "  binaries   $InstallDir"
Write-Host "  state      $StateDir   (TLS certificate + Bossman pin — kept across updates)"
Write-Host "  address    $Address    (what Bossman will poll)"
Write-Host "  write gate $([bool]$Write)"
if ($generatedToken) {
    # Printed once, and only when we made it up: Bossman needs it to poll this host, and a generated token
    # nobody recorded means re-installing to get a new one.
    Write-Host ""
    Write-Host "  AGENT_TOKEN (generated, record it now): $Token"
}
if (-not $BossmanUrl) {
    Write-Host ""
    Write-Host "  No -BossmanUrl given: this agent listens but has not enrolled. Register it in Bossman with"
    Write-Host "  the address and token above, or re-run with -BossmanUrl to let it enrol itself."
}

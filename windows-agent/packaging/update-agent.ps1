# Saved as UTF-8 WITH BOM on purpose (powershell.exe 5.1 reads a BOM-less file as ANSI). Do not strip it.
<#
.SYNOPSIS
    Updates an installed agent IN PLACE with the configuration it already has.

.DESCRIPTION
    install-agent.ps1 is idempotent for the SAME arguments — but an update run without them would generate a new
    token (Bossman could no longer poll the host) and default the name, port and write gate. This script reads the
    values the running service was installed with from its own registry Environment and passes them on unchanged,
    so an update replaces binaries and nothing else.

    It stops the agent's own service. Started by the agent itself it would kill itself half-way, so it is meant to
    run detached — scripts/deploy-windows-agent.sh starts it as a one-shot scheduled task under SYSTEM — and it
    writes what it did to update.log next to itself.

.PARAMETER Source
    The new published agent folder (or its .zip). Defaults to the directory this script sits in.
#>
[CmdletBinding()]
param([string]$Source)
# Not as the parameter default: started by schtasks with -File, $PSScriptRoot was empty when the default was
# evaluated and install-agent.ps1 got an empty -Source (measured on bossman-wintest, 2026-10-17). In the body it is set.
if (-not $Source) { $Source = $PSScriptRoot }
if (-not $Source) { $Source = Split-Path -Parent $MyInvocation.MyCommand.Path }

$ErrorActionPreference = "Stop"
$log = Join-Path $PSScriptRoot "update.log"
Start-Transcript -Path $log -Append | Out-Null
try {
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\agentic-mcp-agent"
    if (-not (Test-Path $key)) { throw "agentic-mcp-agent is not installed — use install-agent.ps1 for a first install." }
    $env_lines = (Get-ItemProperty $key).Environment
    $cfg = @{}
    foreach ($line in $env_lines) {
        $k, $v = $line -split "=", 2
        $cfg[$k] = $v
    }
    $params = @{
        Source   = $Source
        Name     = $cfg["AGENT_NAME"]
        Token    = $cfg["AGENT_TOKEN"]
        Listen   = $cfg["AGENT_LISTEN"]
        Address  = $cfg["AGENT_ADDRESS"]
        StateDir = $cfg["AGENT_STATE_DIR"]
    }
    if ($cfg["BOSSMAN_URL"]) { $params["BossmanUrl"] = $cfg["BOSSMAN_URL"] }
    if ($cfg["AGENT_WRITE"] -eq "true") { $params["Write"] = $true }
    Write-Host "updating with the installed configuration (name $($params.Name), listen $($params.Listen), write $($cfg['AGENT_WRITE']))"
    & (Join-Path $PSScriptRoot "install-agent.ps1") @params
    Write-Host "update finished"
}
catch {
    Write-Host "UPDATE FAILED: $($_.Exception.Message)"
    throw
}
finally {
    Stop-Transcript | Out-Null
}

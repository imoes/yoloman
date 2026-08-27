# Saved as UTF-8 WITH BOM on purpose: powershell.exe 5.1 reads a BOM-less file as ANSI and then
# mis-parses every non-ASCII character in this file. Do not strip it.
<#
.SYNOPSIS
    Removes the yoloman Windows agent service.

.DESCRIPTION
    Stops and deletes the service, removes the inbound firewall rule and the binaries. THE STATE DIRECTORY IS
    KEPT unless -Purge is given, because it holds the TLS certificate and Bossman's pinned public key: a
    reinstall that reuses them is invisible to the server, while a fresh certificate needs a re-pin. Removing
    state by default would make "reinstall the agent" quietly mean "re-enrol the host".

    What it does NOT do is unregister the host in Bossman. An agent removed from a host and a host removed from
    the fleet are two decisions, and only one of them is being taken here — a vanished agent shows up as
    unreachable, which is the truth.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = "$env:ProgramFiles\agentic-mcp",
    [string]$StateDir = "$env:ProgramData\agentic-mcp\state",
    [switch]$Purge
)

$ErrorActionPreference = "Stop"
$ServiceName = "agentic-mcp-agent"

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
    if ($svc.Status -ne "Stopped") {
        Stop-Service -Name $ServiceName -Force
        $svc.WaitForStatus("Stopped", (New-TimeSpan -Seconds 30))
    }
    & sc.exe delete $ServiceName | Out-Null
    Write-Host "service $ServiceName removed"
} else {
    Write-Host "no service $ServiceName — nothing to stop"
}

Get-NetFirewallRule -DisplayName "agentic-mcp agent*" -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-NetFirewallRule -Name $_.Name; Write-Host "firewall rule '$($_.DisplayName)' removed" }

if (Test-Path $InstallDir) {
    Remove-Item -Path $InstallDir -Recurse -Force
    Write-Host "binaries removed from $InstallDir"
}

if ($Purge) {
    if (Test-Path $StateDir) {
        Remove-Item -Path $StateDir -Recurse -Force
        Write-Host "state removed from $StateDir — the next install mints a new certificate and needs a re-pin in Bossman"
    }
} elseif (Test-Path $StateDir) {
    Write-Host "state KEPT in $StateDir (TLS certificate + Bossman pin). Use -Purge to remove it."
}

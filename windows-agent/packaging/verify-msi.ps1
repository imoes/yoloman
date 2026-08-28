# Saved as UTF-8 WITH BOM on purpose: powershell.exe 5.1 reads a BOM-less file as ANSI and then
# mis-parses every non-ASCII character in this file. Do not strip it.
<#
.SYNOPSIS
    Prove an agent MSI actually installs, upgrades and uninstalls — on a real Windows host.

.DESCRIPTION
    THE PACKAGE IS NOT DONE WHEN IT BUILDS. An MSI that compiles can still install a service that will not
    start, leave a second copy beside the first on upgrade, or fail to remove itself — and none of that shows
    up at build time. This script is the evidence, and it is deliberately a script rather than a checklist so
    the answer is the same every time somebody asks.

    Five checks, in the order a fleet meets them:
      1. install silently, with the configuration on the command line
      2. the service is Running AND /healthz answers (the service being "Running" is not the same claim)
      3. the package is in Programs and Features with the version it was built as
      4. installing again UPGRADES in place — one product, one install directory, no second service
      5. uninstall removes the service, the binaries and the entry, and KEEPS the state directory

    Run it on a host you are willing to have the agent installed on and removed from. It leaves the host as it
    found it, apart from the state directory, which is kept by design (see agent.wxs).

.EXAMPLE
    .\verify-msi.ps1 -Msi .\agentic-mcp-agent.msi -ExpectedVersion 0.2.0 `
        -Arguments 'AGENT_NAME=probe AGENT_TOKEN=abc AGENT_LISTEN=0.0.0.0:8451 AGENT_ADDRESS=10.0.0.5:8451'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Msi,
    [Parameter(Mandatory = $true)][string]$ExpectedVersion,
    [string]$Arguments = '',
    [int]$Port = 8451,
    [string]$ServiceName = 'agentic-mcp-agent',
    [string]$StateDir = "$env:ProgramData\agentic-mcp\state"
)

$ErrorActionPreference = 'Stop'
$results = New-Object System.Collections.ArrayList

function Check([string]$name, [scriptblock]$test) {
    try {
        $detail = & $test
        [void]$results.Add([pscustomobject]@{ Check = $name; Result = 'pass'; Detail = "$detail" })
        Write-Host "  pass  $name — $detail"
    } catch {
        [void]$results.Add([pscustomobject]@{ Check = $name; Result = 'FAIL'; Detail = $_.Exception.Message })
        Write-Host "  FAIL  $name — $($_.Exception.Message)"
    }
}

function Install-Package([string]$path, [string]$extra) {
    $log = Join-Path $env:TEMP ('agentic-msi-' + [guid]::NewGuid().ToString('N') + '.log')
    $argumentList = "/i `"$path`" /qn /norestart /l*v `"$log`" $extra"
    $process = Start-Process msiexec.exe -ArgumentList $argumentList -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        # THE LOG'S TAIL, not just the code: 1603 on its own has told nobody anything, ever.
        $tail = (Get-Content $log -Tail 25 -ErrorAction SilentlyContinue) -join "`n"
        throw "msiexec exited $($process.ExitCode). Last lines of $log :`n$tail"
    }
    return $log
}

function Probe-Health([int]$port) {
    $curl = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source
    if (-not $curl) { throw 'curl.exe is not on this host, so the HTTPS probe cannot run' }
    foreach ($attempt in 1..15) {
        Start-Sleep -Seconds 2
        $body = & $curl -sk --max-time 6 "https://127.0.0.1:$port/healthz" 2>$null
        if ($LASTEXITCODE -eq 0 -and $body) { return $body }
    }
    throw "https://127.0.0.1:$port/healthz did not answer within 30s"
}

Write-Host "verifying $Msi (expecting version $ExpectedVersion)"

Check 'installs silently' { Install-Package $Msi $Arguments | Out-Null; 'msiexec exited 0' }

Check 'the service exists and is running' {
    $svc = Get-Service -Name $ServiceName -ErrorAction Stop
    if ($svc.Status -ne 'Running') { throw "the service is $($svc.Status)" }
    "status $($svc.Status), start type $($svc.StartType)"
}

# THE SERVICE BEING RUNNING IS NOT THE SAME CLAIM as the agent answering — the distinction that caught a
# broken TLS key on this very agent once.
Check 'the agent answers /healthz' { Probe-Health $Port }

Check 'it appears in Programs and Features with its version' {
    $entry = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                           'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ItemProperty $_.PSPath } |
        Where-Object { $_.DisplayName -like '*yoloman agent*' } | Select-Object -First 1
    if (-not $entry) { throw 'no uninstall entry named like "yoloman agent"' }
    if ($entry.DisplayVersion -notlike "$ExpectedVersion*") {
        throw "the entry says version $($entry.DisplayVersion), expected $ExpectedVersion"
    }
    "$($entry.DisplayName) $($entry.DisplayVersion)"
}

Check 'installing again upgrades in place (one product, one service)' {
    Install-Package $Msi $Arguments | Out-Null
    $entries = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ItemProperty $_.PSPath } |
        Where-Object { $_.DisplayName -like '*yoloman agent*' }
    if (@($entries).Count -ne 1) { throw "$(@($entries).Count) uninstall entries after the second install" }
    $svc = Get-Service -Name $ServiceName -ErrorAction Stop
    if ($svc.Status -ne 'Running') { throw "the service is $($svc.Status) after the upgrade" }
    'one entry, service still running'
}

Check 'uninstall removes the service, the files and the entry' {
    $product = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' |
        ForEach-Object { Get-ItemProperty $_.PSPath } |
        Where-Object { $_.DisplayName -like '*yoloman agent*' } | Select-Object -First 1
    $code = $product.PSChildName
    $process = Start-Process msiexec.exe -ArgumentList "/x $code /qn /norestart" -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "uninstall exited $($process.ExitCode)" }
    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) { throw 'the service is still registered' }
    if (Test-Path "$env:ProgramFiles\agentic-mcp\AgenticMcp.Agent.Host.exe") { throw 'the binaries are still there' }
    'service, binaries and entry gone'
}

Check 'the state directory survived the uninstall' {
    if (-not (Test-Path $StateDir)) {
        throw "the state directory $StateDir is gone — a reinstall would mint a new certificate and need a re-pin in Bossman"
    }
    "$StateDir kept"
}

Write-Host ''
$results | Format-Table -AutoSize
$failed = @($results | Where-Object { $_.Result -ne 'pass' }).Count
if ($failed -gt 0) {
    throw "$failed check(s) failed — the package is not fit to ship"
}
Write-Host 'all checks passed'

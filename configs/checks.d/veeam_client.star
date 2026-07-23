_STATUS_STATE = {
    "Success": "OK",
    "Warning": "WARN",
    "Failed": "CRIT",
    "InProgress": "OK",
    "Pending": "OK",
}

_RUNNING = ["InProgress", "Pending"]

_PS_SCRIPT = """$ErrorActionPreference = 'SilentlyContinue'
try { Add-PSSnapin VeeamPSSnapIn } catch {}
try { Import-Module Veeam.Backup.PowerShell } catch {}
$now = Get-Date
$r = New-Object System.Collections.ArrayList
$vbrCmd = Get-Command Get-VBRJob -ErrorAction SilentlyContinue
if ($vbrCmd) {
    foreach ($j in @(Get-VBRJob -ErrorAction SilentlyContinue)) {
        $s = $j | Get-VBRJobSession | Sort-Object CreationTime -Descending | Select-Object -First 1
        if (-not $s) { continue }
        $bs = $s.BackupStats
        $tsz = if ($bs -and $null -ne $bs.DataSize) { [long]$bs.DataSize } else { [long]0 }
        $o = @{ Status = $s.State.ToString(); JobName = $j.Name; TotalSizeByte = $tsz }
        if ($bs -and $bs.ReadSize) { $o['ReadSizeByte'] = [long]$bs.ReadSize }
        if ($bs -and $bs.TransferSize) { $o['TransferedSizeByte'] = [long]$bs.TransferSize }
        $spd = $s.Progress.AvgSpeed
        if ($spd -and $spd -gt 0) { $o['AvgSpeedBps'] = [long]$spd }
        $et = $s.EndTime
        if ($et -and $et.Year -gt 1900) {
            $o['LastBackupAge'] = ($now - $et).TotalSeconds
            $dur = $s.Progress.Duration
            if ($dur.TotalSeconds -gt 0) {
                $o['DurationDDHHMMSS'] = ('{0}:{1}:{2}:{3}' -f $dur.Days, $dur.Hours, $dur.Minutes, $dur.Seconds)
            }
        }
        $o['BackupServer'] = $env:COMPUTERNAME
        $null = $r.Add($o)
    }
}
$arr = @($r.ToArray())
if ($arr.Count -eq 0) {
    Write-Output '[]'
} elseif ($arr.Count -eq 1) {
    Write-Output ('[' + ($arr[0] | ConvertTo-Json -Compress) + ']')
} else {
    Write-Output ($arr | ConvertTo-Json -Compress)
}"""

def _fmt_timespan(secs):
    secs = int(secs)
    days = secs // 86400
    rem = secs % 86400
    hours = rem // 3600
    rem = rem % 3600
    mins = rem // 60
    s2 = rem % 60
    if days > 0:
        return "%d days %d hours" % (days, hours)
    if hours > 0:
        return "%d hours %d minutes" % (hours, mins)
    if mins > 0:
        return "%d minutes %d seconds" % (mins, s2)
    return "%d seconds" % s2

def _fmt_bytes(n):
    n = float(n)
    if n < 1024.0:
        return "%f B" % n
    if n < 1048576.0:
        return "%f KB" % (n / 1024.0)
    if n < 1073741824.0:
        return "%f MB" % (n / 1048576.0)
    return "%f GB" % (n / 1073741824.0)

def _collect(ctx):
    res = ctx.run(
        ["powershell.exe", "-NonInteractive", "-NoProfile", "-Command", _PS_SCRIPT],
        mutates=False,
        ok_codes=[0, 1],
    )
    out = res.stdout.strip()
    if not out:
        return []
    if not (out.startswith("[") or out.startswith("{")):
        return []
    parsed = json.decode(out)
    if type(parsed) == "dict":
        return [parsed]
    return parsed

def main(ctx, params):
    if params.get("_discover"):
        jobs = _collect(ctx)
        disc = [
            {
                "item": j.get("JobName", ""),
                "params": {"age": [108000, 172800]},
                "metrics": ["totalsize", "readsize", "transferredsize", "duration", "avgspeed"],
            }
            for j in jobs
            if j.get("JobName", "") != ""
        ]
        return {
            "changed": False,
            "msg": "discovered %d backup jobs" % len(disc),
            "data": {"discovery": disc},
        }

    item = params.get("item", "")
    jobs = _collect(ctx)

    data = None
    for j in jobs:
        if j.get("JobName", "") == item:
            data = j
            break

    if data == None:
        return {
            "changed": False,
            "msg": "Client not found in agent output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    status = data.get("Status", "Unknown")
    state = _STATUS_STATE.get(status, "UNKNOWN")
    infotexts = ["Status: %s" % status]
    metrics = {}

    total_size = data.get("TotalSizeByte", 0)
    if total_size == None:
        total_size = 0
    total_size = int(float(total_size))
    metrics["totalsize"] = total_size

    size_info = [_fmt_bytes(total_size)]
    size_legend = ["total"]

    read_size = data.get("ReadSizeByte")
    if read_size != None:
        read_size = int(float(read_size))
        metrics["readsize"] = read_size
        size_info.append(_fmt_bytes(read_size))
        size_legend.append("read")

    transferred = data.get("TransferedSizeByte")
    if transferred != None:
        transferred = int(float(transferred))
        metrics["transferredsize"] = transferred
        size_info.append(_fmt_bytes(transferred))
        size_legend.append("transferred")

    infotexts.append("Size (%s): %s" % ("/".join(size_legend), "/ ".join(size_info)))

    if status not in _RUNNING:
        age_raw = data.get("LastBackupAge")
        if age_raw != None:
            age = float(age_raw)
            age_levels = params.get("age", [108000, 172800])
            warn_age = float(age_levels[0])
            crit_age = float(age_levels[1])
            age_label = ""
            levels_str = ""
            if age >= crit_age:
                state = "CRIT"
                age_label = "(!!)"
                levels_str = " (Warn/Crit: %s/%s)" % (_fmt_timespan(warn_age), _fmt_timespan(crit_age))
            elif age >= warn_age:
                if state != "CRIT":
                    state = "WARN"
                age_label = "(!)"
                levels_str = " (Warn/Crit: %s/%s)" % (_fmt_timespan(warn_age), _fmt_timespan(crit_age))
            infotexts.append("Last backup: %s ago%s%s" % (_fmt_timespan(age), age_label, levels_str))
        else:
            state = "CRIT"
            infotexts.append("No complete Backup(!!)")

        dur_raw = data.get("DurationDDHHMMSS")
        if dur_raw != None:
            parts = dur_raw.split(":")
            if len(parts) == 4:
                duration = int(parts[3]) + int(parts[2]) * 60 + int(parts[1]) * 3600 + int(parts[0]) * 86400
                infotexts.append("Duration: %s" % _fmt_timespan(duration))
                metrics["duration"] = duration

    avg_speed = data.get("AvgSpeedBps")
    if avg_speed != None:
        avg_speed = int(float(avg_speed))
        metrics["avgspeed"] = avg_speed
        infotexts.append("Average Speed: %s/s" % _fmt_bytes(avg_speed))

    backup_server = data.get("BackupServer")
    if backup_server != None:
        infotexts.append("Backup server: %s" % backup_server)

    return {
        "changed": False,
        "msg": ", ".join(infotexts),
        "data": {"state": state, "metrics": metrics, "details": ""},
    }
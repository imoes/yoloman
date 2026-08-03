# -*- starlark -*-
# Checkmk check translation: hyperv_vm_checkpoints -> read-only Starlark check

SECONDS_PER_DAY = 86400

_DEFAULT_AGE_OLDEST = (10 * SECONDS_PER_DAY, 20 * SECONDS_PER_DAY)
_DEFAULT_AGE = None

def _probe_hyperv_present(ctx):
    cmd = "Get-Module -ListAvailable Hyper-V 2>$null | Measure-Object | %{$_.Count}"
    res = ctx.run(
        ["powershell", "-NoProfile", "-NonInteractive", "-Command", cmd],
        mutates=False,
    )
    if res.rc == 0 and res.stdout.strip() != "" and res.stdout.strip() != "0":
        return True
    return False

def _list_checkpoints(ctx):
    cmd = "$snaps = Get-VM | % { Get-VMSnapshot -VMName $_.Name -ErrorAction SilentlyContinue }; $snaps | % { $name = $_.Name; $path = $_.Path; $created = $_.CreationTime.ToString('yyyy-MM-dd HH:mm:ss'); $parent = if ($_.Parent) { $_.Parent.Name } else { '' }; $name + '|' + $path + '|' + $created + '|' + $parent }"
    res = ctx.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", cmd], mutates=False)
    if res.rc != 0:
        return []
    checkpoints = []
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split("|")
        if len(parts) < 4:
            continue
        cp = {
            "name": parts[0],
            "path": parts[1],
            "created": parts[2],
            "parent": parts[3],
        }
        checkpoints.append(cp)
    return checkpoints

def _parse_timestamp(created_str):
    parts = created_str.strip().split(" ")
    if len(parts) < 2:
        return None
    date_part = parts[0]
    time_part = parts[1]

    time_components = time_part.split(":")
    if len(time_components) < 2:
        return None
    hour = int(time_components[0]) if time_components[0].isdigit() else None
    minute = int(time_components[1]) if time_components[1].isdigit() else None
    second = 0
    if len(time_components) >= 3 and time_components[2].isdigit():
        second = int(time_components[2])
    if hour == None or minute == None:
        return None

    if "-" in date_part:
        dparts = date_part.split("-")
        if len(dparts) == 3:
            if len(dparts[0]) == 4:
                year = int(dparts[0]) if dparts[0].isdigit() else None
                month = int(dparts[1]) if dparts[1].isdigit() else None
                day = int(dparts[2]) if dparts[2].isdigit() else None
                ts = _to_epoch(year, month, day, hour, minute, second)
                if ts != None:
                    return ts
            else:
                month = int(dparts[0]) if dparts[0].isdigit() else None
                day = int(dparts[1]) if dparts[1].isdigit() else None
                year = int(dparts[2]) if dparts[2].isdigit() else None
                ts = _to_epoch(year, month, day, hour, minute, second)
                if ts != None:
                    return ts

    if "/" in date_part:
        dparts = date_part.split("/")
        if len(dparts) == 3:
            first = int(dparts[0]) if dparts[0].isdigit() else None
            second_d = int(dparts[1]) if dparts[1].isdigit() else None
            third = int(dparts[2]) if dparts[2].isdigit() else None
            month = first
            day = second_d
            year = third
            ts = _to_epoch(year, month, day, hour, minute, second)
            if ts != None:
                return ts
            day = first
            month = second_d
            year = third
            ts = _to_epoch(year, month, day, hour, minute, second)
            if ts != None:
                return ts
            year = first
            month = second_d
            day = third
            ts = _to_epoch(year, month, day, hour, minute, second)
            if ts != None:
                return ts

    if "." in date_part:
        dparts = date_part.split(".")
        if len(dparts) == 3:
            day = int(dparts[0]) if dparts[0].isdigit() else None
            month = int(dparts[1]) if dparts[1].isdigit() else None
            year = int(dparts[2]) if dparts[2].isdigit() else None
            ts = _to_epoch(year, month, day, hour, minute, second)
            if ts != None:
                return ts

    return None

def _to_epoch(year, month, day, hour, minute, second):
    if year == None or month == None or day == None or hour == None or minute == None:
        return None
    if year < 1900 or year > 2100:
        return None
    if month < 1 or month > 12:
        return None
    if day < 1 or day > 31:
        return None
    if hour < 0 or hour > 23:
        return None
    if minute < 0 or minute > 59:
        return None
    if second < 0 or second > 59:
        return None

    days_in_month = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    if year % 4 == 0 and (year % 100 != 0 or year % 400 == 0):
        days_in_month[1] = 29

    total_days = 0
    for y in range(1970, year):
        if y % 4 == 0 and (y % 100 != 0 or y % 400 == 0):
            total_days += 366
        else:
            total_days += 365

    for m in range(1, month):
        total_days += days_in_month[m - 1]

    total_days += (day - 1)

    epoch = total_days * 86400 + hour * 3600 + minute * 60 + second
    return epoch

def _get_current_time(ctx):
    res = ctx.run(["date", "+%s"], mutates=False)
    if res.rc == 0:
        ts_str = res.stdout.strip()
        if ts_str.isdigit():
            return int(ts_str)
    return None

def _check_levels(value, levels, metric_name, label):
    state = "OK"
    if levels != None:
        warn = levels[0]
        crit = levels[1]
        if value >= crit:
            state = "CRIT"
        elif value >= warn:
            state = "WARN"
    return {"state": state, "metric": metric_name, "value": value, "label": label}

def _render_timespan(seconds):
    days = seconds // SECONDS_PER_DAY
    remainder = seconds % SECONDS_PER_DAY
    hours = remainder // 3600
    remainder = remainder % 3600
    minutes = remainder // 60
    secs = remainder % 60
    if days > 0:
        return "%dD %d:%d:%d" % (days, hours, minutes, secs)
    return "%d:%d:%d" % (hours, minutes, secs)

def main(ctx, params):
    if params.get("_discover"):
        if not _probe_hyperv_present(ctx):
            return {"changed": False, "msg": "discovered 0 items (Hyper-V not present)",
                    "data": {"discovery": []}}

        checkpoints = _list_checkpoints(ctx)
        if len(checkpoints) == 0:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}

        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [
                {
                    "item": "",
                    "params": {
                        "age": _DEFAULT_AGE,
                        "age_oldest": _DEFAULT_AGE_OLDEST,
                    },
                    "metrics": ["age", "age_oldest"],
                },
            ]},
        }

    if not _probe_hyperv_present(ctx):
        return {
            "changed": False,
            "msg": "No Hyper-V VM checkpoints data found (Hyper-V not present)",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Hyper-V PowerShell module not found on this host",
            },
        }

    checkpoints = _list_checkpoints(ctx)

    if len(checkpoints) == 0:
        return {
            "changed": False,
            "msg": "Checkpoints: 0",
            "data": {
                "state": "OK",
                "metrics": {},
                "details": "No Hyper-V VM checkpoints found",
            },
        }

    current_time = _get_current_time(ctx)
    if current_time == None:
        return {
            "changed": False,
            "msg": "Unable to determine current time",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Could not read system time",
            },
        }

    checkpoint_data = []
    for cp in checkpoints:
        if "created" not in cp or not cp["created"]:
            continue
        ts = _parse_timestamp(cp["created"])
        if ts == None:
            continue
        age_seconds = current_time - ts
        if age_seconds < 0:
            age_seconds = 0
        checkpoint_data.append((cp["name"], age_seconds))

    if len(checkpoint_data) == 0:
        return {
            "changed": False,
            "msg": "No valid checkpoint dates found",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "Could not parse any checkpoint creation timestamps",
            },
        }

    checkpoint_data = sorted(checkpoint_data, key=lambda x: x[1])

    newest_name = checkpoint_data[0][0]
    newest_age = checkpoint_data[0][1]

    oldest_name = checkpoint_data[len(checkpoint_data) - 1][0]
    oldest_age = checkpoint_data[len(checkpoint_data) - 1][1]

    age_levels = params.get("age", _DEFAULT_AGE)
    age_oldest_levels = params.get("age_oldest")

    if age_oldest_levels == None:
        age_oldest_levels = _DEFAULT_AGE_OLDEST

    newest_result = _check_levels(newest_age, age_levels, "age",
                                  "Last (%s)" % newest_name)
    oldest_result = _check_levels(oldest_age, age_oldest_levels, "age_oldest",
                                  "Oldest (%s)" % oldest_name)

    all_states = [newest_result["state"], oldest_result["state"]]
    if "CRIT" in all_states:
        overall_state = "CRIT"
    elif "WARN" in all_states:
        overall_state = "WARN"
    else:
        overall_state = "OK"

    newest_rendered = _render_timespan(newest_age)
    oldest_rendered = _render_timespan(oldest_age)

    summary = "Checkpoints: %d, Last (%s): %s, Oldest (%s): %s" % (
        len(checkpoint_data),
        newest_name, newest_rendered,
        oldest_name, oldest_rendered,
    )

    details = "Checkpoint count: %d\n" % len(checkpoint_data)
    details += "Newest checkpoint: %s (age: %s)\n" % (newest_name, newest_rendered)
    details += "Oldest checkpoint: %s (age: %s)" % (oldest_name, oldest_rendered)

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": overall_state,
            "metrics": {"age": newest_age, "age_oldest": oldest_age},
            "details": details,
        },
    }
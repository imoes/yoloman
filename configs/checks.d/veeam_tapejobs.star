def _get_tape_jobs(ctx, params):
    ps_res = ctx.run(
        ["pwsh", "-Command", "Get-Module -ListAvailable -Name Veeam.Backup"],
        mutates=False,
    )
    if ps_res.rc != 0:
        ps_res = ctx.run(
            ["powershell", "-Command", "Get-Module -ListAvailable -Name Veeam.Backup"],
            mutates=False,
        )
        if ps_res.rc != 0:
            return None

    ps_query = (
        "Import-Module Veeam.Backup; " +
        "$jobs = Get-VBRTapeJob; " +
        "foreach ($j in $jobs) { " +
        "$last = Get-VBRTapeJob -Name $j.Name | Get-VBRSession -Last; " +
        "$result = if ($last) { $last.Result.ToString() } else { 'None' }; " +
        "$state = if ($last) { $last.State.ToString() } else { 'Idle' }; " +
        "$j.Name + '|' + $result + '|' + $state " +
        "}"
    )
    res = ctx.run(["pwsh", "-Command", ps_query], mutates=False)
    if res.rc != 0:
        res = ctx.run(["powershell", "-Command", ps_query], mutates=False)
        if res.rc != 0:
            return None

    jobs = []
    for line in res.stdout.splitlines():
        parts = line.strip().split("|", 2)
        if len(parts) < 3:
            continue
        name, result, state = parts
        jobs.append({
            "name": name,
            "job_id": name,
            "last_result": result,
            "last_state": state,
        })
    return jobs

_BACKUP_STATE = {
    "Success": "OK",
    "Warning": "WARN",
    "Failed": "CRIT",
}

_DAY = 3600 * 24

def main(ctx, params):
    is_discover = params.get("_discover", False)

    if is_discover:
        jobs = _get_tape_jobs(ctx, params)
        if jobs == None:
            return {"changed": False, "msg": "VEEAM Backup not installed",
                    "data": {"discovery": []}}
        discovery = []
        for job in jobs:
            discovery.append({
                "item": job["name"],
                "params": {"levels_upper": params.get("levels_upper", (_DAY, 2 * _DAY))},
                "metrics": ["running_time"],
            })
        return {"changed": False, "msg": "discovered %d items" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    jobs = _get_tape_jobs(ctx, params)
    if jobs == None:
        return {"changed": False, "msg": "VEEAM Backup not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    job = None
    for j in jobs:
        if j["name"] == item:
            job = j
            break

    if job == None:
        return {"changed": False, "msg": "no such veeam tape job: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    last_result = job["last_result"]
    last_state = job["last_state"]
    levels = params.get("levels_upper", (_DAY, 2 * _DAY))
    warn_level = levels[0] if len(levels) > 0 else _DAY
    crit_level = levels[1] if len(levels) > 1 else 2 * _DAY

    if last_result != "None" or last_state not in ("Working", "Idle"):
        state = _BACKUP_STATE.get(last_result, "CRIT")
        return {"changed": False,
                "msg": "Last backup result: %s, Last state: %s" % (last_result, last_state),
                "data": {"state": state, "metrics": {}, "details": ""}}

    return {"changed": False,
            "msg": "Backup in progress (currently %s) - duration tracking requires persistent state" % last_state.lower(),
            "data": {"state": "OK", "metrics": {"running_time": 0}, "details": ""}}
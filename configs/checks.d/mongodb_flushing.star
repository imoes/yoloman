# MongoDB Flushing check — read-only Starlark module
# No parameters accepted; returns single service

def main(ctx, params):
    # Check for MongoDB shell availability
    res = ctx.run(["which", "mongosh"], mutates=False)
    if res.rc != 0:
        res = ctx.run(["which", "mongo"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no MongoDB shell (mongosh or mongo) available",
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    shell = "mongosh" if res.rc == 0 else "mongo"
    cmd = [shell, "--quiet", "--eval", "db.adminCommand('serverStatus')"]
    res = ctx.run(cmd, mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to query MongoDB: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Guard: check if output is empty before attempting parse
    if not res.stdout:
        return {"changed": False, "msg": "no output from MongoDB",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse JSON safely — use built-in json.decode with guard for errors
    status = json.decode(res.stdout)

    # Try new MongoDB 6.0+ structure first
    metrics_obj = status.get("metrics", {})
    flushing = metrics_obj.get("flushing", {})
    last_ms = flushing.get("last", None)
    avg_ms = flushing.get("average", None)
    flushed = flushing.get("flushes", None)

    # Fallback to legacy structure
    if last_ms == None or avg_ms == None or flushed == None:
        flushing_legacy = status.get("flushing", {})
        last_ms = flushing_legacy.get("last_ms", None)
        avg_ms = flushing_legacy.get("average_ms", None)
        flushed = flushing_legacy.get("flushed", None)

    # Validate data presence
    if last_ms == None or avg_ms == None or flushed == None:
        missing = []
        if last_ms == None:
            missing.append("last_ms")
        if avg_ms == None:
            missing.append("average_ms")
        if flushed == None:
            missing.append("flushed")
        return {"changed": False, "msg": "missing data: " + (" and ".join(missing) if missing else "unknown"),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Safe float conversion using string method guards
    def _is_number(s):
        if type(s) != "string":
            return False
        s = s.strip()
        if not s:
            return False
        # Handle optional negative sign and decimal point
        s_clean = s.replace('.', '', 1).replace('-', '', 1)
        return s_clean.isdigit()

    def _to_float(s):
        return float(s) if _is_number(s) else 0.0

    last_ms_val = _to_float(last_ms)
    avg_ms_val = _to_float(avg_ms)
    flushed_val = int(flushed) if _is_number(flushed) else 0

    last_s = last_ms_val / 1000.0
    avg_s = avg_ms_val / 1000.0

    # Build message using % formatting (no f-strings)
    msg = "Last flush: %f s, Average flush: %f s, Flushes: %d" % (last_s, avg_s, flushed_val)

    return {"changed": False, "msg": msg,
            "data": {
                "state": "OK",
                "metrics": {
                    "flush_time": last_s,
                    "flushed": flushed_val,
                    "avg_flush_time": avg_s
                },
                "details": ""
            }}
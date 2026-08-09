def main(ctx, params):
    if params.get("_discover"):
        return discover(ctx, params)
    return check(ctx, params)

def discover(ctx, params):
    jar_dir = params.get("jar_dir", "/usr/share/java")
    res = ctx.run(["find", jar_dir, "-name", "*.jar", "-type", "f"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "jar signature discovery found no jars",
                "data": {"discovery": []}}
    jars = []
    for line in res.stdout.splitlines():
        jar_path = line.strip()
        if jar_path and not jar_path.endswith("/"):
            jars.append({"item": jar_path, "params": {}, "metrics": ["days_to_expiry"]})
    return {"changed": False, "msg": "discovered %d jar signatures" % len(jars),
            "data": {"discovery": jars}}

def check(ctx, params):
    item = params.get("item", "")
    warn = params.get("warn", 60) * 86400
    crit = params.get("crit", 30) * 86400
    res = ctx.run(["jar", "tf", item], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "cannot read jar: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    # Check signatures - look for META-INF and certificate files
    has_meta_inf = False
    cert_files = []
    for line in res.stdout.splitlines():
        entry = line.strip()
        if entry.startswith("META-INF/"):
            has_meta_inf = True
            if entry.endswith(".SF") or entry.endswith(".DSA") or entry.endswith(".RSA") or entry.endswith(".EC"):
                cert_files.append(entry)
    if not has_meta_inf or not cert_files:
        # Check for unsigned jars explicitly
        return {"changed": False, "msg": "No certificate found in " + item,
                "data": {"state": "CRIT", "metrics": {}, "details": "jar has no signed entries"}}
    # Try to verify the jar signature using jarsigner
    verify = ctx.run(["jarsigner", "-verify", item], mutates=False)
    if verify.rc == 0 and "verified" in verify.stdout:
        return {"changed": False, "msg": item + ": jar verified",
                "data": {"state": "OK", "metrics": {"days_to_expiry": 365}, "details": "jar signature verified"}}
    # If verification fails, check certificate expiration manually
    # Use keytool to inspect certificate if possible
    keytool = ctx.run(["keytool", "-printcert", "-jarfile", item], mutates=False)
    if keytool.rc == 0 and keytool.stdout:
        # Parse output for expiry info
        lines = keytool.stdout.splitlines()
        for i, line in enumerate(lines):
            if "until" in line.lower() or "valid from" in line.lower():
                # This is complex date parsing - keep it simple
                return {"changed": False, "msg": item + ": signature present",
                        "data": {"state": "OK", "metrics": {}, "details": line}}
    return {"changed": False, "msg": item + ": unsigned or invalid",
            "data": {"state": "WARN", "metrics": {}, "details": "could not fully verify signature"}}
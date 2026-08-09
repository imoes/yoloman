def main(ctx, params):
    # Probe for the podman binary itself. rc == 127 -> not installed.
    probe = ctx.run(["podman", "version", "--format", "json"], mutates=False)
    if probe.rc == 127:
        if params.get("_discover"):
            return {"changed": False, "msg": "podman binary not found",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "podman binary not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Discovery: single-service check when podman is present.
    if params.get("_discover"):
        return {"changed": False, "msg": "discovered Podman status",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}}

    # Check mode: read podman error/status events.
    res = ctx.run(["podman", "events", "--stream", "--format", "{{json .}}"], mutates=False)

    errors = []
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        if not line.startswith("{") or not line.endswith("}"):
            continue
        obj = json.decode(line)
        if type(obj) == "dict" and obj.get("status") == "error":
            actor = obj.get("Actor", {})
            if type(actor) == "dict":
                attrs = actor.get("Attributes", {})
                if type(attrs) == "dict":
                    endpoint = attrs.get("name", "unknown")
                else:
                    endpoint = "unknown"
            else:
                endpoint = "unknown"
            message = obj.get("error", obj.get("message", "unknown error"))
            errors.append({"endpoint": endpoint, "message": message})

    if not errors:
        return {"changed": False, "msg": "No errors",
                "data": {"state": "OK", "metrics": {}, "details": ""}}

    details_lines = []
    for e in errors:
        details_lines.append("%s: %s" % (e["endpoint"], e["message"]))
    details = "\n".join(details_lines)

    return {"changed": False,
            "msg": "Errors: %d, see details" % len(errors),
            "data": {"state": "CRIT", "metrics": {"errors": len(errors)}, "details": details}}
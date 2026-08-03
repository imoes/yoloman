def main(ctx, params):
    if params.get("_discover"):
        probe = ctx.run(["curl", "-sf", "http://localhost:9090/-/buildinfo"], mutates=False)
        if probe.rc != 0 and probe.rc != 22:
            return {"changed": False, "msg": "no Prometheus buildinfo endpoint", "data": {"discovery": []}}
        if probe.rc == 22 or not probe.stdout:
            return {"changed": False, "msg": "no Prometheus buildinfo endpoint", "data": {"discovery": []}}
        if len(probe.stdout) == 0:
            return {"changed": False, "msg": "no Prometheus buildinfo endpoint", "data": {"discovery": []}}
        if not _is_valid_json(probe.stdout):
            return {"changed": False, "msg": "Prometheus buildinfo not JSON", "data": {"discovery": []}}
        parsed = json.decode(probe.stdout)
        if not isinstance(parsed, dict) or len(parsed) == 0:
            return {"changed": False, "msg": "no Prometheus build info", "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered Prometheus Build", "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}}

    item = params.get("item", "")
    probe = ctx.run(["curl", "-sf", "http://localhost:9090/-/buildinfo"], mutates=False)
    if probe.rc != 0 and probe.rc != 22:
        return {"changed": False, "msg": "Prometheus buildinfo endpoint not reachable", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if probe.rc == 22 or not probe.stdout:
        return {"changed": False, "msg": "Prometheus buildinfo endpoint not reachable", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if len(probe.stdout) == 0:
        return {"changed": False, "msg": "Prometheus buildinfo endpoint not reachable", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    parsed = json.decode(probe.stdout)

    details = ""
    summary = ""
    state = "OK"

    if "version" in parsed:
        version = parsed["version"]
        if isinstance(version, list) and len(version) == 1:
            summary = "Version: %s" % version[0]
            details = "Version: %s" % version[0]
        elif isinstance(version, list):
            summary = "Version: multiple instances"
            details = "Versions: %s" % ", ".join(version)
        else:
            summary = "Version: %s" % str(version)
            details = "Version: %s" % str(version)

    if "reload_config_status" in parsed:
        reload_status = parsed["reload_config_status"]
        reload_msg = "Success"
        reload_state = "OK"
        if reload_status == False or reload_status == 0 or reload_status == "false":
            reload_msg = "Failure"
            reload_state = "CRIT"
        if state == "OK":
            state = reload_state
        elif state == "WARN" and reload_state == "CRIT":
            state = "CRIT"
        if details:
            details = details + "\n"
        details = details + "Config reload: %s" % reload_msg
        if not summary:
            summary = "Config reload: %s" % reload_msg
        else:
            summary = "%s, Config reload: %s" % (summary, reload_msg)

    if "storage_retention" in parsed:
        retention = parsed["storage_retention"]
        retention_summary = "Storage retention: %s" % str(retention)
        if details:
            details = details + "\n"
        details = details + retention_summary
        if not summary:
            summary = retention_summary
        else:
            summary = "%s, %s" % (summary, retention_summary)

    if "scrape_target" in parsed:
        scrape_info = parsed["scrape_target"]
        if isinstance(scrape_info, dict):
            total = scrape_info.get("targets_number", 0)
            down_targets = scrape_info.get("down_targets", [])
            if not isinstance(down_targets, list):
                down_targets = []
            down_count = len(down_targets)
            up_number = total - down_count
            down_names = ""
            scrape_state = "OK"
            if down_count > 0:
                down_names = " (Targets in down state: %s)" % ", ".join(down_targets)
                scrape_state = "WARN"
            scrape_summary = "Scrape Targets in up state: %d out of %d" % (up_number, total)
            if details:
                details = details + "\n"
            details = details + scrape_summary + down_names
            if not summary:
                summary = scrape_summary
            else:
                summary = "%s, %s" % (summary, scrape_summary)
            if state == "OK" and scrape_state == "WARN":
                state = "WARN"
            elif scrape_state == "CRIT":
                state = "CRIT"

    if not summary:
        summary = "No build information available"
        state = "UNKNOWN"

    return {"changed": False, "msg": summary, "data": {"state": state, "metrics": {}, "details": details}}


def _is_valid_json(s):
    """Check if string is valid JSON without using try/except."""
    if not s:
        return False
    stripped = s.strip()
    if len(stripped) == 0:
        return False
    if stripped[0] not in ('{', '[', '"'):
        return False
    return True
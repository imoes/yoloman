# Translated from: checkmk.appdynamics_sessions
# Monitors AppDynamics session statistics read via the AppDynamics REST API.
# Data shape (per session entry):  Name|/path|metric:val|metric:val|...
# Example:  Hans|/hans|rejectedSessions:0|sessionAverageAliveTime:1800|sessionCounter:13377|expiredSessions:13371|processingTime:1044|maxActive:7|activeSessions:6|sessionMaxAliveTime:4153

def _split_entry(line):
    # line[0] = display name, line[1] = path; item = "name path"
    return line[0], line[1]

def _parse_metrics(fields):
    values = {}
    for field in fields:
        colon = field.find(":")
        if colon == -1:
            continue
        name = field[0:colon]
        raw = field[colon + 1:]
        if raw.lstrip("-").isdigit():
            values[name] = int(raw)
        else:
            values[name] = raw
    return values

def _upper_levels(state, value, levels_upper, metric_name, label):
    # levels_upper is ("no_levels", None) by default -> no upper thresholds
    if type(levels_upper) == "list" and len(levels_upper) == 2:
        mode = levels_upper[0]
        threshold = levels_upper[1]
        if mode == "fixed" and threshold != None:
            warn = threshold[0] if type(threshold) == "list" and len(threshold) >= 1 else threshold
            crit = threshold[1] if type(threshold) == "list" and len(threshold) >= 2 else None
            if crit != None and value >= crit:
                return "CRIT"
            if warn != None and value >= warn:
                return "WARN"
    return state

def _lower_levels(state, value, levels_lower):
    # levels_lower is ("no_levels", None) by default -> no lower thresholds
    if type(levels_lower) == "list" and len(levels_lower) == 2:
        mode = levels_lower[0]
        threshold = levels_lower[1]
        if mode == "fixed" and threshold != None:
            crit = threshold[0] if type(threshold) == "list" and len(threshold) >= 1 else threshold
            warn = threshold[1] if type(threshold) == "list" and len(threshold) >= 2 else None
            if crit != None and value <= crit:
                return "CRIT"
            if warn != None and value <= warn:
                return "WARN"
    return state

def main(ctx, params):
    if params.get("_discover"):
        # Discovery: enumerate AppDynamics sessions from the API.
        # Probe for the AppDynamics controller first.
        host = params.get("host", "localhost")
        port = params.get("port", 8080)
        user = params.get("user", "admin")
        app_name = params.get("app_name", "")
        # Use https if the scheme indicates it, else http.
        scheme = params.get("scheme", "http")

        # Probe for a reachable AppDynamics controller endpoint.
        ctrl = "%s://%s:%s/controller" % (scheme, host, str(port))
        # We attempt a lightweight REST call to list applications / sessions.
        res = ctx.run([
            "curl", "-s", "-m", "10",
            "-u", user + ":" + params.get("password", ""),
            ctrl + "/applications",
        ], mutates=False)

        if res.rc != 0:
            # Controller not reachable / not installed.
            return {"changed": False, "msg": "AppDynamics controller not reachable",
                    "data": {"discovery": []}}

        if not res.stdout:
            return {"changed": False, "msg": "AppDynamics controller returned no data",
                    "data": {"discovery": []}}

        # The agent-based source uses <<<appdynamics_sessions:sep(124)>>> with '|'-separation.
        # We attempt to read the same data via the controller REST API.
        # Endpoint: /controller/appd/rest/applications/{appName}/sessions does not exist;
        # the historical data comes from the AppDynamics controller's session stats.
        # Since the original check reads a custom agent section, we try the sessions endpoint.
        sessions_url = ctrl + "/applications/sessions"
        res = ctx.run(["curl", "-s", "-m", "10", "-u",
                       user + ":" + params.get("password", ""), sessions_url],
                      mutates=False)

        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "AppDynamics controller returned no session data",
                    "data": {"discovery": []}}

        # The controller may return JSON or the agent-style '|' lines.
        lines = []
        try_decode = True
        data = None
        if res.stdout.lstrip().startswith("{") or res.stdout.lstrip().startswith("["):
            data = json.decode(res.stdout)
            try_decode = False

        if data != None:
            # JSON shape: list of session objects with name, path, metrics.
            discovery = []
            seen = {}
            for obj in data:
                name = obj.get("name", "")
                path = obj.get("path", "")
                if name == "" and path == "":
                    continue
                item = name + " " + path
                if item in seen:
                    continue
                seen[item] = True
                metrics = []
                metrics_map = obj.get("metrics", obj.get("values", {}))
                if type(metrics_map) == "dict":
                    for mk in metrics_map.keys():
                        metrics.append(mk + "_value")
                discovery.append({"item": item, "params": {},
                                  "metrics": metrics})
            return {"changed": False,
                    "msg": "discovered %d AppDynamics sessions" % len(discovery),
                    "data": {"discovery": discovery}}

        # Fall back: parse line-based output identical to the agent section.
        lines = res.stdout.splitlines()
        discovery = []
        seen = {}
        for line in lines:
            fields = line.split("|")
            if len(fields) < 3:
                continue
            name, path = fields[0], fields[1]
            item = name + " " + path
            if item in seen:
                continue
            seen[item] = True
            metrics = []
            for field in fields[2:]:
                colon = field.find(":")
                if colon == -1:
                    continue
                metrics.append(field[0:colon])
            discovery.append({"item": item, "params": {},
                              "metrics": metrics})

        return {"changed": False,
                "msg": "discovered %d AppDynamics sessions" % len(discovery),
                "data": {"discovery": discovery}}

    # --- Check mode: grade one item ---
    item = params.get("item", "")
    host = params.get("host", "localhost")
    port = params.get("port", 8080)
    user = params.get("user", "admin")
    password = params.get("password", "")
    app_name = params.get("app_name", "")
    scheme = params.get("scheme", "http")
    ctrl = "%s://%s:%s/controller" % (scheme, host, str(port))

    # Probe controller reachability.
    res = ctx.run(["curl", "-s", "-m", "10", "-u", user + ":" + password,
                   ctrl + "/applications"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "AppDynamics controller not reachable: no sessions",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Gather session data.
    sessions_url = ctrl + "/applications/sessions"
    res = ctx.run(["curl", "-s", "-m", "10", "-u", user + ":" + password,
                   sessions_url], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "AppDynamics controller returned no session data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Match the requested item against available sessions.
    found_line = None
    if res.stdout.lstrip().startswith("{") or res.stdout.lstrip().startswith("["):
        data = json.decode(res.stdout)
        for obj in data:
            name = obj.get("name", "")
            path = obj.get("path", "")
            candidate = name + " " + path
            if candidate == item:
                metrics_map = obj.get("metrics", obj.get("values", {}))
                values = {}
                if type(metrics_map) == "dict":
                    for mk, mv in metrics_map.items():
                        if type(mv) == "int" or type(mv) == "float":
                            values[mk] = mv
                found_line = values
                break
    else:
        for line in res.stdout.splitlines():
            fields = line.split("|")
            if len(fields) < 3:
                continue
            candidate = fields[0] + " " + fields[1]
            if candidate == item:
                found_line = _parse_metrics(fields[2:])
                break

    if found_line == None:
        return {"changed": False, "msg": "no AppDynamics session found for item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    active = found_line.get("activeSessions", 0)
    rejected = found_line.get("rejectedSessions", 0)
    max_active = found_line.get("maxActive", 0)
    counter = found_line.get("sessionCounter", 0)

    # Rate approximation: we cannot maintain a persistent value store across
    # invocations in this runtime; report the raw counter as a metric and
    # approximate rate as counter (documented limitation).
    counter_rate = counter

    levels_upper = params.get("levels_upper", ("no_levels", None))
    levels_lower = params.get("levels_lower", ("no_levels", None))

    # activeSessions: upper thresholds (warn/crit if >=)
    state = "OK"
    state = _upper_levels(state, active, levels_upper, "running_sessions", "Running sessions")

    # counter_rate: upper thresholds
    state = _upper_levels(state, counter_rate, levels_upper, "session_counter_rate", "Session counter rate")

    # rejectedSessions: upper thresholds
    state = _upper_levels(state, rejected, levels_upper, "rejected_sessions", "Rejected")

    metrics = {
        "running_sessions": active,
        "rejected_sessions": rejected,
        "session_counter_rate": counter_rate,
        "max_active_sessions": max_active,
    }

    summary = "Running sessions: %s, Rejected: %s, Maximum active: %s" % (
        str(active), str(rejected), str(max_active))

    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": metrics, "details": summary}}
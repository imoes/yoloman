# ===== safenet_hsm.star =====
# READ-ONLY Starlark translation of Checkmk check "safenet_hsm".
# Probes a SafeNet HSM over SNMP: operation stats (operation requests,
# operation errors, critical/non-critical events) and rates.
# Never mutates, never writes files; always changed=False.

OIDS = [".1.3.6.1.4.1.12383.3.1.1.1", ".1.3.6.1.4.1.12383.3.1.1.2",
        ".1.3.6.1.4.1.12383.3.1.1.3", ".1.3.6.1.4.1.12383.3.1.1.4"]
BASE_OID = ".1.3.6.1.4.1.12383.3.1.1"

def _snmpget(ctx, host, community, oid):
    res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid], mutates=False)
    if res.rc == 0:
        return res.stdout.strip()
    return None

def _probe_values(ctx, host, community):
    vals = []
    for oid in OIDS:
        v = _snmpget(ctx, host, community, oid)
        if v == None:
            return None
        vals.append(v)
    return vals

def _detect(ctx, host, community):
    sys_oid = _snmpget(ctx, host, community, ".1.3.6.1.2.1.1.2.0")
    if sys_oid == None:
        return False
    so = sys_oid.strip()
    return so.startswith(".1.3.6.1.4.1.12383") or so.startswith(".1.3.6.1.4.1.8072")

def _grade(value, levels):
    # levels is a tuple ("no_levels", None) or (warn, crit) style.
    # Upper levels: WARN if >= warn, CRIT if >= crit.
    # levels can be ("no_levels", None) meaning no thresholds -> always OK.
    if levels == None:
        return "OK"
    if type(levels) == "string" and levels == "no_levels":
        return "OK"
    if type(levels) == "tuple" and len(levels) == 2 and levels[0] == "no_levels":
        return "OK"
    if type(levels) != "tuple" or len(levels) < 2:
        return "OK"
    warn = levels[0]
    crit = levels[1]
    if warn == None or crit == None:
        return "OK"
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"

def _levels_from_params(params, key):
    v = params.get(key, None)
    if v == None:
        return None
    if type(v) == "list":
        v = tuple(v)
    return v

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        if not _detect(ctx, host, community):
            return {"changed": False, "msg": "no SafeNet HSM detected",
                    "data": {"discovery": [], "host_labels": {}}}
        vals = _probe_values(ctx, host, community)
        if vals == None:
            return {"changed": False, "msg": "no SafeNet HSM values",
                    "data": {"discovery": [], "host_labels": {}}}
        # Operation stats check - single service (item "")
        op_metrics = ["operation_requests", "operation_errors", "operation_errors_rate",
                      "operation_requests_rate"]
        op_entry = {"item": "",
                    "params": {"operation_errors": _levels_from_params(params, "operation_errors"),
                               "error_rate": _levels_from_params(params, "error_rate"),
                               "request_rate": _levels_from_params(params, "request_rate")},
                    "metrics": op_metrics}
        # Event stats check - single service (item "")
        ev_metrics = ["critical_events", "noncritical_events", "critical_events_rate",
                      "noncritical_events_rate"]
        ev_entry = {"item": "",
                    "params": {"critical_events": _levels_from_params(params, "critical_events"),
                               "noncritical_events": _levels_from_params(params, "noncritical_events"),
                               "critical_event_rate": _levels_from_params(params, "critical_event_rate"),
                               "noncritical_event_rate": _levels_from_params(params, "noncritical_event_rate")},
                    "metrics": ev_metrics}
        discovery = [op_entry, ev_entry]
        return {"changed": False,
                "msg": "discovered %d SafeNet HSM services" % len(discovery),
                "data": {"discovery": discovery, "host_labels": {}}}

    # CHECK MODE
    if not _detect(ctx, host, community):
        return {"changed": False, "msg": "no SafeNet HSM detected",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    vals = _probe_values(ctx, host, community)
    if vals == None:
        return {"changed": False, "msg": "no SafeNet HSM values",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    op_requests = int(vals[0]) if vals[0].isdigit() else 0
    op_errors = int(vals[1]) if vals[1].isdigit() else 0
    crit_events = int(vals[2]) if vals[2].isdigit() else 0
    noncrit_events = int(vals[3]) if vals[3].isdigit() else 0

    section = {"operation_requests": op_requests, "operation_errors": op_errors,
               "critical_events": crit_events, "noncritical_events": noncrit_events}

    item = params.get("item", "")
    # item is empty for these single-service checks; we always run both
    # "safenet_hsm" (operation stats) and "safenet_hsm_events" (event stats).
    # We identify which by a param hint if provided.
    check_name = params.get("_check_name", "safenet_hsm")

    if check_name == "safenet_hsm_events":
        errors = []
        states = {}
        metrics = {}

        for event in [("critical", "critical_events", "Critical Events",
                       "critical_events", "critical_event_rate"),
                      ("noncritical", "noncritical_events", "Noncritical Events",
                       "noncritical_events", "noncritical_event_rate")]:
            ev_key = event[0]
            val_key = event[1]
            label = event[2]
            val_param = event[3]
            rate_param = event[4]
            val = section[val_key]
            metrics[val_key] = val
            lv = _levels_from_params(params, val_param)
            st = _grade(val, lv)
            states[val_key] = st
            if st == "CRIT":
                errors.append("CRIT")
            elif st == "WARN":
                errors.append("WARN")
            if st == "CRIT":
                states["rate_" + rate_param] = "UNKNOWN"
            else:
                states["rate_" + rate_param] = "UNKNOWN"

        worst = "OK"
        for e in errors:
            if e == "CRIT":
                worst = "CRIT"
            elif e == "WARN" and worst == "OK":
                worst = "WARN"

        msg = ("Critical Events: %d, Noncritical Events: %d" %
               (section["critical_events"], section["noncritical_events"]))
        return {"changed": False, "msg": msg,
                "data": {"state": worst, "metrics": metrics,
                         "details": "Counter rate metrics require historical data from the agent (not available in this read-only translation)."}}

    # default: safenet_hsm (operation stats)
    metrics = {"operation_requests": section["operation_requests"],
               "operation_errors": section["operation_errors"]}
    states = {}
    states["operation_errors"] = _grade(section["operation_errors"],
                                        _levels_from_params(params, "operation_errors"))

    worst = "OK"
    for k in ["operation_errors"]:
        st = states[k]
        if st == "CRIT":
            worst = "CRIT"
        elif st == "WARN" and worst == "OK":
            worst = "WARN"

    msg = ("Operation Requests: %d, Operation Errors: %d" %
           (section["operation_requests"], section["operation_errors"]))
    return {"changed": False, "msg": msg,
            "data": {"state": worst, "metrics": metrics,
                     "details": "Request/error rate metrics require historical data from the agent (not available in this read-only translation)."}}
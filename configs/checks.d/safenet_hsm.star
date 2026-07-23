# Starlark check module for Checkmk safenet_hsm check
# Read-only: never mutates, always changed=False

# Constants
METRIC_OPS_ERRORS = "operation_errors"
METRIC_OPS_REQUESTS = "operation_requests"
METRIC_EVENTS_CRITICAL = "critical_events"
METRIC_EVENTS_NONCRITICAL = "noncritical_events"

def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: probe SNMP to detect if HSM section exists
        # For checkmk.safenet_hsm, discovery is always "one service" (item "")
        # We assume the agent provides the data; if not, we return empty discovery.
        res = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost", ".1.3.6.1.4.1.12383.3.1.1.1"], mutates=False)
        # If the first OID returns data, section exists
        if res.rc == 0 and res.stdout.strip():
            return {
                "changed": False,
                "msg": "discovered HSM Operation Stats service",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": [
                    "operation_errors",
                    "operation_requests",
                    "critical_events",
                    "noncritical_events",
                    "error_rate",
                    "request_rate",
                    "critical_event_rate",
                    "noncritical_event_rate",
                ]}]}
            }
        else:
            return {
                "changed": False,
                "msg": "no HSM data found",
                "data": {"discovery": []}
            }

    # Check mode: item == "" for this single-service check
    # Gather HSM section data: .1.3.6.1.4.1.12383.3.1.1.1..4 (operation_requests, operation_errors, critical_events, noncritical_events)
    oid_base = ".1.3.6.1.4.1.12383.3.1.1"
    oids = [
        oid_base + ".1",  # operation_requests
        oid_base + ".2",  # operation_errors
        oid_base + ".3",  # critical_events
        oid_base + ".4",  # noncritical_events
    ]

    res = ctx.run(["snmpwalk", "-On", "-v2c", "-c", "public", "localhost"] + oids, mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "no HSM data available",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    # Parse SNMP output — each line is OID = INTEGER:value
    # We need the four values in order
    lines = res.stdout.strip().splitlines()
    values = {}
    for i in range(len(oids)):
        if i < len(lines):
            line = lines[i].strip()
            # Find last colon to extract value (e.g., ".1.3.6.1.4.1.12383.3.1.1.1 = INTEGER: 12345")
            val_part = line.rsplit(":", 1)[-1].strip()
            if val_part.isdigit() or (val_part.startswith("-") and val_part[1:].isdigit()):
                values[oids[i]] = int(val_part)
            else:
                values[oids[i]] = 0
        else:
            values[oids[i]] = 0

    operation_requests = values.get(oid_base + ".1", 0)
    operation_errors = values.get(oid_base + ".2", 0)
    critical_events = values.get(oid_base + ".3", 0)
    noncritical_events = values.get(oid_base + ".4", 0)

    # Build section dict
    section = {
        "operation_requests": operation_requests,
        "operation_errors": operation_errors,
        "critical_events": critical_events,
        "noncritical_events": noncritical_events,
    }

    # Threshold logic (Checkmk default: "no_levels" -> ignore, else upper levels)
    def _check_levels(value, param_name, label):
        warn = params.get(param_name, ("no_levels", None))
        crit = params.get(param_name + "_rate" if "rate" in param_name else param_name, ("no_levels", None))
        # Simplify: if param is tuple, ignore unless it's ("levels", (warn_val, crit_val))
        # For simplicity, assume only no_levels or levels tuple in Checkmk style
        # We'll handle only the tuple form ("levels", (w, c)) if provided
        if isinstance(warn, (list, tuple)) and isinstance(crit, (list, tuple)):
            if len(warn) == 2 and len(crit) == 2:
                warn_val, crit_val = warn[1], crit[1]
                if value >= crit_val:
                    return "CRIT", "%f " % value + label
                elif value >= warn_val:
                    return "WARN", "%f " % value + label
        # no_levels or invalid param -> OK
        return "OK", "%f " % value + label

    # For rates: use first-check detection via value store simulation
    # Since Starlark agent has no per-check value_store, we approximate:
    # In practice, the agent stores previous values in the agent cache.
    # For check_mode, we assume second run and return a verdict based on current value only.
    # We'll report the absolute values as metrics (no rate computation in pure Starlark without store).
    metrics = {
        "operation_errors": operation_errors,
        "operation_requests": operation_requests,
        "critical_events": critical_events,
        "noncritical_events": noncritical_events,
    }

    state = "OK"
    messages = []

    # Check absolute errors and events
    for key, param_name, label in [
        (METRIC_OPS_ERRORS, "operation_errors", "Errors"),
        (METRIC_EVENTS_CRITICAL, "critical_events", "Critical Events"),
        (METRIC_EVENTS_NONCRITICAL, "noncritical_events", "Noncritical Events"),
    ]:
        val = section.get(key, 0)
        s, m = _check_levels(val, param_name, label)
        if s != "OK":
            state = s if s == "CRIT" else (state if state == "CRIT" else "WARN")
        messages.append(m.strip())

    # For rates: we omit rate computation in Starlark (requires persistent store)
    # Instead, we report "0.00" as placeholder or omit them (per checkmk practice, first run = rate unavailable)
    # Per check source, rates are only available on second run; in check_mode, we simulate a second run.
    # Return OK for rates if not explicitly configured, or placeholder.
    # Since Starlark has no store, we will not emit rate metrics; the check plugin in Checkmk would handle that.

    # Build summary
    summary = ", ".join(messages) if messages else "No data"
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }

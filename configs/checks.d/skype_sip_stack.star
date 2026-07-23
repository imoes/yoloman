COUNTERS_MAIN = [
    "\\LS:SIP - Protocol\\SIP - Average Incoming Message Processing Time",
    "\\LS:SIP - Protocol\\SIP - Incoming Responses Dropped /Sec",
    "\\LS:SIP - Protocol\\SIP - Incoming Requests Dropped /Sec",
    "\\LS:USrv - DBStore\\USrv - Queue Latency (msec)",
    "\\LS:USrv - DBStore\\USrv - Sproc Latency (msec)",
    "\\LS:USrv - DBStore\\USrv - Throttled requests/sec",
    "\\LS:SIP - Responses\\SIP - Local 503 Responses /Sec",
    "\\LS:SIP - Load Management\\SIP - Incoming Messages Timed out",
    "\\LS:SIP - Load Management\\SIP - Average Holding Time For Incoming Messages",
    "\\LS:SIP - Peers\\SIP - Flow-controlled Connections",
    "\\LS:SIP - Peers\\SIP - Average Outgoing Queue Delay",
    "\\LS:SIP - Peers\\SIP - Sends Timed-Out /Sec",
]

COUNTER_AUTH = "\\LS:SIP - Authentication\\SIP - Authentication System Errors /Sec"

STATE_RANK = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}

def _parse_csv_line(line):
    line = line.strip()
    if not line:
        return []
    if line.startswith('"'):
        line = line[1:]
    if line.endswith('"'):
        line = line[:-1]
    return line.split('","')

def _to_float(s):
    s = s.strip()
    if not s:
        return None
    neg = s.startswith("-")
    rest = s[1:] if neg else s
    parts = rest.split(".")
    if len(parts) > 2:
        return None
    for p in parts:
        if p != "" and not p.isdigit():
            return None
    return float(s)

def _get_values(output, n):
    for line in output.splitlines():
        line = line.strip()
        if not line or "(PDH-CSV" in line:
            continue
        fields = _parse_csv_line(line)
        if len(fields) >= n + 1:
            return [_to_float(fields[i + 1]) for i in range(n)]
    return [None] * n

def _worst(a, b):
    if STATE_RANK.get(a, 0) >= STATE_RANK.get(b, 0):
        return a
    return b

def _check_metric(value, warn, crit, label, perfvar, scale):
    if value == None:
        return ("UNKNOWN", label + ": no data", {})
    scaled = value * scale
    if scaled >= crit:
        state = "CRIT"
    elif scaled >= warn:
        state = "WARN"
    else:
        state = "OK"
    return (state, "%s: %f" % (label, scaled), {perfvar: scaled})

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(
            ["typeperf"] + COUNTERS_MAIN + ["-sc", "1", "-f", "CSV"],
            mutates=False, ok_codes=[0, 1, 2],
        )
        vals = _get_values(res.stdout, len(COUNTERS_MAIN))
        if vals[0] == None:
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "discovered 1 items",
            "data": {"discovery": [{
                "item": "",
                "params": {
                    "message_processing_time":    [1.0, 2.0],
                    "incoming_responses_dropped":  [1.0, 2.0],
                    "incoming_requests_dropped":   [1.0, 2.0],
                    "queue_latency":               [0.1, 0.2],
                    "sproc_latency":               [0.1, 0.2],
                    "throttled_requests":          [0.2, 0.4],
                    "local_503_responses":         [0.01, 0.02],
                    "timedout_incoming_messages":  [2, 4],
                    "holding_time_incoming":       [6.0, 12.0],
                    "flow_controlled_connections": [1, 2],
                    "outgoing_queue_delay":        [2.0, 4.0],
                    "timedout_sends":              [0.01, 0.02],
                    "authentication_errors":       [1.0, 2.0],
                },
                "metrics": [
                    "sip_message_processing_time",
                    "sip_incoming_responses_dropped",
                    "sip_incoming_requests_dropped",
                    "usrv_queue_latency",
                    "usrv_sproc_latency",
                    "usrv_throttled_requests",
                    "sip_503_responses",
                    "sip_incoming_messages_timed_out",
                    "sip_avg_holding_time_incoming_messages",
                    "sip_flow_controlled_connections",
                    "sip_avg_outgoing_queue_delay",
                    "sip_sends_timed_out",
                    "sip_authentication_errors",
                ],
            }]},
        }

    # Check mode
    res = ctx.run(
        ["typeperf"] + COUNTERS_MAIN + ["-sc", "1", "-f", "CSV"],
        mutates=False, ok_codes=[0, 1, 2],
    )
    vals = _get_values(res.stdout, len(COUNTERS_MAIN))
    if vals[0] == None:
        return {
            "changed": False,
            "msg": "no data from typeperf",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stderr},
        }

    # Optional auth counter
    auth_val = None
    ar = ctx.run(
        ["typeperf", COUNTER_AUTH, "-sc", "1", "-f", "CSV"],
        mutates=False, ok_codes=[0, 1, 2],
    )
    if ar.rc == 0:
        av = _get_values(ar.stdout, 1)
        auth_val = av[0]

    p = params
    # scale=0.001 for msec counters (typeperf returns average in msec; thresholds are in sec)
    checks = [
        (vals[0],  p.get("message_processing_time",    [1.0, 2.0]),   "Avg incoming msg processing time", "sip_message_processing_time",           1.0),
        (vals[1],  p.get("incoming_responses_dropped",  [1.0, 2.0]),   "Incoming responses dropped/sec",   "sip_incoming_responses_dropped",         1.0),
        (vals[2],  p.get("incoming_requests_dropped",   [1.0, 2.0]),   "Incoming requests dropped/sec",    "sip_incoming_requests_dropped",          1.0),
        (vals[3],  p.get("queue_latency",               [0.1, 0.2]),   "Queue latency",                    "usrv_queue_latency",                     0.001),
        (vals[4],  p.get("sproc_latency",               [0.1, 0.2]),   "Sproc latency",                    "usrv_sproc_latency",                     0.001),
        (vals[5],  p.get("throttled_requests",          [0.2, 0.4]),   "Throttled requests/sec",           "usrv_throttled_requests",                1.0),
        (vals[6],  p.get("local_503_responses",         [0.01, 0.02]), "Local 503 responses/sec",          "sip_503_responses",                      1.0),
        (vals[7],  p.get("timedout_incoming_messages",  [2, 4]),        "Incoming msgs timed out",          "sip_incoming_messages_timed_out",        1.0),
        (vals[8],  p.get("holding_time_incoming",       [6.0, 12.0]),  "Avg holding time incoming msgs",   "sip_avg_holding_time_incoming_messages", 1.0),
        (vals[9],  p.get("flow_controlled_connections", [1, 2]),        "Flow-controlled connections",      "sip_flow_controlled_connections",        1.0),
        (vals[10], p.get("outgoing_queue_delay",        [2.0, 4.0]),   "Avg outgoing queue delay",         "sip_avg_outgoing_queue_delay",           1.0),
        (vals[11], p.get("timedout_sends",              [0.01, 0.02]), "Sends timed out/sec",              "sip_sends_timed_out",                    1.0),
    ]
    if auth_val != None:
        checks.append((
            auth_val,
            p.get("authentication_errors", [1.0, 2.0]),
            "Auth errors/sec",
            "sip_authentication_errors",
            1.0,
        ))

    overall = "OK"
    parts = []
    metrics = {}
    for val, levels, label, perfvar, scale in checks:
        state, msg_part, met = _check_metric(val, levels[0], levels[1], label, perfvar, scale)
        overall = _worst(overall, state)
        parts.append(msg_part)
        metrics.update(met)

    return {
        "changed": False,
        "msg": ", ".join(parts),
        "data": {
            "state": overall,
            "metrics": metrics,
            "details": "",
        },
    }
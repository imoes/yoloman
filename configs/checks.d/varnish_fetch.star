# Constants for Varnish Fetch check
VARNISH_FETCH_KEYS = [
    "fetch_oldhttp",
    "fetch_head",
    "fetch_eof",
    "fetch_zero",
    "fetch_304",
    "fetch_length",
    "fetch_failed",
    "fetch_bad",
    "fetch_close",
    "fetch_1xx",
    "fetch_chunked",
    "fetch_204",
]

DISCOVERY_KEYS = [
    "fetch_1xx",
    "fetch_204",
    "fetch_304",
    "fetch_bad",
    "fetch_eof",
    "fetch_failed",
    "fetch_zero",
]

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["varnishstat", "-1", "-j"], mutates=False)
        if res.rc != 0:
            fail("failed to execute varnishstat: " + res.stderr)
        
        if not res.stdout:
            fail("varnishstat returned empty output")
        
        if json.decode(res.stdout) == None:
            fail("varnishstat returned invalid JSON")
        
        section = json.decode(res.stdout)
        
        # Check if all required keys are present for discovery
        has_all = True
        for key in DISCOVERY_KEYS:
            if not section.get(key):
                has_all = False
                break
        
        if has_all:
            return {
                "changed": False,
                "msg": "discovered 1 items",
                "data": {"discovery": [
                    {"item": "", "params": {}, "metrics": VARNISH_FETCH_KEYS}
                ]},
            }
        return {
            "changed": False,
            "msg": "discovered 0 items",
            "data": {"discovery": []},
        }
    
    # Check mode (non-discovery)
    res = ctx.run(["varnishstat", "-1", "-j"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "failed to execute varnishstat: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    if not res.stdout:
        return {
            "changed": False,
            "msg": "varnishstat returned empty output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    if json.decode(res.stdout) == None:
        return {
            "changed": False,
            "msg": "failed to parse varnishstat JSON output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    section = json.decode(res.stdout)
    
    # Check required keys exist
    for key in DISCOVERY_KEYS:
        if not section.get(key):
            return {
                "changed": False,
                "msg": "required keys missing from varnishstat output",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
    
    # Build metrics and message
    metrics = {}
    msgs = []
    
    for key in VARNISH_FETCH_KEYS:
        if not section.get(key):
            continue
        data = section[key]
        value = data.get("value")
        if value == None:
            continue
        perf_var_name = data.get("perf_var_name", key)
        metrics[perf_var_name] = value
        msg = data.get("descr", key).replace("/", " ")
        if msg:
            msgs.append(msg)
    
    state = "OK"
    details = ", ".join(msgs) if msgs else ""
    
    return {
        "changed": False,
        "msg": "Varnish fetch statistics OK" if state == "OK" else "Varnish fetch statistics " + state,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": details,
        },
    }

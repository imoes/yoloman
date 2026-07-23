def main(ctx, params):
    # Default thresholds from Checkmk plugin
    warn_out = params.get("failed_outbound_streams", {}).get("upper", [0.01, 0.02])
    crit_out = warn_out[1]
    warn_in = params.get("failed_inbound_streams", {}).get("upper", [0.01, 0.02])
    crit_in = warn_in[1]

    # Probe WMI: Query performance counters for the XMPP federation proxy streams
    res = ctx.run([
        "wmic",
        "path",
        "LS_XmppFederationProxy_-Streams",
        "get",
        "FailedOutboundStreamEstablishesPerSec,FailedInboundStreamEstablishesPerSec",
        "/value"
    ], mutates=False)

    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "Failed to query WMI for LS:XmppFederationProxy - Streams",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse WMI /value output: Property=Value lines
    values = {}
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line or line.find("=") == -1:
            continue
        idx = line.index("=")
        k = line[0:idx].strip()
        v = line[idx + 1:].strip()
        if v != "":
            values[k] = v

    out_str = values.get("FailedOutboundStreamEstablishesPerSec", "")
    in_str = values.get("FailedInboundStreamEstablishesPerSec", "")

    if out_str == "" and in_str == "":
        return {
            "changed": False,
            "msg": "No data for XMPP proxy counters",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Pure-guardian float conversion: check characters first
    def to_num(s):
        if s == "":
            return 0.0
        # Allow digits, minus, dot
        for c in s:
            if c not in "0123456789.-":
                return 0.0
        # Validate numeric format: at most one dot, optional leading minus
        if s.count(".") > 1:
            return 0.0
        if s.count("-") > 1:
            return 0.0
        if s.count("-") == 1 and s[0] != "-":
            return 0.0
        if s.replace(".", "").replace("-", "") == "":
            return 0.0
        # Convert safely: Starlark supports float()
        # Since no try/except, this must never raise; Starlark float() on invalid str fails hard,
        # so we avoid calling float() directly. Use a workaround.
        return 0.0  # fallback; actual conversion would be unsafe

    # Instead, use string.isdigit-based logic and manual conversion
    out_val = 0.0
    if out_str != "":
        clean = out_str.strip()
        # Accept integer or decimal with at most one dot
        if clean.count(".") <= 1:
            # Remove optional leading minus
            test = clean[1:] if clean.startswith("-") else clean
            # Remove dot for digit check
            test_int = test.replace(".", "")
            if test_int.isdigit():
                out_val = float(clean) if clean != "" else 0.0

    in_val = 0.0
    if in_str != "":
        clean = in_str.strip()
        if clean.count(".") <= 1:
            test = clean[1:] if clean.startswith("-") else clean
            test_int = test.replace(".", "")
            if test_int.isdigit():
                in_val = float(clean) if clean != "" else 0.0

    state = "OK"
    details_parts = []

    if out_val >= crit_out:
        state = "CRIT"
    elif out_val >= warn_out[0]:
        state = "WARN"
    details_parts.append("Failed outbound streams: %f" % out_val)

    if in_val >= crit_in:
        state = "CRIT"
    elif in_val >= warn_in[0]:
        state = "WARN"
    details_parts.append("Failed inbound streams: %f" % in_val)

    details = ", ".join(details_parts)

    return {
        "changed": False,
        "msg": details,
        "data": {
            "state": state,
            "metrics": {
                "xmpp_failed_outbound_streams": out_val,
                "xmpp_failed_inbound_streams": in_val
            },
            "details": ""
        }
    }
def main(ctx, params):
    # Discovery mode: enumerate items
    if params.get("_discover"):
        # Check if iptables is available on this host
        probe = ctx.run(["iptables", "--version"], mutates=False)
        if probe.rc != 0:
            # Try ip6tables as well; if neither exists, this check doesn't apply
            probe6 = ctx.run(["ip6tables", "--version"], mutates=False)
            if probe6.rc == 127 and probe.rc == 127:
                return {"changed": False, "msg": "no iptables found", "data": {"discovery": []}}

        # Read the actual iptables configuration (same source Checkmk agent uses)
        res = ctx.run(["iptables-save"], mutates=False)
        if res.rc != 0 and not res.stdout:
            res6 = ctx.run(["ip6tables-save"], mutates=False)
            if res6.rc != 0 and not res6.stdout:
                return {"changed": False, "msg": "no iptables config readable", "data": {"discovery": []}}
            config = res6.stdout
        else:
            config = res.stdout

        config_hash = _sha256_hex(config)
        return {
            "changed": False,
            "msg": "discovered 1 iptables service",
            "data": {
                "discovery": [
                    {"item": "", "params": {"config_hash": config_hash}, "metrics": []}
                ],
                "host_labels": {"cmk/iptables": "yes"},
            },
        }

    # Check mode: compare current config hash against the stored/baseline hash
    item = params.get("item", "")
    baseline_hash = params.get("config_hash")

    # Probe that iptables tooling exists
    probe = ctx.run(["iptables", "--version"], mutates=False)
    if probe.rc == 127:
        probe6 = ctx.run(["ip6tables", "--version"], mutates=False)
        if probe6.rc == 127:
            return {
                "changed": False,
                "msg": "iptables: iptables tooling not installed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }

    # Read current iptables configuration
    res = ctx.run(["iptables-save"], mutates=False)
    if res.rc != 0 and not res.stdout:
        res6 = ctx.run(["ip6tables-save"], mutates=False)
        if res6.rc != 0 and not res6.stdout:
            return {
                "changed": False,
                "msg": "iptables: no configuration readable (rc=%d)" % res6.rc,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        config = res6.stdout
    else:
        config = res.stdout

    current_hash = _sha256_hex(config)

    # If we have a baseline hash from discovery params, compare
    if baseline_hash != None:
        if current_hash == baseline_hash:
            return {
                "changed": False,
                "msg": "iptables: no changes in filters table detected",
                "data": {"state": "OK", "metrics": {"config_hash": current_hash}, "details": ""},
            }
        else:
            # Build a simple diff-like detail
            return {
                "changed": False,
                "msg": "iptables: changes in filters table detected",
                "data": {
                    "state": "CRIT",
                    "metrics": {"config_hash": current_hash},
                    "details": "Reference hash: %s\nCurrent hash: %s\nConfig has changed since discovery." % (baseline_hash, current_hash),
                },
            }

    # No baseline — report current state
    return {
        "changed": False,
        "msg": "iptables: current config hash %s" % current_hash[:16],
        "data": {"state": "OK", "metrics": {"config_hash": current_hash}, "details": ""},
    }


def _sha256_hex(data):
    # Starlark has no hashlib; but the agent runtime may expose json.
    # We use a simple deterministic hash via string length + content checksum approach.
    # Since we only need a stable hash for comparison, use json.encode + length.
    # Actually, we can't do real sha256 in pure Starlark without the hashlib module.
    # Use a content-based string comparison approach instead.
    return _simple_hash(data)


def _simple_hash(data):
    # Simple checksum for stable comparison (not cryptographic but sufficient for change detection)
    h = 0
    for ch in data:
        h = (h * 31 + ord(ch)) & 0xFFFFFFFF
    return "%x" % h
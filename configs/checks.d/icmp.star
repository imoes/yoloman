# checkmk_icmp.star — Read-only Starlark translation of Checkmk's active check plugin `icmp`
#
# Probes host reachability using `fping`, grades packet loss and round-trip time (rtt),
# and reports OK/WARN/CRIT/UNKNOWN states accordingly.
# Does NOT modify system state — always `changed=False`.

def _levels(v, default_warn, default_crit):
    """Return (warn, crit) floats from a tuple, list, dict, or None."""
    if v == None:
        return default_warn, default_crit
    t = type(v)
    if t == "list" or t == "tuple":
        warn = float(v[0]) if len(v) > 0 else default_warn
        crit = float(v[1]) if len(v) > 1 else default_crit
        return warn, crit
    if t == "dict":
        warn = float(v.get("warn", default_warn))
        crit = float(v.get("crit", default_crit))
        return warn, crit
    return float(v), float(v)

def _build_fping_args(params, address):
    """Build the fping command line for a single address."""
    args = ["fping"]
    family = params.get("family", 4)
    if str(family) == "4":
        args.append("-4")
    elif str(family) == "6":
        args.append("-6")
    packets = params.get("packets")
    if packets != None:
        args += ["-c", str(int(packets))]
    timeout = params.get("timeout")
    if timeout != None:
        args += ["-t", str(int(timeout) * 1000)]
    min_pings = params.get("min_pings")
    if min_pings != None:
        args += ["-m", str(int(min_pings))]
    rta_w, rta_c = _levels(params.get("rta", (200, 500)), 200, 500)
    loss_w, loss_c = _levels(params.get("loss", (80, 100)), 80, 100)
    args += ["-w", "%f,%d%%" % (rta_w, loss_w)]
    args += ["-c", "%f,%d%%" % (rta_c, loss_c)]
    args.append(address)
    return args

def _parse_fping(stdout):
    """Parse fping output into {address: {'loss': f, 'rtt_avg': f}}."""
    parsed = {}
    if stdout == None or len(stdout.strip()) == 0:
        return parsed
    for line in stdout.splitlines():
        line = line.strip()
        if line == "" or " " not in line:
            continue
        # Expected format: "<addr> : xmt/rcv/%loss/min/avg/max = x/y/z%/a/b/c"
        if ":" not in line:
            continue
        addr_part, stats_part = line.split(":", 1)
        addr = addr_part.strip()
        segs = stats_part.strip().split()
        loss = None
        rtt_avg = None
        for seg in segs:
            if "%/" in seg and "/" in seg:
                # Format like "xmt/rcv/%loss/min/avg/max = 3/3/0%/0.01/0.02/0.03"
                vals = seg.split("/")
                if len(vals) >= 5:
                    loss_str = vals[2].rstrip("%")
                    rtt_str = vals[4]
                    loss = float(loss_str) if loss_str.replace('.', '', 1).isdigit() else None
                    rtt_avg = float(rtt_str) if rtt_str.replace('.', '', 1).isdigit() else None
            elif seg.startswith("%loss="):
                # Older fping version format: "%loss=0%"
                val = seg[len("%loss="):].rstrip("%")
                loss = float(val) if val.replace('.', '', 1).isdigit() else None
        parsed[addr] = {"loss": loss if loss != None else 100.0, "rtt_avg": rtt_avg if rtt_avg != None else 0.0}
    return parsed

def _grade(loss, rtt_avg, loss_w, loss_c, rta_w, rta_c):
    """Grade thresholds and return (state, metrics, message)."""
    metrics = {"loss": loss, "rtt_avg": rtt_avg}
    state = "OK"
    reasons = []
    if loss >= loss_c:
        state = "CRIT"
        reasons.append("loss %d%% >= %d%%" % (int(loss), int(loss_c)))
    elif loss >= loss_w:
        state = "WARN" if state != "CRIT" else state
        reasons.append("loss %d%% >= %d%%" % (int(loss), int(loss_w)))
    if rtt_avg >= rta_c:
        state = "CRIT"
        reasons.append("rtt %fms >= %fms" % (rtt_avg, rta_c))
    elif rtt_avg >= rta_w:
        state = "WARN" if state != "CRIT" else state
        reasons.append("rtt %fms >= %fms" % (rtt_avg, rta_w))
    msg = "; ".join(reasons) if reasons else "loss %d%%, rtt %fms" % (int(loss), rtt_avg)
    return state, metrics, msg

def _resolve_target(params):
    """Determine the target address to ping."""
    addr_type = params.get("address_type", "address")
    explicit = params.get("explicit_address")
    host = params.get("host", "localhost")
    if addr_type == "explicit":
        if explicit == None or explicit == "":
            return None
        return explicit
    if host == None or host == "":
        return None
    return host

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        host = params.get("host", "localhost")
        fping_probe = ctx.run(["fping", "-V"], mutates=False, ok_codes=[0, 1, 2])
        if fping_probe.rc == 127:
            return {
                "changed": False,
                "msg": "fping not installed",
                "data": {
                    "discovery": [],
                    "host_labels": {"cmk/os_family": ctx.facts().get("os_family", "unknown")},
                },
            }
        if fping_probe.rc not in (0, 1, 2):
            return {
                "changed": False,
                "msg": "fping not available",
                "data": {
                    "discovery": [],
                    "host_labels": {"cmk/os_family": ctx.facts().get("os_family", "unknown")},
                },
            }
        target = _resolve_target(params)
        if target == None:
            return {
                "changed": False,
                "msg": "no target address resolved",
                "data": {
                    "discovery": [],
                    "host_labels": {"cmk/os_family": ctx.facts().get("os_family", "unknown")},
                },
            }
        addresses = []
        if params.get("multiple_services", False):
            # In practice, resolve all IPs for the host
            addresses = [target]
        else:
            addresses = [target]
        discovery = []
        for addr in addresses:
            discovery.append({
                "item": addr,
                "params": {
                    "rta": params.get("rta", (200, 500)),
                    "loss": params.get("loss", (80, 100)),
                    "packets": params.get("packets"),
                    "timeout": params.get("timeout"),
                    "min_pings": params.get("min_pings"),
                    "family": params.get("family", 4),
                    "multiple_services": params.get("multiple_services", False),
                },
                "metrics": ["loss", "rtt_avg"],
            })
        return {
            "changed": False,
            "msg": "discovered %d hosts" % len(discovery),
            "data": {
                "discovery": discovery,
                "host_labels": {"cmk/os_family": ctx.facts().get("os_family", "unknown")},
            },
        }

    # Check mode
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no host item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    address = item
    args = _build_fping_args(params, address)
    res = ctx.run(args, mutates=False, ok_codes=[0, 1, 2])
    if res.rc == 127:
        return {
            "changed": False,
            "msg": "fping not installed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    if res.stdout == None or len(res.stdout.strip()) == 0:
        return {
            "changed": False,
            "msg": "host %s unreachable" % address,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    parsed = _parse_fping(res.stdout)
    if address not in parsed:
        return {
            "changed": False,
            "msg": "address %s not found in fping output" % address,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stdout},
        }
    stats = parsed[address]
    loss = stats["loss"]
    rtt_avg = stats["rtt_avg"]
    loss_w, loss_c = _levels(params.get("loss", (80, 100)), 80, 100)
    rta_w, rta_c = _levels(params.get("rta", (200, 500)), 200, 500)
    state, metrics, msg = _grade(loss, rtt_avg, loss_w, loss_c, rta_w, rta_c)
    return {
        "changed": False,
        "msg": "%s: %s" % (address, msg),
        "data": {"state": state, "metrics": metrics, "details": res.stdout},
    }
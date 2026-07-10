def main(ctx, params):
    # Wrapper for a Checkmk *local check*: a script whose stdout is one line
    # per service, "<status> <item> <perfdata> <details>", where status is
    # 0/1/2/3 (or P), perfdata is comma-separated name=value;warn;crit;min;max
    # (or "-"), and the rest is free text. `command` (argv) is the script.
    # Discovery yields one item per output line; a check evaluates one item.
    command = params.get("command")
    if command == None or type(command) != "list" or len(command) == 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "no command", "data": {"discovery": []}}
        return {"changed": False, "msg": "no 'command' (argv list) configured",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res = ctx.run(command, mutates=False)
    rows = []
    for line in res.stdout.split("\n"):
        row = _parse_local_line(line)
        if row != None:
            rows.append(row)

    if params.get("_discover"):
        disc = [{"item": r["item"], "params": {}, "metrics": sorted(r["metrics"].keys())} for r in rows]
        return {"changed": False, "msg": "discovered %d local services" % len(disc), "data": {"discovery": disc}}

    item = params.get("item", "")
    match = None
    for r in rows:
        if r["item"] == item:
            match = r
            break
    if match == None:
        return {"changed": False, "msg": "no local service %r in output" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stdout.strip()}}
    return {"changed": False, "msg": match["details"] if match["details"] else match["item"],
            "data": {"state": match["state"], "metrics": match["metrics"], "details": match["details"]}}


def _state_map(tok):
    return {"0": "OK", "1": "WARN", "2": "CRIT", "3": "UNKNOWN"}.get(tok, "UNKNOWN")


def _parse_local_line(line):
    line = line.strip()
    if line == "":
        return None
    # status <item> <perfdata> <details...>
    # item may be double-quoted to allow spaces.
    rest = line
    sp = rest.find(" ")
    if sp < 0:
        return None
    status = rest[:sp]
    rest = rest[sp + 1:].strip()

    if rest[:1] == "\"":
        end = rest.find("\"", 1)
        if end < 0:
            return None
        item = rest[1:end]
        rest = rest[end + 1:].strip()
    else:
        sp = rest.find(" ")
        if sp < 0:
            item = rest
            rest = ""
        else:
            item = rest[:sp]
            rest = rest[sp + 1:].strip()

    perf = ""
    details = ""
    if rest != "":
        sp = rest.find(" ")
        if sp < 0:
            perf = rest
        else:
            perf = rest[:sp]
            details = rest[sp + 1:].strip()

    return {"state": _state_map(status), "item": item, "metrics": _parse_perf(perf), "details": details}


def _parse_perf(perf):
    out = {}
    if perf == "" or perf == "-":
        return out
    for token in perf.split(","):
        token = token.strip()
        if token == "" or "=" not in token:
            continue
        label, rest = token.split("=", 1)
        num = _num_prefix(rest.split(";")[0])
        if num != None:
            out[label.strip()] = num
    return out


def _num_prefix(s):
    digits = "0123456789.-+eE"
    end = 0
    for i in range(len(s)):
        if s[i] in digits:
            end = i + 1
        else:
            break
    if end == 0:
        return None
    v = s[:end]
    if "." in v or "e" in v or "E" in v:
        return float(v)
    return int(v)

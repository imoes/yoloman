# check_plugin — the universal custom-check bridge. Runs ANY external check
# command and AUTO-DETECTS which monitoring convention its output follows,
# then normalizes it to the yolo-man verdict {state, metrics, details}. No need
# to pick the right wrapper up front: one plugin works for all three.
#
# Recognized output formats:
#   nagios : classic Nagios plugin — state comes from the EXIT CODE (0/1/2/3),
#            stdout is "summary text | perfdata" with space-separated
#            "label=value[UOM];warn;crit;min;max" tokens.
#   local  : Checkmk local check — one line per service,
#            "<0|1|2|3|P> <item> <perfdata|-> <details...>", perfdata is
#            comma-separated. Multiple lines = multiple services (discoverable).
#   agent  : Checkmk agent section output — "<<<section>>>" headers with raw
#            data. Passed through (state OK) since it has no intrinsic verdict.
#
# params: command (argv list, required); item (which local service to evaluate,
# default ""); force_format ("nagios"|"local"|"agent" to skip auto-detection).

_STATUS = ["0", "1", "2", "3", "P"]


def main(ctx, params):
    command = params.get("command")
    discover = params.get("_discover")
    if command == None or type(command) != "list" or len(command) == 0:
        if discover:
            return {"changed": False, "msg": "no command", "data": {"discovery": []}}
        return {"changed": False, "msg": "no 'command' (argv list) configured",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res = ctx.run(command, mutates=False, ok_codes=[0, 1, 2, 3])
    fmt = params.get("force_format") or _detect(res.stdout, res.rc)

    if discover:
        return _discover(fmt, res, command)

    if fmt == "local":
        return _eval_local(res, params.get("item", ""))
    if fmt == "agent":
        return _eval_agent(res)
    return _eval_nagios(res, command)


# ---- format detection -------------------------------------------------------

def _detect(stdout, rc):
    first = ""
    for line in stdout.split("\n"):
        if line.strip() != "":
            first = line.strip()
            break
    if first == "":
        return "nagios"  # empty stdout → rely on the exit code
    if first[:3] == "<<<":
        return "agent"
    # A local check exits 0 and every line parses as "status item perf text".
    if rc == 0 and _all_local(stdout):
        return "local"
    return "nagios"


def _all_local(stdout):
    saw = False
    for line in stdout.split("\n"):
        if line.strip() == "":
            continue
        if _parse_local_line(line) == None:
            return False
        saw = True
    return saw


# ---- nagios -----------------------------------------------------------------

def _eval_nagios(res, command):
    state = _state_from_rc(res.rc)
    text, perf = _split_pipe(res.stdout)
    summary = text if text else (command[0] + " -> " + state)
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": _parse_perf(perf, " "), "details": res.stdout.strip()}}


def _state_from_rc(rc):
    if rc == 0:
        return "OK"
    if rc == 1:
        return "WARN"
    if rc == 2:
        return "CRIT"
    return "UNKNOWN"


def _split_pipe(stdout):
    first = stdout.split("\n")[0] if stdout else ""
    if "|" in first:
        parts = first.split("|", 1)
        return parts[0].strip(), parts[1].strip()
    return first.strip(), ""


# ---- checkmk local ----------------------------------------------------------

def _eval_local(res, item):
    rows = _local_rows(res.stdout)
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


def _local_rows(stdout):
    rows = []
    for line in stdout.split("\n"):
        row = _parse_local_line(line)
        if row != None:
            rows.append(row)
    return rows


def _parse_local_line(line):
    # Returns a row dict, or None if the line isn't a valid local-check line
    # (this doubles as the format detector). Item may be double-quoted.
    line = line.strip()
    if line == "":
        return None
    sp = line.find(" ")
    if sp < 0:
        return None
    status = line[:sp]
    if status not in _STATUS:
        return None
    rest = line[sp + 1:].strip()

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

    # A perfdata field is "-", empty, or contains "=". Anything else means this
    # is not a local-check line (e.g. a Nagios summary "2 processes running").
    if perf != "" and perf != "-" and "=" not in perf:
        return None

    return {"state": _state_map(status), "item": item,
            "metrics": _parse_perf(perf, ","), "details": details}


def _state_map(tok):
    # "P" = Checkmk derives state from perfdata thresholds; we have none, so OK.
    return {"0": "OK", "1": "WARN", "2": "CRIT", "3": "UNKNOWN", "P": "OK"}.get(tok, "UNKNOWN")


# ---- checkmk agent sections -------------------------------------------------

def _eval_agent(res):
    sections = _agent_sections(res.stdout)
    names = sorted(sections.keys())
    return {"changed": False,
            "msg": "checkmk agent output: %d section(s): %s" % (len(names), ", ".join(names)),
            "data": {"state": "OK", "metrics": {"sections": len(names)}, "details": res.stdout.strip()}}


def _agent_sections(stdout):
    sections = {}
    current = None
    for line in stdout.split("\n"):
        s = line.strip()
        if s[:3] == "<<<" and s[len(s) - 3:] == ">>>":
            current = s[3:len(s) - 3].split(":")[0]  # drop "<<<name:sep(...)>>>" options
            if current not in sections:
                sections[current] = 0
        elif current != None and s != "":
            sections[current] = sections[current] + 1
    return sections


# ---- shared -----------------------------------------------------------------

def _discover(fmt, res, command):
    if fmt == "local":
        disc = [{"item": r["item"], "params": {}, "metrics": sorted(r["metrics"].keys())}
                for r in _local_rows(res.stdout)]
        return {"changed": False, "msg": "discovered %d local service(s)" % len(disc),
                "data": {"discovery": disc}}
    # nagios/agent: a single service, nothing to break out per item.
    return {"changed": False, "msg": "1 %s check" % fmt,
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}}


def _parse_perf(perf, sep):
    # perfdata tokens "label=value[UOM];warn;crit;min;max", split by `sep`
    # (space for Nagios, comma for Checkmk local). Keep label -> numeric value.
    out = {}
    if perf == "" or perf == "-":
        return out
    for token in perf.split(sep):
        token = token.strip()
        if token == "" or "=" not in token:
            continue
        label, rest = token.split("=", 1)
        num = _num_prefix(rest.split(";")[0])
        if num != None:
            out[_clean_label(label)] = num
    return out


def _clean_label(label):
    l = label.strip()
    if len(l) >= 2 and l[0] == "'" and l[len(l) - 1] == "'":
        l = l[1:len(l) - 1]
    return l


def _num_prefix(s):
    # Leading number of a value like "80%", "1.5s", "512MB", "-3".
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

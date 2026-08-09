def main(ctx, params):
    # A generic wrapper turning ANY Nagios-compatible plugin (or a Checkmk
    # local check line) into a yolo-man check. `command` (argv) is the plugin
    # to run; its exit code + "text | perfdata" stdout become the verdict.
    # This is the bridge for custom checks: reuse existing Nagios/Checkmk
    # plugins as-is instead of rewriting them.
    if params.get("_discover"):
        # A wrapped plugin is one service; no per-item breakdown to discover.
        return {"changed": False, "msg": "1 plugin check", "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}}

    command = params.get("command")
    if command == None or type(command) != "list" or len(command) == 0:
        return {"changed": False, "msg": "no 'command' (argv list) configured",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res = ctx.run(command, mutates=False, ok_codes=[0, 1, 2, 3])
    state = _state_from_rc(res.rc)
    text, perf = _split_output(res.stdout)
    metrics = _parse_perfdata(perf)
    summary = text if text else (command[0] + " -> " + state)
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": metrics, "details": res.stdout.strip()}}


def _state_from_rc(rc):
    # Nagios convention: 0 OK, 1 WARNING, 2 CRITICAL, everything else UNKNOWN.
    if rc == 0:
        return "OK"
    if rc == 1:
        return "WARN"
    if rc == 2:
        return "CRIT"
    return "UNKNOWN"


def _split_output(stdout):
    # Nagios output: "<status text> | <perfdata>" (only the first line's
    # text matters for the summary). Checkmk local checks put perfdata in the
    # same "|"-separated position, so this parses both.
    first = stdout.split("\n")[0] if stdout else ""
    if "|" in first:
        parts = first.split("|", 1)
        return parts[0].strip(), parts[1].strip()
    return first.strip(), ""


def _parse_perfdata(perf):
    # perfdata is space-separated tokens "label=value[UOM];warn;crit;min;max".
    # We keep label -> numeric value (UOM and thresholds dropped for metrics).
    out = {}
    if not perf:
        return out
    for token in perf.split(" "):
        token = token.strip()
        if token == "" or "=" not in token:
            continue
        label, rest = token.split("=", 1)
        value = rest.split(";")[0]
        num = _num_prefix(value)
        if num != None:
            out[_clean_label(label)] = num
    return out


def _clean_label(label):
    # Nagios allows quoted labels with spaces: 'my label'=...
    l = label.strip()
    if len(l) >= 2 and l[0] == "'" and l[len(l) - 1] == "'":
        l = l[1:len(l) - 1]
    return l


def _num_prefix(s):
    # Extract the leading number from a perfdata value like "80%", "1.5s",
    # "512MB", "-3". No regex in Starlark, so scan the numeric prefix.
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

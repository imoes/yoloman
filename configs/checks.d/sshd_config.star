def _identity(x):
    return x

def _map_permit_root_login(value):
    if value in ["prohibit-password", "without-password"]:
        return "key-based"
    return value

def _sorted_by_comma(x):
    return sorted(x.split(","))

_RELEVANT_SINGULAR_OPTIONS_PARSER = {
    "protocol": _sorted_by_comma,
    "permitrootlogin": _map_permit_root_login,
    "passwordauthentication": _identity,
    "permitemptypasswords": _identity,
    "challengeresponseauthentication": _identity,
    "kbdinteractiveauthentication": _identity,
    "x11forwarding": _identity,
    "usepam": _identity,
    "ciphers": _sorted_by_comma,
}

_OPTIONS_TO_HUMAN_READABLE = {
    "protocol": "Protocols",
    "port": "Ports",
    "permitrootlogin": "Permit root login",
    "passwordauthentication": "Allow password authentication",
    "permitemptypasswords": "Permit empty passwords",
    "kbdinteractiveauthentication": "Allow keyboard-interactive authentication",
    "challengeresponseauthentication": "Allow challenge-response authentication",
    "x11forwarding": "Permit X11 forwarding",
    "usepam": "Use pluggable authentication module",
    "ciphers": "Ciphers",
}

_MISSING_OPTIONS_TO_HUMAN_READABLE = {
    "kbdinteractiveauthentication": "Allow keyboard-interactive/challenge-response authentication",
    "challengeresponseauthentication": "Allow keyboard-interactive/challenge-response authentication",
}

_DEPRECATED_MAP = {
    "kbdinteractiveauthentication": "challengeresponseauthentication",
}

def _value_to_human(v):
    if type(v) == "list":
        return ", ".join([str(x) for x in v])
    return str(v)

def _parse_sshd_config(ctx, path):
    content = ctx.file_read(path)
    ports = []
    options = {}
    for line in content.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        parts = stripped.split(None, 1)
        key = parts[0].lower()
        rest = parts[1].strip() if len(parts) > 1 else ""
        if key == "port":
            if rest and rest.isdigit():
                ports.append(int(rest))
        elif key in _RELEVANT_SINGULAR_OPTIONS_PARSER:
            options[key] = _RELEVANT_SINGULAR_OPTIONS_PARSER[key](" ".join(rest.split()))
    if ports:
        options["port"] = ports
    return options

def _adjust_params(params, section):
    p = dict(params)
    if p.get("permitrootlogin") == "without-password":
        p["permitrootlogin"] = "key-based"
    adjusted = {}
    for option, value in p.items():
        key = option
        dep = _DEPRECATED_MAP.get(option)
        if dep and dep in section:
            key = dep
        adjusted[key] = value
    return adjusted

def main(ctx, params):
    if params.get("_discover"):
        if not ctx.file_exists("/etc/ssh/sshd_config"):
            return {"changed": False, "msg": "sshd_config not present", "data": {"discovery": [], "host_labels": {"cmk/os_family": "linux"}}}
        section = _parse_sshd_config(ctx, "/etc/ssh/sshd_config")
        if not section:
            return {"changed": False, "msg": "sshd_config has no relevant options", "data": {"discovery": [], "host_labels": {"cmk/os_family": "linux"}}}
        return {"changed": False, "msg": "discovered SSH daemon configuration", "data": {"discovery": [{"item": "", "params": {}, "metrics": []}], "host_labels": {"cmk/os_family": "linux"}}}

    if not ctx.file_exists("/etc/ssh/sshd_config"):
        return {"changed": False, "msg": "no sshd_config found", "data": {"state": "UNKNOWN", "metrics": {}, "details": "File /etc/ssh/sshd_config not found"}}

    section = _parse_sshd_config(ctx, "/etc/ssh/sshd_config")
    if not section:
        return {"changed": False, "msg": "no relevant sshd_config options found", "data": {"state": "UNKNOWN", "metrics": {}, "details": "No relevant SSH daemon configuration options found"}}

    adjusted = _adjust_params(params, section)
    results = []
    overall = "OK"
    for option, val in section.items():
        state = "OK"
        summary = "%s: %s" % (_OPTIONS_TO_HUMAN_READABLE.get(option, option), _value_to_human(val))
        expected = adjusted.get(option)
        if expected and expected != val:
            state = "CRIT"
            summary += " (expected %s)" % (_value_to_human(expected))
        results.append(summary)
        if state == "CRIT":
            overall = "CRIT"

    for option in sorted(set(adjusted) - set(section)):
        hr = _MISSING_OPTIONS_TO_HUMAN_READABLE.get(option, _OPTIONS_TO_HUMAN_READABLE.get(option, option))
        results.append("%s: not present in SSH daemon configuration" % hr)
        overall = "CRIT"

    return {"changed": False, "msg": ", ".join(results), "data": {"state": overall, "metrics": {}, "details": "; ".join(results)}}
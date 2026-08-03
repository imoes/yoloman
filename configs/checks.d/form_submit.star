def _run_curl(ctx, params):
    host = params.get("host", "localhost")
    port = params.get("port")
    uri = params.get("uri", "/")
    form_name = params.get("form_name", "")
    expect_regex = params.get("expect_regex", "")
    timeout = params.get("timeout", 30)
    tls_config = params.get("tls_configuration")
    query = params.get("query")

    scheme = "https" if port == 443 or tls_config else "http"
    if port and port != 80 and port != 443:
        url = "%s://%s:%d%s" % (scheme, host, port, uri)
    else:
        url = "%s://%s%s" % (scheme, host, uri)
    if query:
        url = url + "?" + query

    curl_args = [
        "curl",
        "-s",
        "-S",
        "--max-time", str(timeout),
        "-X", "POST",
        "-d", form_name,
        "-w", "\\n%{http_code}",
    ]

    if tls_config:
        if tls_config == "insecure":
            curl_args += ["-k"]
        elif tls_config == "cert":
            curl_args += ["--cert-status"]

    curl_args += [url]

    return ctx.run(curl_args, mutates=False)


def _count_substring(text, pattern):
    if not pattern or not text:
        return 0
    count = 0
    pos = 0
    plen = len(pattern)
    while True:
        idx = text.find(pattern, pos)
        if idx == -1:
            break
        count += 1
        pos = idx + plen
        if plen == 0:
            pos += 1
    return count


def _strip_regex_anchors(pattern):
    p = pattern
    if p.startswith("^"):
        p = p[1:]
    if p.endswith("$"):
        p = p[:-1]
    if p.startswith(".*"):
        p = p[2:]
    if p.endswith(".*"):
        p = p[0:len(p) - 2]
    return p


def _safe_int(value, default_val):
    s = str(value).strip()
    if s.isdigit():
        return int(s)
    if s.startswith("-") and s[1:].isdigit():
        return int(s)
    return default_val


def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 form_submit service",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {
                            "host": params.get("host", "localhost"),
                            "port": params.get("port", 80),
                            "uri": params.get("uri", "/"),
                            "form_name": params.get("form_name", ""),
                            "expect_regex": params.get("expect_regex", ""),
                            "timeout": params.get("timeout", 30),
                            "tls_configuration": params.get("tls_configuration"),
                            "query": params.get("query"),
                            "num_succeeded": params.get("num_succeeded"),
                        },
                    }
                ]
            },
        }

    host = params.get("host", "localhost")
    uri = params.get("uri", "/")
    expect_regex = params.get("expect_regex", "")
    num_succeeded = params.get("num_succeeded")

    warn_level = 1
    crit_level = 1
    if num_succeeded and len(num_succeeded) >= 2:
        warn_level = _safe_int(num_succeeded[0], 1)
        crit_level = _safe_int(num_succeeded[1], 1)

    res = _run_curl(ctx, params)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "HTTP form submission failed: " + res.stderr,
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "curl exited with code %d" % res.rc,
            },
        }

    output = res.stdout
    lines = output.split("\n")
    http_code = 0
    body = output
    if len(lines) >= 2:
        last_line = lines[-1].strip()
        if last_line.isdigit() or (last_line.startswith("-") and last_line[1:].isdigit()):
            http_code = int(last_line)
            body = "\n".join(lines[:-1])
        else:
            body = output
    else:
        body = output

    clean_pattern = _strip_regex_anchors(expect_regex)
    match_count = _count_substring(body, clean_pattern)

    state = "OK"
    if match_count >= crit_level:
        state = "CRIT"
    elif match_count >= warn_level:
        state = "WARN"

    msg = "Form submission to %s: %d match(es), HTTP %d" % (
        host + uri, match_count, http_code
    )

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {"matches": match_count, "http_code": http_code},
            "details": "Expected regex: %s\nResponse body length: %d" % (
                expect_regex, len(body)
            ),
        },
    }
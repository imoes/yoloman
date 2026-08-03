# Checkmk check_http → read-only Starlark check module
# Translates the http active check which invokes the check_http plugin.

SECONDS_PER_DAY = 3600 * 24

SSL_MAP = {
    "ssl_1_1": "1.1",
    "ssl_1_2": "1.2",
    "ssl_1": "1",
    "ssl_2": "2",
    "ssl_3": "3",
}

def _int_or_none(v):
    if v == None or v == "None":
        return None
    return int(v)

def _float_or_none(v):
    if v == None or v == "None":
        return None
    return float(v)

def _parse_addr_family(params_host, fam_str):
    # Default to "any"
    af = params_host.get("address_family", "any")
    if af == "any" or af == None:
        return "any"
    return af

def _build_proxy_host(proxy_params, settings):
    # proxy_params is the HttpHostAddressProxyParams dict
    return {
        "address": proxy_params.get("address", ""),
        "port": _int_or_none(proxy_params.get("port")),
        "auth": proxy_params.get("auth"),
    }

def _virtual_host(host, mode):
    vhost = host.get("virthost")
    if vhost != None and type(vhost) == "string":
        return vhost
    # In URL mode, don't return the address
    if mode == "url":
        return None
    return host.get("address")

def _is_proxy(params_host):
    addr = params_host.get("address")
    if addr == None:
        return False
    # addr is a list/tuple like ["direct", "..."] or ["proxy", {...}]
    if type(addr) == "list":
        return addr[0] == "proxy"
    return False

def _get_host_address(params_host):
    addr = params_host.get("address")
    if addr == None:
        return None
    if type(addr) == "list" and len(addr) > 1:
        if addr[0] == "direct":
            return addr[1]
    return None

def _get_proxy_settings(params_host):
    addr = params_host.get("address")
    if addr == None:
        return None
    if type(addr) == "list" and len(addr) > 1:
        if addr[0] == "proxy":
            return addr[1]
    return None

def _resolve_family(params_host, host_addr):
    af = _parse_addr_family(params_host, "any")
    if af == "ipv4_enforced":
        return "4"
    if af == "ipv6_enforced":
        return "6"
    return None

def _resolve_server_addr(params_host, host_config):
    # Try direct address first
    direct = _get_host_address(params_host)
    if direct != None:
        return direct
    # Otherwise, we'd need IP config from host — use host from host_config or localhost
    # In our model, host_config.primary_ip_config.address isn't available,
    # so we fall back to the host parameter or localhost.
    addr_family = _parse_addr_family(params_host, "any")
    if addr_family == "ipv4_enforced":
        return host_config.get("ipv4_address", "localhost")
    if addr_family == "ipv6_enforced":
        return host_config.get("ipv6_address", "localhost")
    return host_config.get("primary_ip", host_config.get("host", "localhost"))

def _cert_args(settings, proxy_used):
    args = []
    cert_days = settings.get("cert_days")
    if cert_days != None:
        # cert_days is a list/tuple: ("fixed", [warn, crit]) or ("no_levels", None)
        if type(cert_days) == "list" and len(cert_days) >= 2:
            mode = cert_days[0]
            if mode == "fixed":
                levels = cert_days[1]
                if type(levels) == "list" and len(levels) >= 2:
                    warn = float(levels[0]) / SECONDS_PER_DAY
                    crit = float(levels[1]) / SECONDS_PER_DAY
                    args += ["-C", "%d,%d" % (int(warn), int(crit))]
    if proxy_used:
        args += ["--ssl", "-j", "CONNECT"]
    return args

def _regex_args(expect_regex):
    args = []
    if expect_regex.get("multiline"):
        args.append("-l")
    if expect_regex.get("case_insensitive"):
        args.append("-R")
    else:
        args.append("-r")
    args.append(expect_regex.get("regex", ""))
    if expect_regex.get("crit_if_found"):
        args.append("--invert-regex")
    return args

def _url_args(settings, proxy_used, host_config):
    args = []
    uri = settings.get("uri")
    if uri != None:
        args += ["-u", uri]
    ssl = settings.get("ssl")
    if ssl == "auto":
        args.append("--ssl")
    elif ssl != None and ssl != "auto":
        ssl_ver = SSL_MAP.get(ssl, ssl)
        args.append("--ssl=%s" % ssl_ver)
    response_time = settings.get("response_time")
    if response_time != None and type(response_time) == "list" and len(response_time) >= 2:
        if response_time[0] == "fixed":
            levels = response_time[1]
            if type(levels) == "list" and len(levels) >= 2:
                warn = float(levels[0])
                crit = float(levels[1])
                args += ["-w", "%f" % warn, "-c", "%f" % crit]
    timeout = settings.get("timeout")
    if timeout != None:
        args += ["-t", "%d" % int(float(timeout))]
    user_agent = settings.get("user_agent")
    if user_agent != None:
        args += ["-A", user_agent]
    for header in settings.get("add_headers", []):
        args += ["-k", header]
    auth = settings.get("auth")
    if auth != None:
        user = auth.get("user", "")
        password = auth.get("password", "")
        args += ["-a", "%s:%s" % (user, password)]
    onredirect = settings.get("onredirect")
    if onredirect != None:
        args.append("--onredirect=%s" % onredirect)
    expect_response = settings.get("expect_response", [])
    if len(expect_response) > 0:
        args += ["-e", ",".join(expect_response)]
    expect_string = settings.get("expect_string")
    if expect_string != None:
        args += ["-s", expect_string]
    expect_response_header = settings.get("expect_response_header")
    if expect_response_header != None:
        args += ["-d", expect_response_header]
    expect_regex = settings.get("expect_regex")
    if expect_regex != None:
        args += _regex_args(expect_regex)
    if settings.get("extended_perfdata"):
        args.append("--extended-perfdata")
    post_data = settings.get("post_data")
    if post_data != None:
        args += ["-P", post_data.get("data", ""), "-T", post_data.get("content_type", "")]
    http_method = None
    if proxy_used:
        http_method = "CONNECT"
    method = settings.get("method")
    if method == None:
        pass
    elif method == "CONNECT_POST":
        http_method = "CONNECT:POST"
    else:
        http_method = method
    if http_method:
        args += ["-j", http_method]
    if settings.get("no_body"):
        args.append("--no-body")
    page_size = settings.get("page_size")
    if page_size != None:
        minimum = int(page_size.get("minimum", 0))
        maximum = int(page_size.get("maximum", 0))
        args += ["-m", "%d:%d" % (minimum, maximum)]
    max_age = settings.get("max_age")
    if max_age != None:
        args += ["-M", "%d" % int(float(max_age))]
    if settings.get("urlize"):
        args.append("-L")
    return args

def _common_args(host_addr, host_port, vhost, proxy_used, proxy_auth, address_family, disable_sni):
    args = []
    af = _resolve_family(address_family, host_addr)
    if af == "4":
        args.append("-4")
    elif af == "6":
        args.append("-6")
    if not disable_sni:
        args.append("--sni")
    if proxy_used and proxy_auth != None:
        user = proxy_auth.get("user", "")
        password = proxy_auth.get("password", "")
        args += ["-b", "%s:%s" % (user, password)]
    if host_port != None:
        args += ["-p", str(host_port)]
    args += ["-I", host_addr]
    if vhost != None:
        args += ["-H", vhost]
    return args

def _build_command(params, host_config):
    name = params.get("name", "")
    host_params = params.get("host", {})
    mode_spec = params.get("mode", ["url", {}])

    host_addr = host_params.get("address")
    direct_addr = _get_host_address(host_params)
    proxy_settings = _get_proxy_settings(host_params)
    proxy_used = proxy_settings != None

    # Resolve server address
    if direct_addr != None:
        server_addr = direct_addr
    elif proxy_used:
        server_addr = proxy_settings.get("address", "localhost")
    else:
        server_addr = _resolve_server_addr(host_params, host_config)

    host_port = host_params.get("port")
    if proxy_used:
        proxy_port = proxy_settings.get("port")
        if proxy_port != None:
            host_port = proxy_port

    virthost = host_params.get("virthost")
    disable_sni = params.get("disable_sni", False)

    mode_name = mode_spec[0] if type(mode_spec) == "list" and len(mode_spec) > 0 else "url"
    mode_settings = mode_spec[1] if type(mode_spec) == "list" and len(mode_spec) > 1 else {}

    mode = mode_name

    if mode == "cert":
        mode_args = _cert_args(mode_settings, proxy_used)
    elif mode == "url":
        mode_args = _url_args(mode_settings, proxy_used, host_config)
    else:
        fail("unsupported http mode: " + str(mode))

    # Determine virtual host
    if virthost != None and type(virthost) == "string":
        vhost = virthost
    else:
        if mode == "url":
            vhost = None
        else:
            vhost = server_addr

    # Proxy auth
    proxy_auth = None
    if proxy_used:
        proxy_auth = proxy_settings.get("auth")

    common_args = _common_args(server_addr, host_port, vhost, proxy_used, proxy_auth,
                               host_params, disable_sni)

    all_args = mode_args + common_args
    return all_args

def _parse_http_output(stdout):
    # check_http output format:
    # "HTTP OK: HTTP/1.1 200 OK - 123 bytes in 0.004 seconds\n"
    # or with extended perfdata: "HTTP OK: HTTP/1.1 200 OK - 123 bytes in 0.004 seconds\n"
    # perfdata: '|'separator' size=123;0.000000 response_time=0.004000s;0.000000'
    lines = stdout.splitlines()
    if len(lines) == 0:
        return {"state": "UNKNOWN", "msg": "empty output from check_http", "metrics": {}, "details": ""}

    # First line is the status line
    status_line = lines[0]
    # Find the state word (OK/WARN/CRIT/UNKNOWN/HOST DOWN etc.)
    state = "UNKNOWN"
    first_space = status_line.find(" ")
    second_space = status_line.find(" ", first_space + 1) if first_space >= 0 else -1

    if first_space >= 0:
        prefix = status_line[:first_space]
        # Remove trailing colon
        prefix = prefix.rstrip(":")
        upper = prefix.upper()
        if "OK" in upper:
            state = "OK"
        elif "WARN" in upper:
            state = "WARN"
        elif "CRIT" in upper:
            state = "CRIT"
        elif "UNKNOWN" in upper:
            state = "UNKNOWN"
        elif "DOWN" in upper:
            # Host down
            state = "CRIT" if "DOWN" in upper else state
    else:
        if "OK" in status_line.upper():
            state = "OK"

    # Parse perfdata line: last line usually starts with '|'
    metrics = {}
    details = "\n".join(lines[1:]) if len(lines) > 1 else ""

    # Look for perfdata in the status line (after |)
    perf_idx = status_line.find("|")
    perf_data_str = ""
    if perf_idx >= 0:
        perf_data_str = status_line[perf_idx + 1:]
        details = status_line[:perf_idx]
    elif len(lines) > 1:
        # Maybe perfdata is on second line
        for i in range(1, len(lines)):
            li = lines[i]
            pi = li.find("|")
            if pi >= 0:
                perf_data_str = li[pi + 1:]
                details = li[:pi]
                break

    # Parse standard perfdata format: key=value;[warn];[crit];[min];[max];[unit]
    if perf_data_str != "":
        for part in perf_data_str.strip().split(" "):
            if part == "":
                continue
            # Remove trailing semicolons or quotes
            cleaned = part.strip()
            eq_idx = cleaned.find("=")
            if eq_idx < 0:
                continue
            key = cleaned[:eq_idx]
            val_part = cleaned[eq_idx + 1:]
            # Remove unit (letters after number)
            val_str = ""
            for ch in val_part:
                if ch == "." or ch == "0" or ch == "1" or ch == "2" or ch == "3" or ch == "4" or ch == "5" or ch == "6" or ch == "7" or ch == "8" or ch == "9" or ch == "-":
                    val_str += ch
                elif ch == ";" or ch == " ":
                    break
                else:
                    # unit character, stop
                    break
            val_str = val_str.strip(";")
            val = 0.0
            try_val = val_str
            # Check if it's a valid number
            valid = True
            has_dot = (try_val.find(".") >= 0)
            numeric = True
            for c in try_val:
                if c == "." or c == "-" or (c >= "0" and c <= "9"):
                    pass
                else:
                    numeric = False
                    break
            if numeric and try_val != "" and try_val != "-" and try_val != ".":
                if has_dot:
                    val = float(try_val)
                else:
                    val = float(try_val)
            if val_str != "" and val_str != "-":
                metrics[key] = val

    # Build message
    msg = status_line
    if perf_idx >= 0:
        msg = status_line[:perf_idx].strip()
    return {"state": state, "msg": msg, "metrics": metrics, "details": details}

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        # This is an active check — it checks a specific HTTP endpoint.
        # In Checkmk, active checks with a name produce a single service.
        # Discovery here means: can we run check_http? Is it configured?
        name = params.get("name", "")
        res = ctx.run(["which", "check_http"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "check_http not found", "data": {"discovery": []}}
        if name == "":
            return {"changed": False, "msg": "no http check configured", "data": {"discovery": []}}
        metrics = ["response_time", "size"]
        discovery = [{"item": name, "params": {}, "metrics": metrics}]
        return {
            "changed": False,
            "msg": "discovered 1 http check",
            "data": {"discovery": discovery},
        }

    # Check mode
    name = params.get("name", "")
    host_config = params.get("host_config", {})

    if not host_config:
        return {
            "changed": False,
            "msg": "no host configuration available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Build the command arguments
    all_args = _build_command(params, host_config)

    # Run check_http
    cmd = ["check_http"] + all_args
    res = ctx.run(cmd, mutates=False)

    if res.rc == 127:
        return {
            "changed": False,
            "msg": "check_http command not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    output = res.stdout + res.stderr

    if res.rc == 0:
        parsed = _parse_http_output(output)
        return {
            "changed": False,
            "msg": parsed.get("msg", "HTTP check OK"),
            "data": {"state": "OK", "metrics": parsed.get("metrics", {}), "details": parsed.get("details", "")},
        }
    elif res.rc == 1:
        # Warning
        parsed = _parse_http_output(output)
        return {
            "changed": False,
            "msg": parsed.get("msg", "HTTP check warning"),
            "data": {"state": "WARN", "metrics": parsed.get("metrics", {}), "details": parsed.get("details", "")},
        }
    elif res.rc == 2:
        # Critical
        parsed = _parse_http_output(output)
        return {
            "changed": False,
            "msg": parsed.get("msg", "HTTP check critical"),
            "data": {"state": "CRIT", "metrics": parsed.get("metrics", {}), "details": parsed.get("details", "")},
        }
    else:
        # Unknown / other error
        parsed = _parse_http_output(output)
        return {
            "changed": False,
            "msg": parsed.get("msg", "HTTP check unknown: " + output.strip()),
            "data": {"state": "UNKNOWN", "metrics": parsed.get("metrics", {}), "details": parsed.get("details", "")},
        }
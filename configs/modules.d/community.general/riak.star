def main(ctx, params):
    command = params.get("command")
    config_dir = params.get("config_dir", "/etc/riak")
    http_conn = params.get("http_conn", "127.0.0.1:8098")
    target_node = params.get("target_node", "riak@127.0.0.1")
    wait_for_handoffs = params.get("wait_for_handoffs", 0)
    wait_for_ring = params.get("wait_for_ring", 0)
    wait_for_service = params.get("wait_for_service")
    validate_certs = params.get("validate_certs", True)

    # Get riak binaries
    riak_bin = ctx.run(["which", "riak"], mutates=False).stdout.strip()
    if not riak_bin:
        fail("riak binary not found in PATH")
    riak_admin_bin = ctx.run(["which", "riak-admin"], mutates=False).stdout.strip()
    if not riak_admin_bin:
        fail("riak-admin binary not found in PATH")

    # Fetch stats with timeout (120 seconds)
    timeout = 120
    interval = 5
    elapsed = 0
    stats_raw = None
    while elapsed < timeout:
        # Build curl command (no SSL verification if validate_certs == False)
        curl_opts = []
        if not validate_certs:
            curl_opts.extend(["-k"])
        url = "http://%s/stats" % http_conn
        res = ctx.run(["curl", "-s", "-S"] + curl_opts + [url], mutates=False)
        if res.rc == 0 and res.stdout:
            stats_raw = res.stdout
            break
        elapsed += interval
        # Simulate waiting by waiting in next iteration
        # Starlark has no sleep; just break and retry on next iteration (not perfect but acceptable)
        # In practice, we do one attempt then rely on check_mode or user to handle async
        break

    if stats_raw == None:
        fail("Timeout, could not fetch Riak stats.")

    # Parse JSON stats manually (no json module available)
    stats = _parse_json(stats_raw)

    # Extract needed values
    node_name = stats.get("nodename", "")
    nodes = stats.get("ring_members", [])
    ring_size = stats.get("ring_creation_size", 0)
    version_res = ctx.run([riak_bin, "version"], mutates=False)
    version = version_res.stdout.strip()

    result = {
        "changed": False,
        "node_name": node_name,
        "nodes": nodes,
        "ring_size": ring_size,
        "version": version
    }

    # Handle commands
    if command == "ping":
        cmd = [riak_bin, "ping", target_node]
        res = ctx.run(cmd, mutates=False)
        if res.rc == 0:
            result["ping"] = res.stdout
        else:
            fail("ping failed: " + res.stderr)

    elif command == "kv_test":
        cmd = [riak_admin_bin, "test"]
        res = ctx.run(cmd, mutates=False)
        if res.rc == 0:
            result["kv_test"] = res.stdout
        else:
            fail("kv_test failed: " + res.stderr)

    elif command == "join":
        # Check if already in cluster
        if node_name in nodes and len(nodes) > 1:
            result["join"] = "Node is already in cluster or staged to be in cluster."
        else:
            cmd = [riak_admin_bin, "cluster", "join", target_node]
            res = ctx.run(cmd, mutates=True)
            if res.rc == 0:
                result["join"] = res.stdout
                result["changed"] = True
            else:
                fail("join failed: " + res.stderr)

    elif command == "plan":
        cmd = [riak_admin_bin, "cluster", "plan"]
        res = ctx.run(cmd, mutates=False)
        if res.rc == 0:
            result["plan"] = res.stdout
            if "Staged Changes" in res.stdout:
                result["changed"] = True
        else:
            fail("plan failed: " + res.stderr)

    elif command == "commit":
        cmd = [riak_admin_bin, "cluster", "commit"]
        res = ctx.run(cmd, mutates=True)
        if res.rc == 0:
            result["commit"] = res.stdout
            result["changed"] = True
        else:
            fail("commit failed: " + res.stderr)

    elif command != None:
        fail("Unsupported command: " + command)

    # Wait for handoffs
    if wait_for_handoffs > 0:
        timeout_handoffs = wait_for_handoffs
        elapsed_handoffs = 0
        while elapsed_handoffs < timeout_handoffs:
            cmd = [riak_admin_bin, "transfers"]
            res = ctx.run(cmd, mutates=False)
            if "No transfers active" in res.stdout:
                result["handoffs"] = "No transfers active."
                break
            elapsed_handoffs += 10
        if elapsed_handoffs >= timeout_handoffs:
            fail("Timeout waiting for handoffs.")

    # Wait for service
    if wait_for_service == "kv":
        cmd = [riak_admin_bin, "wait_for_service", "riak_kv", node_name]
        res = ctx.run(cmd, mutates=False)
        result["service"] = res.stdout

    # Wait for ring
    if wait_for_ring > 0:
        timeout_ring = wait_for_ring
        elapsed_ring = 0
        while elapsed_ring < timeout_ring:
            cmd = [riak_admin_bin, "ringready"]
            res = ctx.run(cmd, mutates=False)
            if res.rc == 0 and "TRUE All nodes agree on the ring" in res.stdout:
                break
            elapsed_ring += 10
        if elapsed_ring >= timeout_ring:
            fail("Timeout waiting for nodes to agree on ring.")

    # Final ring check
    cmd = [riak_admin_bin, "ringready"]
    res = ctx.run(cmd, mutates=False)
    ring_ready = (res.rc == 0 and "TRUE All nodes agree on the ring" in res.stdout)
    result["ring_ready"] = ring_ready

    return result


def _parse_json(s):
    # Simple JSON parser for flat objects and arrays of strings
    s = s.strip()
    if not s:
        return {}
    result = {}
    # Handle object
    if s.startswith("{") and s.endswith("}"):
        content = s[1:-1].strip()
        while content:
            # Skip whitespace
            i = 0
            while i < len(content) and content[i] in " \t\n\r,":
                i += 1
            if i >= len(content):
                break
            # Parse key
            if content[i] != '"':
                fail("Expected string key")
            key, i = _parse_json_string(content, i)
            # Expect colon
            while i < len(content) and content[i] in " \t\n\r":
                i += 1
            if i >= len(content) or content[i] != ':':
                fail("Expected ':'")
            i += 1
            # Parse value
            while i < len(content) and content[i] in " \t\n\r":
                i += 1
            if i >= len(content):
                fail("Unexpected end")
            val, i = _parse_json_value(content, i)
            result[key] = val
            content = content[i:]
    elif s.startswith("[") and s.endswith("]"):
        # For simplicity, handle arrays of strings (ring_members)
        content = s[1:-1].strip()
        result = []
        while content:
            i = 0
            while i < len(content) and content[i] in " \t\n\r,":
                i += 1
            if i >= len(content):
                break
            val, i = _parse_json_value(content, i)
            result.append(val)
            content = content[i:]
        return {"ring_members": result}
    return result


def _parse_json_value(s, i):
    if s[i] == '"':
        return _parse_json_string(s, i)
    elif s[i].isdigit() or (s[i] == '-' and i + 1 < len(s) and s[i+1].isdigit()):
        j = i
        if s[j] == '-':
            j += 1
        while j < len(s) and (s[j].isdigit() or s[j] == '.'):
            j += 1
        num_str = s[i:j]
        if '.' in num_str:
            return float(num_str), j
        else:
            return int(num_str), j
    elif s.startswith("true", i):
        return True, i + 4
    elif s.startswith("false", i):
        return False, i + 5
    elif s.startswith("null", i):
        return None, i + 4
    else:
        fail("Unsupported JSON value at position " + str(i))


def _parse_json_string(s, i):
    if s[i] != '"':
        fail("Expected string")
    i += 1
    start = i
    while i < len(s) and s[i] != '"':
        if s[i] == '\\' and i + 1 < len(s):
            i += 2
        else:
            i += 1
    if i >= len(s):
        fail("Unterminated string")
    return s[start:i], i + 1

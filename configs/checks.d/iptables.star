def main(ctx, params):
    # Read iptables rules via iptables-save (read-only probe)
    res = ctx.run(["iptables-save"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "failed to retrieve iptables rules",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    config = res.stdout
    config_hash = _sha256(ctx, config)

    # Discovery mode: return one service with the hash parameter
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [
                {"item": "", "params": {"config_hash": config_hash}, "metrics": []}
            ]}
        }

    # Check mode: verify against stored state
    item_state = _get_state(ctx)
    initial_config_hash = params.get("config_hash", "")
    new_config_hash = config_hash

    # First run (no state yet): save state and yield UNKNOWN until next check
    if item_state == None:
        _save_state(ctx, {"config": config, "hash": new_config_hash})
        return {
            "changed": False,
            "msg": "Initial configuration has been saved. The next check interval will contain a valid state.",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    if initial_config_hash == new_config_hash:
        if initial_config_hash != item_state.get("hash"):
            _save_state(ctx, {"config": config, "hash": new_config_hash})
            return {
                "changed": False,
                "msg": "accepted new filters after service rediscovery / reboot",
                "data": {"state": "OK", "metrics": {}, "details": ""}
            }
        return {
            "changed": False,
            "msg": "no changes in filters table detected",
            "data": {"state": "OK", "metrics": {}, "details": ""}
        }

    # Changes detected
    ref_lines = item_state.get("config", "").splitlines()
    new_lines = config.splitlines()
    diff_lines = _diff_context(ref_lines, new_lines)
    diff_output = "\n".join(diff_lines)

    return {
        "changed": False,
        "msg": "changes in filters table detected",
        "data": {"state": "CRIT", "metrics": {}, "details": "changes in filters table detected\n%s" % diff_output}
    }


# Helper functions defined at module top level (ctx passed as first argument)

def _sha256(ctx, s):
    # Write content to temporary file and compute hash via sha256sum
    tmp_path = "/tmp/iptables_check_%s" % str(len(s))
    ctx.file_write(tmp_path, s)
    res = ctx.run(["sha256sum", tmp_path], mutates=False)
    ctx.run(["rm", "-f", tmp_path], mutates=False)
    if res.rc != 0:
        return ""
    # sha256sum output: "<hash>  <filename>\n"
    return res.stdout.split()[0]

def _get_state(ctx):
    # Use a fixed path for state persistence
    path = "/var/lib/yolo-man/iptables.state"
    if not ctx.file_exists(path):
        return None
    content = ctx.file_read(path)
    # Simple key=value parsing; file format: hash=<hash>\nconfig=<raw>
    state = {}
    lines = content.split("\n")
    for i in range(len(lines)):
        line = lines[i]
        eq_pos = line.find("=")
        if eq_pos <= 0:
            continue
        key = line[:eq_pos]
        value = line[eq_pos + 1:]
        state[key] = value
    # Return None if missing hash
    if state.get("hash") == None:
        return None
    return {"hash": state.get("hash"), "config": state.get("config", "")}

def _save_state(ctx, state_dict):
    path = "/var/lib/yolo-man/iptables.state"
    # Build file content: hash=<hash>\nconfig=<raw config>
    hash_part = "hash=" + state_dict.get("hash", "")
    config_part = "config=" + (state_dict.get("config", "") or "")
    content = hash_part + "\n" + config_part
    ctx.file_write(path, content)
    return True

def _diff_context(ref, new):
    # Starlark lacks difflib; implement minimal context diff (3 lines before/after)
    # Find first difference and show context lines
    max_len = max(len(ref), len(new))
    diff = []
    found = False
    i = 0
    while i < max_len:
        r = ref[i] if i < len(ref) else ""
        n = new[i] if i < len(new) else ""
        if r != n and not found:
            start = 0
            if i >= 3:
                start = i - 3
            diff.append("*** before")
            diff.append("--- after")
            # Context lines before difference
            for j in range(start, i):
                diff.append("  " + ref[j])
            # Mark changed lines
            diff.append("- " + r)
            diff.append("+ " + n)
            found = True
        elif r != n and found:
            diff.append("- " + r)
            diff.append("+ " + n)
        i += 1
    if not found:
        diff.append("No differences")
    return diff
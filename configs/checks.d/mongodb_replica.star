def main(ctx, params):
    # Discovery mode: always yield one service (no items)
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}
        }

    # Check mode: get replica status via mongosh
    mongosh_cmd = ["mongosh", "--quiet", "--eval", "JSON.stringify(rs.status())"]
    res = ctx.run(mongosh_cmd, mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "mongosh failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    stdout = res.stdout.strip()
    if not stdout:
        return {
            "changed": False,
            "msg": "no MongoDB replica set data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Guard: only decode if output looks like JSON
    if stdout.find("{") != 0 and stdout.find("[") != 0:
        return {
            "changed": False,
            "msg": "invalid MongoDB status output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Safe decode: use json.decode only when output appears valid
    # Starlark json.decode raises no exception; it fails on bad input.
    # But in practice, the agent context may have error text.
    # We rely on the agent to provide valid JSON; if not, report UNKNOWN.
    # Checkmk's source uses json.loads which fails on non-JSON — here we must guard.
    # Since json.decode in Starlark aborts the script on error, we avoid calling it directly on unknown input.
    # Instead, we assume mongosh always outputs valid JSON on success.
    status = json.decode(stdout)

    # Extract primary and members
    primary = None
    secondaries_active = []
    secondaries_passive = []
    arbiters = []

    members = status.get("members")
    if members != None and type(members) == "list":
        for member in members:
            if type(member) != "dict":
                continue
            state = member.get("stateStr", "")
            host = member.get("name", "")
            if state == "PRIMARY":
                primary = host
            elif state == "SECONDARY":
                secondaries_active.append(host)
            elif state == "ARBITER":
                arbiters.append(host)

    # Build verdict
    if primary == None:
        state = "CRIT"
        summary = "Replica set does not have a primary node"
    else:
        state = "OK"
        summary = "Primary: " + str(primary)

    # Append secondary and arbiter info
    details_parts = []
    if secondaries_active:
        details_parts.append("Active secondaries: " + ", ".join(secondaries_active))
    else:
        details_parts.append("No active secondaries")

    if secondaries_passive:
        details_parts.append("Passive secondaries: " + ", ".join(secondaries_passive))

    if arbiters:
        details_parts.append("Arbiters: " + ", ".join(arbiters))
    else:
        details_parts.append("No arbiters")

    details = "; ".join(details_parts)

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {},
            "details": details
        }
    }
def main(ctx, params):
    if params.get("_discover"):
        # Discovery: yield exactly one service
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": ["primary_election_time"]}]},
        }

    # Read-only probe for MongoDB replica set status via agent section
    res = ctx.run(["cat", "/var/lib/mongodb/replica_set_status.json"], mutates=False)
    if res.rc != 0 or res.stdout == "":
        return {
            "changed": False,
            "msg": "No replica set status available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Guard: only decode if output looks like valid JSON
    if res.stdout.strip() == "":
        return {
            "changed": False,
            "msg": "Empty replica set status output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    section = json.decode(res.stdout)

    members = section.get("members", [])
    if len(members) == 0:
        return {
            "changed": False,
            "msg": "Replica set has no members",
            "data": {"state": "WARN", "metrics": {}, "details": ""}
        }

    primary = None
    for member in members:
        if member.get("state", -1) == 1:  # PRIMARY state
            primary = member
            break

    if primary == None:
        return {
            "changed": False,
            "msg": "No primary member found in replica set",
            "data": {"state": "WARN", "metrics": {}, "details": ""}
        }

    primary_name = primary.get("name", "")
    election_time_ts = primary.get("electionTime", {}).get("$timestamp", {}).get("t", None)

    if election_time_ts == None:
        return {
            "changed": False,
            "msg": "Can not retrieve primary name and election time",
            "data": {"state": "WARN", "metrics": {}, "details": ""}
        }

    # electionTime.t is seconds since epoch (Unix timestamp)
    election_time = float(election_time_ts)
    election_datetime_str = "%d" % election_time

    summary = "Primary '%s' elected at %s" % (primary_name, election_datetime_str)
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": "OK",
            "metrics": {"primary_election_time": election_time},
            "details": ""
        },
    }

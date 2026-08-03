def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["which", "mongo"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "mongo not found",
                    "data": {"discovery": []}}
        res = ctx.run(["mongo", "--quiet", "--eval",
                       "JSON.stringify(rs.status())"], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "cannot get replica set status",
                    "data": {"discovery": []}}
        d = json.decode(res.stdout)
        if d == None or not d.get("ok") == 1:
            return {"changed": False, "msg": "replica set not initialized",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 items",
                "data": {"discovery": [
                    {"item": "", "params": {},
                     "metrics": []}]}}

    item = params.get("item", "")
    res = ctx.run(["mongo", "--quiet", "--eval",
                   "JSON.stringify(rs.status())"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "cannot get replica set status",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    d = json.decode(res.stdout)
    if d == None or not d.get("ok") == 1:
        return {"changed": False, "msg": "replica set not initialized",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    members = d.get("members", [])
    primary = None
    active = []
    passive = []
    arbiters = []
    for m in members:
        state = m.get("stateStr")
        name = m.get("name")
        if state == "PRIMARY":
            primary = name
        elif state in ("SECONDARY", "SECONDARY PENDING"):
            active.append(name)
        elif state == "ARBITER":
            arbiters.append(name)
        elif state == "PASSIVE":
            passive.append(name)

    msgs = []
    if primary != None:
        msgs.append("Primary: %s" % primary)
    else:
        msgs.append("Replica set does not have a primary node")
        return {"changed": False, "msg": "CRIT - Replica set does not have a primary node",
                "data": {"state": "CRIT", "metrics": {}, "details": "\n".join(msgs)}}
    if active:
        msgs.append("Active secondaries: %s" % ", ".join(active))
    else:
        msgs.append("No active secondaries")
    if passive:
        msgs.append("Passive secondaries: %s" % ", ".join(passive))
    else:
        msgs.append("No passive secondaries")
    if arbiters:
        msgs.append("Arbiters: %s" % ", ".join(arbiters))
    else:
        msgs.append("No arbiters")

    return {"changed": False, "msg": "OK - %s" % "; ".join(msgs),
            "data": {"state": "OK", "metrics": {}, "details": "\n".join(msgs)}}
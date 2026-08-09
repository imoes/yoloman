def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["olsnodes"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no oracle crs found", "data": {"discovery": []}}
        if res.rc == 127:
            return {"changed": False, "msg": "olsnodes not installed", "data": {"discovery": []}}
        res2 = ctx.run(["crsctl", "query", "css", "votedisk"], mutates=False)
        if res2.rc != 0 or not res2.stdout:
            return {"changed": False, "msg": "no voting disks found", "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item", "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}}
    item = params.get("item", "")
    res = ctx.run(["crsctl", "query", "css", "votedisk"], mutates=False)
    if res.rc == 127:
        return {"changed": False, "msg": "crsctl not installed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "no Voting Disk(s) found. Maybe the cssd/crsd is not running!", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    lines = res.stdout.splitlines()
    votecount = 0
    votedisk = ""
    for line in lines:
        f = line.split()
        if len(f) >= 4 and f[1] == "ONLINE":
            votecount += 1
            votedisk += "[%s] " % f[3]
        elif len(f) == 3 and f[0] != "Name" and f[0] != "---":
            votecount += 1
            votedisk += "[%s] " % f[2]
        elif len(f) >= 4 and f[1] == "OFFLINE":
            pass
    if votecount in (1, 3, 5):
        infotext = "%d Voting Disks found. %s" % (votecount, votedisk)
        return {"changed": False, "msg": infotext, "data": {"state": "OK", "metrics": {}, "details": infotext}}
    if votecount == 0:
        return {"changed": False, "msg": "No Voting Disk(s) found. Maybe the cssd/crsd is not running!", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    infotext = "missing Voting Disks (!!). %d Votes found %s" % (votecount, votedisk)
    return {"changed": False, "msg": infotext, "data": {"state": "CRIT", "metrics": {}, "details": infotext}}
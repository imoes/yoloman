def main(ctx, params):
    res = ctx.run(["cat", "/proc/cluster/asm_voting_disks"], mutates=False)
    # Fallback if file doesn't exist or is empty
    if not res.stdout or res.rc != 0:
        return {
            "changed": False,
            "msg": "ORA-GI Voting: No data (cssd/crsd likely not running)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    votecount = 0
    votedisk = ""
    lines = res.stdout.splitlines()
    for line in lines:
        if not line.strip():
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        # Check if line format matches expected pattern: <num> ONLINE <hash> (<disk>) [name]
        # or shorter format: <num> ONLINE <hash> (<disk>)
        if parts[1] == "ONLINE":
            votecount += 1
            if len(parts) >= 4:
                disk = parts[3].strip("()")
                votedisk += "[%s] " % disk
            elif len(parts) == 3:
                # Shorter format: third element might be disk name in brackets or hash
                disk_part = parts[2]
                if disk_part.startswith("(") and disk_part.endswith(")"):
                    disk = disk_part.strip("()")
                else:
                    # Assume it's the disk identifier if not in parentheses
                    disk = disk_part
                votedisk += "[%s] " % disk
        elif len(parts) == 3:
            # Fallback for lines with only 3 parts (shouldn't happen with current format)
            votecount += 1
            disk = parts[2]
            votedisk += "[%s] " % disk

    if votecount == 0:
        return {
            "changed": False,
            "msg": "ORA-GI Voting: No Voting Disk(s) found. Maybe the cssd/crsd is not running!",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if votecount in (1, 3, 5):
        infotext = "%d Voting Disks found. %s" % (votecount, votedisk)
        return {
            "changed": False,
            "msg": infotext,
            "data": {"state": "OK", "metrics": {}, "details": ""},
        }

    infotext = "missing Voting Disks (!!). %d Votes found %s" % (votecount, votedisk)
    return {
        "changed": False,
        "msg": infotext,
        "data": {"state": "CRIT", "metrics": {}, "details": ""},
    }

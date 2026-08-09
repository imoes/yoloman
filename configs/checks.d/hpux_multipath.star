# hpux_multipath.star
# Checkmk check: hpux_multipath - Multipath %s
# Translated to read-only Starlark for yolo-man agent

# Path state -> index mapping (ACTIVE, STANDBY, FAILED, UNOPEN)
_PATH_STATES = {
    "ACTIVE": 0,
    "STANDBY": 1,
    "FAILED": 2,
    "UNOPEN": 3,
    "OPENING": 0,
    "CLOSING": 1,
}


def _format_pathstatus(pathcounts):
    infos = []
    for name, i in sorted(_PATH_STATES.items(), key=lambda kv: kv[1]):
        c = pathcounts[i]
        if c > 0:
            infos.append("%d %s" % (c, name))
    return ", ".join(infos)


def _parse_ioscan_output(stdout):
    """Parse ioscan -fn output to extract LUN path information.
    
    Simulates the <<<hpux_multipath>>> agent section by extracting
    LUN path info from ioscan output.
    """
    disks = {}
    disk = ""
    paths = []
    wwid = ""
    
    lines = stdout.split("\n")
    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        
        # Look for LUN PATH INFORMATION header with device
        if "LUN PATH INFORMATION FOR LUN" in stripped:
            # Extract device name - format: "LUN PATH INFORMATION FOR LUN : /dev/rdisk/disk10"
            if ":" in stripped:
                parts = stripped.split(":")
                if len(parts) >= 2:
                    disk = parts[-1].strip()
            else:
                disk = ""
            paths = [0, 0, 0, 0]  # ACTIVE, STANDBY, FAILED, UNOPEN
            wwid = ""
        elif "World Wide Identifier" in stripped:
            if "=" in stripped:
                parts = stripped.split("=")
                if len(parts) >= 2:
                    wwid = parts[-1].strip()
            if wwid != "" and disk != "":
                paths = [0, 0, 0, 0]
                disks[wwid] = (disk, paths)
        elif "State" in stripped:
            if "=" in stripped:
                parts = stripped.split("=")
                if len(parts) >= 2:
                    state = parts[-1].strip()
                    idx = _PATH_STATES.get(state)
                    if idx != None and wwid in disks:
                        disk_name, pathcounts = disks[wwid]
                        pathcounts[idx] = pathcounts[idx] + 1
    
    return disks


def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        # Check if ioscan is available (HP-UX system)
        probe = ctx.run(["ioscan", "-fn"], mutates=False)
        if probe.rc == 127:
            # ioscan not found - not an HP-UX system, not applicable
            return {"changed": False, "msg": "hpux_multipath: ioscan not available",
                    "data": {"discovery": []}}
        
        if probe.rc != 0:
            return {"changed": False, "msg": "hpux_multipath: ioscan failed",
                    "data": {"discovery": []}}
        
        section = _parse_ioscan_output(probe.stdout)
        
        discovery = []
        for wwid, (disk, pathcounts) in section.items():
            active = pathcounts[0]
            standby = pathcounts[1]
            failed = pathcounts[2]
            unopen = pathcounts[3]
            if active + standby + failed >= 2:
                discovery.append({
                    "item": wwid,
                    "params": {"expected": (active, standby, failed, unopen)},
                    "metrics": [],
                })
        
        return {"changed": False, "msg": "discovered %d multipath devices" % len(discovery),
                "data": {"discovery": discovery}}
    
    # Check mode - check one item
    item = params.get("item", "")
    
    # Check if ioscan is available
    probe = ctx.run(["ioscan", "-fn"], mutates=False)
    if probe.rc == 127:
        return {"changed": False, "msg": "hpux_multipath: ioscan not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    if probe.rc != 0:
        return {"changed": False, "msg": "hpux_multipath: ioscan failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    section = _parse_ioscan_output(probe.stdout)
    
    if item == "" or item not in section:
        if item == "":
            if len(section) == 1:
                item = list(section.keys())[0]
            elif len(section) == 0:
                return {"changed": False, "msg": "no multipath devices found",
                        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
            else:
                return {"changed": False, "msg": "multiple multipath devices found, specify item",
                        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        
        if item not in section:
            return {"changed": False, "msg": "no such WWID: " + str(item),
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    disk, pathcounts = section[item]
    
    if pathcounts[2] > 0:
        msg = "%s: %d failed paths! (%s)" % (disk, pathcounts[2], _format_pathstatus(pathcounts))
        return {"changed": False, "msg": msg,
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    
    expected = params.get("expected", (pathcounts[0], pathcounts[1], pathcounts[2], pathcounts[3]))
    if list(pathcounts) != list(expected):
        msg = "%s: Invalid path status %s (should be %s)" % (
            disk, _format_pathstatus(pathcounts), _format_pathstatus(list(expected)))
        return {"changed": False, "msg": msg,
                "data": {"state": "WARN", "metrics": {}, "details": ""}}
    else:
        msg = "%s: %s" % (disk, _format_pathstatus(pathcounts))
        return {"changed": False, "msg": msg,
                "data": {"state": "OK", "metrics": {}, "details": ""}}
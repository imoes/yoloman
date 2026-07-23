def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/proc/diskstats"], mutates=False)
        disks = []
        for line in res.stdout.splitlines():
            fields = line.split()
            # IBM SVC agent reports disk stats via /proc/diskstats;
            # we expose each "disk" that has non-zero r_io/w_io in check mode
            if len(fields) >= 14:
                # fields[2]=r_sectors, fields[6]=w_sectors, fields[13]=r_ios, fields[17]=w_ios
                # Use r_ios/w_ios directly as IO counts, not sectors
                r_ios = int(fields[13]) if fields[13].isdigit() else 0
                w_ios = int(fields[17]) if fields[17].isdigit() else 0
                if r_ios > 0 or w_ios > 0:
                    disk_name = fields[2]
                    disks.append({
                        "item": disk_name,
                        "params": {},
                        "metrics": ["read", "write"]
                    })
        return {"changed": False, "msg": "discovered %d disks" % len(disks),
                "data": {"discovery": disks}}
    
    item = params.get("item", "")
    res = ctx.run(["cat", "/proc/diskstats"], mutates=False)
    for line in res.stdout.splitlines():
        fields = line.split()
        if len(fields) >= 18 and fields[2] == item:
            r_ios = int(fields[13]) if fields[13].isdigit() else 0
            w_ios = int(fields[17]) if fields[17].isdigit() else 0
            read_iops = float(r_ios)
            write_iops = float(w_ios)
            return {"changed": False,
                    "msg": "%d IO/s read, %d IO/s write" % (read_iops, write_iops),
                    "data": {
                        "state": "OK",
                        "metrics": {"read": read_iops, "write": write_iops},
                        "details": ""
                    }}
    return {"changed": False, "msg": "disk %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
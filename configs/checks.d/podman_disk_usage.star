def main(ctx, params):
    # Discovery mode: enumerate items (containers, images, volumes) from podman data
    if params.get("_discover"):
        res = ctx.run(["podman", "system", "df", "--format", "json"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "failed to run podman df: " + res.stderr,
                    "data": {"discovery": []}}
        if not res.stdout:
            return {"changed": False, "msg": "no output from podman df",
                    "data": {"discovery": []}}
        
        data = json.decode(res.stdout)
        
        items = []
        if isinstance(data, list):
            # Summary format
            for entry in data:
                entry_type = entry.get("Type")
                if entry_type == "Images":
                    items.append({"item": "images", "params": {}, "metrics": ["size", "reclaimable_size", "total_number", "active_number"]})
                elif entry_type == "Containers":
                    items.append({"item": "containers", "params": {}, "metrics": ["size", "reclaimable_size", "total_number", "active_number"]})
                elif entry_type == "Local Volumes":
                    items.append({"item": "volumes", "params": {}, "metrics": ["size", "reclaimable_size", "total_number", "active_number"]})
        elif isinstance(data, dict):
            # Entity format
            if "Images" in data:
                images = data.get("Images", [])
                total_size = 0
                total_number = len(images)
                active_number = 0
                for img in images:
                    size = float(img.get("Size", 0))
                    total_size += size
                    if img.get("Containers", 0) > 0:
                        active_number += 1
                items.append({"item": "images", "params": {}, "metrics": ["size", "total_number", "active_number"]})
            if "Containers" in data:
                containers = data.get("Containers", [])
                total_size = 0
                total_reclaimable = 0
                total_number = len(containers)
                active_number = 0
                for c in containers:
                    size = float(c.get("Size", 0))
                    rwsize = float(c.get("RWSize", 0))
                    total_size += size
                    total_reclaimable += rwsize
                    status = c.get("Status", "").lower()
                    if status == "running":
                        active_number += 1
                metrics = ["size", "reclaimable_size", "total_number", "active_number"] if total_reclaimable > 0 else ["size", "total_number", "active_number"]
                items.append({"item": "containers", "params": {}, "metrics": metrics})
            if "Volumes" in data:
                volumes = data.get("Volumes", [])
                total_size = 0
                total_reclaimable = 0
                total_number = len(volumes)
                active_number = 0
                for v in volumes:
                    size = float(v.get("Size", 0))
                    reclaimable = float(v.get("ReclaimableSize", 0))
                    total_size += size
                    total_reclaimable += reclaimable
                    if v.get("Links", 0) > 0:
                        active_number += 1
                metrics = ["size", "reclaimable_size", "total_number", "active_number"] if total_reclaimable > 0 else ["size", "total_number", "active_number"]
                items.append({"item": "volumes", "params": {}, "metrics": metrics})
        
        return {"changed": False, "msg": "discovered %d items" % len(items),
                "data": {"discovery": items}}

    # Check mode: verify one item
    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res = ctx.run(["podman", "system", "df", "--format", "json"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to run podman df: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not res.stdout:
        return {"changed": False, "msg": "no output from podman df",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    data = json.decode(res.stdout)

    # Extract usage data for the requested item
    size = 0.0
    reclaimable_size = None
    total_number = 0
    active_number = 0

    if isinstance(data, list):
        # Summary format
        for entry in data:
            entry_type = entry.get("Type")
            if entry_type == "Images" and item == "images":
                size = float(entry.get("RawSize", 0))
                reclaimable_size = float(entry.get("RawReclaimable", 0))
                total_number = int(entry.get("Total", 0))
                active_number = int(entry.get("Active", 0))
                break
            elif entry_type == "Containers" and item == "containers":
                size = float(entry.get("RawSize", 0))
                reclaimable_size = float(entry.get("RawReclaimable", 0))
                total_number = int(entry.get("Total", 0))
                active_number = int(entry.get("Active", 0))
                break
            elif entry_type == "Local Volumes" and item == "volumes":
                size = float(entry.get("RawSize", 0))
                reclaimable_size = float(entry.get("RawReclaimable", 0))
                total_number = int(entry.get("Total", 0))
                active_number = int(entry.get("Active", 0))
                break
    elif isinstance(data, dict):
        # Entity format
        if item == "images" and "Images" in data:
            images = data.get("Images", [])
            for img in images:
                size += float(img.get("Size", 0))
                if img.get("Containers", 0) > 0:
                    active_number += 1
            total_number = len(images)
        elif item == "containers" and "Containers" in data:
            containers = data.get("Containers", [])
            for c in containers:
                size += float(c.get("Size", 0))
                rwsize = float(c.get("RWSize", 0))
                reclaimable_size = (reclaimable_size if reclaimable_size != None else 0) + rwsize
                status = c.get("Status", "").lower()
                if status == "running":
                    active_number += 1
            total_number = len(containers)
        elif item == "volumes" and "Volumes" in data:
            volumes = data.get("Volumes", [])
            for v in volumes:
                size += float(v.get("Size", 0))
                reclaimable = float(v.get("ReclaimableSize", 0))
                reclaimable_size = (reclaimable_size if reclaimable_size != None else 0) + reclaimable
                if v.get("Links", 0) > 0:
                    active_number += 1
            total_number = len(volumes)

    # Apply thresholds
    state = "OK"
    msg_parts = []
    
    # Size
    size_val = float(size)
    warn_size = params.get("size_upper", {}).get("levels", (None, None))
    crit_size = params.get("size_upper", {}).get("levels", (None, None))
    warn_size_val = warn_size[1] if warn_size != None and len(warn_size) > 1 else None
    crit_size_val = crit_size[1] if crit_size != None and len(crit_size) > 1 else None
    if crit_size_val != None and size_val >= crit_size_val:
        state = "CRIT"
    elif warn_size_val != None and size_val >= warn_size_val:
        state = "WARN"
    msg_parts.append("Size: %s" % _render_bytes(size_val))

    # Reclaimable size (if available)
    if reclaimable_size != None:
        reclaim_val = float(reclaimable_size)
        warn_rec = params.get("reclaimable_upper", {}).get("levels", (None, None))
        crit_rec = params.get("reclaimable_upper", {}).get("levels", (None, None))
        warn_rec_val = warn_rec[1] if warn_rec != None and len(warn_rec) > 1 else None
        crit_rec_val = crit_rec[1] if crit_rec != None and len(crit_rec) > 1 else None
        if crit_rec_val != None and reclaim_val >= crit_rec_val:
            state = "CRIT"
        elif warn_rec_val != None and reclaim_val >= warn_rec_val:
            state = "WARN"
        msg_parts.append("Reclaimable: %s" % _render_bytes(reclaim_val))

    # Total count
    total_val = float(total_number)
    warn_tot = params.get("total", {}).get("levels", (None, None))
    crit_tot = params.get("total", {}).get("levels", (None, None))
    warn_tot_val = warn_tot[1] if warn_tot != None and len(warn_tot) > 1 else None
    crit_tot_val = crit_tot[1] if crit_tot != None and len(crit_tot) > 1 else None
    if crit_tot_val != None and total_val >= crit_tot_val:
        state = "CRIT"
    elif warn_tot_val != None and total_val >= warn_tot_val:
        state = "WARN"
    msg_parts.append("Total: %d" % int(total_val))

    # Active count
    active_val = float(active_number)
    warn_act = params.get("active", {}).get("levels", (None, None))
    crit_act = params.get("active", {}).get("levels", (None, None))
    warn_act_val = warn_act[1] if warn_act != None and len(warn_act) > 1 else None
    crit_act_val = crit_act[1] if crit_act != None and len(crit_act) > 1 else None
    if crit_act_val != None and active_val >= crit_act_val:
        state = "CRIT"
    elif warn_act_val != None and active_val >= warn_act_val:
        state = "WARN"
    msg_parts.append("Active: %d" % int(active_val))

    # Build metrics dict
    metrics = {"podman_disk_usage_" + item + "_total_size": size_val,
               "podman_disk_usage_" + item + "_total_number": total_val,
               "podman_disk_usage_" + item + "_active_number": active_val}
    if reclaimable_size != None:
        metrics["podman_disk_usage_" + item + "_reclaimable_size"] = float(reclaimable_size)

    return {"changed": False, "msg": "; ".join(msg_parts),
            "data": {"state": state, "metrics": metrics, "details": ""}}


def _render_bytes(value):
    # Simple bytes renderer: returns human-readable bytes string
    if value < 1024:
        return "%f B" % value
    elif value < 1024 * 1024:
        return "%f KB" % (value / 1024.0)
    elif value < 1024 * 1024 * 1024:
        return "%f MB" % (value / (1024.0 * 1024.0))
    elif value < 1024 * 1024 * 1024 * 1024:
        return "%f GB" % (value / (1024.0 * 1024.0 * 1024.0))
    else:
        return "%f TB" % (value / (1024.0 * 1024.0 * 1024.0 * 1024.0))
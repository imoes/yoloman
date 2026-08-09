# drbd_disk check plugin for yolo-man agent
# Reads /proc/drbd directly to gather disk I/O statistics for a DRBD resource


def main(ctx, params):
    # Discover mode: list all DRBD resources and their metrics
    if params.get("_discover"):
        content = ctx.file_read("/proc/drbd") if ctx.file_exists("/proc/drbd") else ""
        lines = content.split("\n")
        
        # Skip first two lines (version info)
        if len(lines) < 3:
            return {"changed": False, "msg": "discovered 0 DRBD devices",
                    "data": {"discovery": []}}
        
        resources = []
        
        for line in lines[2:]:
            stripped = line.strip()
            # Check if line starts with optional spaces followed by digits and colon
            if stripped.startswith(" "):
                idx_part = stripped[1:]
                if idx_part and idx_part[0].isdigit():
                    colon_pos = idx_part.find(":")
                    if colon_pos > 0:
                        idx = idx_part[0:colon_pos]
                        item = "drbd" + idx
                        resources.append({
                            "item": item,
                            "params": {},
                            "metrics": ["write", "read"]
                        })
        
        return {"changed": False, "msg": "discovered %d DRBD devices" % len(resources),
                "data": {"discovery": resources}}
    
    # Check mode: analyze one DRBD resource
    item = params.get("item", "")
    # Extract index from item: "drbd0" -> "0"
    if not item.startswith("drbd"):
        return {"changed": False, "msg": "invalid item format",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    idx = item[4:]  # Remove "drbd" prefix
    
    content = ctx.file_read("/proc/drbd") if ctx.file_exists("/proc/drbd") else ""
    lines = content.split("\n")
    
    if len(lines) < 3:
        return {"changed": False, "msg": "DRBD data unavailable",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Find the block for our resource index
    block_lines = []
    in_block = False
    
    for line in lines[2:]:
        stripped = line.strip()
        # Check if line starts with optional spaces followed by digits and colon
        if stripped.startswith(" "):
            idx_part = stripped[1:]
            if idx_part and idx_part[0].isdigit():
                colon_pos = idx_part.find(":")
                if colon_pos > 0:
                    current_idx = idx_part[0:colon_pos]
                    if current_idx == idx:
                        in_block = True
                    elif in_block:
                        break  # Next resource block starts
        if in_block:
            block_lines.append(line)
    
    if not in_block or len(block_lines) < 2:
        return {"changed": False, "msg": "resource %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse the second line (data line): "    ns:12031428 nr:0 dw:12031364 dr:1175992347 al:2179 bm:71877 lo:37 pe:0 ua:37 ap:0 ep:1 wo:b oos:301729988"
    data_line = block_lines[1].strip()
    
    # Extract dw (disk write) and dr (disk read) values
    dw = 0
    dr = 0
    for part in data_line.split():
        if part.startswith("dw:"):
            val = part[3:]
            dw = int(val) if val.isdigit() else 0
        elif part.startswith("dr:"):
            val = part[3:]
            dr = int(val) if val.isdigit() else 0
    
    # Calculate rates: return absolute values (since we have no state persistence, return raw KB)
    # Checkmk expects rates, but without persistence we return the raw values.
    # This matches the agent's behavior: it returns cumulative values that Checkmk rates.
    # Since the yolo-man agent has no rate store, return raw KB values (not rates).
    # In production, this will return cumulative values, which Checkmk can rate if configured appropriately.
    # Return them as-is; Checkmk's check_levels can handle them.
    
    # Determine state (OK by default unless errors detected)
    # Checkmk doesn't define explicit state rules for disk checks; use OK
    state = "OK"
    details = ""
    
    return {"changed": False, "msg": "Disk: write=%d KB, read=%d KB" % (dw, dr),
            "data": {"state": state, "metrics": {"write": dw, "read": dr}, "details": details}}
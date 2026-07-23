# Helper to extract key-value from megaraid agent lines
def _parse_line(line):
    """Parse a megaraid agent line like 'State: Optimal' or 'Default Cache: Enabled'"""
    if not line:
        return None, None
    parts = line.split(":", 1)
    if len(parts) < 2:
        return None, None
    key = parts[0].strip()
    value = parts[1].strip()
    return key, value

# State mapping from Checkmk defaults (megaraid.py: LDISKS_DEFAULTS)
# State mapping: 'Optimal' -> 0, 'Online' -> 0, 'Offline' -> 2, 'Degraded' -> 1, 'Rebuilding' -> 1
_STATE_MAP = {
    "Optimal": 0,
    "Online": 0,
    "Offline": 2,
    "Degraded": 1,
    "Rebuilding": 1,
    "Failed": 2,
    "Unknown": 3,
}

def _get_state_code(state):
    return _STATE_MAP.get(state, 3)

def main(ctx, params):
    if params.get("_discover"):
        # Discover items by running storcli -d0 all show
        # We use storcli because megaraid agent reads /proc/megaraid or similar CLI
        # The check source expects storcli output format, so run that exact command
        res = ctx.run(["storcli", "-d0", "all", "show"], mutates=False)
        if res.rc != 0:
            # Return empty discovery if command fails (e.g., no megaraid controller)
            return {"changed": False, "msg": "discovered 0 disks", "data": {"discovery": []}}
        
        # Parse the storcli output to extract adapter and disk info
        out = []
        lines = res.stdout.splitlines()
        adapter = None
        
        for line in lines:
            stripped = line.strip()
            # Check for adapter line
            if stripped.startswith("Adapter #"):
                adapter = stripped.split("#")[1].strip()
            # Check for virtual drive line
            elif "Virtual Disk" in stripped or "Virtual Drive" in stripped:
                # Format: "Virtual Disk : 0 (Target Id: 0)"
                parts = stripped.split(":")
                if len(parts) >= 2:
                    disk = parts[1].strip().split()[0]
                    item = "/c{}/v{}".format(adapter, disk)
                    # Only yield new-style items (start with /c)
                    out.append({
                        "item": item,
                        "params": {},
                        "metrics": []
                    })
        
        return {"changed": False, "msg": "discovered %d disks" % len(out),
                "data": {"discovery": out}}
    
    # Check mode - single item
    item = params.get("item", "")
    
    # Run same command as in discovery
    res = ctx.run(["storcli", "-d0", "all", "show"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "command failed", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Parse storcli output to find our item
    lines = res.stdout.splitlines()
    adapter = None
    ldisk_state = None
    default_cache = None
    current_cache = None
    default_write = None
    current_write = None
    
    for line in lines:
        stripped = line.strip()
        
        # Track adapter
        if stripped.startswith("Adapter #"):
            adapter = stripped.split("#")[1].strip()
        
        # Detect start of a new virtual drive block
        elif "Virtual Disk" in stripped or "Virtual Drive" in stripped:
            # Check if this matches our item
            parts = stripped.split(":")
            if len(parts) >= 2:
                disk = parts[1].strip().split()[0]
                current_item = "/c{}/v{}".format(adapter, disk)
                if current_item == item:
                    # Reset state for this item
                    ldisk_state = None
                    default_cache = None
                    current_cache = None
                    default_write = None
                    current_write = None
        
        # Parse properties of the current virtual drive
        elif ldisk_state != None or (default_cache == None and current_cache == None and 
                                     default_write == None and current_write == None):
            # We need to track which properties we're parsing
            pass
        
        # If we found the item, parse its properties
        if item and (ldisk_state == None or default_cache == None):
            if stripped.startswith("State"):
                ldisk_state = stripped.split(":", 1)[1].strip()
            elif "Default" in stripped:
                parts = stripped.split()
                if len(parts) >= 4:
                    # e.g., "Default Cache: Caching Enabled"
                    if "Cache" in stripped:
                        default_cache = " ".join(parts[3:]).replace(": ", "")
                    elif "Write" in stripped:
                        default_write = " ".join(parts[3:]).replace(": ", "")
            elif "Current" in stripped:
                parts = stripped.split()
                if len(parts) >= 4:
                    if "Cache" in stripped:
                        current_cache = " ".join(parts[3:]).replace(": ", "")
                    elif "Write" in stripped:
                        current_write = " ".join(parts[3:]).replace(": ", "")
    
    # Find item in parsed data - need better parsing logic
    # Reset and use more reliable parsing approach
    ldisk_state = None
    default_cache = None
    current_cache = None
    default_write = None
    current_write = None
    
    in_item = False
    
    for line in lines:
        stripped = line.strip()
        
        if stripped.startswith("Adapter #"):
            adapter = stripped.split("#")[1].strip()
        
        # Check for virtual drive start line
        elif "Virtual Disk" in stripped or "Virtual Drive" in stripped:
            parts = stripped.split(":")
            if len(parts) >= 2:
                disk = parts[1].strip().split()[0]
                current_item = "/c{}/v{}".format(adapter, disk)
                in_item = (current_item == item)
                ldisk_state = None
                default_cache = None
                current_cache = None
                default_write = None
                current_write = None
        
        # If in our item block, parse properties
        elif in_item:
            if stripped.startswith("State"):
                ldisk_state = stripped.split(":", 1)[1].strip()
            elif stripped.startswith("Default Cache"):
                default_cache = stripped.split(":", 1)[1].strip()
            elif stripped.startswith("Default Write"):
                default_write = stripped.split(":", 1)[1].strip()
            elif stripped.startswith("Current Cache"):
                current_cache = stripped.split(":", 1)[1].strip()
            elif stripped.startswith("Current Write"):
                current_write = stripped.split(":", 1)[1].strip()
    
    # If item not found
    if ldisk_state == None:
        return {"changed": False, "msg": "disk not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Determine state code
    state_code = _get_state_code(ldisk_state)
    
    # Build message
    msg_parts = []
    msg_parts.append(ldisk_state.capitalize())
    if default_cache and current_cache:
        if current_cache != default_cache:
            msg_parts.append("Cache: " + current_cache + " (expected: " + default_cache + ")")
        else:
            msg_parts.append("Cache: " + current_cache)
    if default_write and current_write:
        if current_write != default_write:
            msg_parts.append("Write: " + current_write + " (expected: " + default_write + ")")
        else:
            msg_parts.append("Write: " + current_write)
    
    # State determination (WARN if mismatched, CRIT for bad states)
    if ldisk_state == "Offline" or ldisk_state == "Failed":
        state = "CRIT"
    elif ldisk_state == "Degraded" or ldisk_state == "Rebuilding":
        state = "WARN"
    elif ldisk_state == "Optimal" or ldisk_state == "Online":
        state = "OK"
    else:
        state = "UNKNOWN"
    
    # Check cache/write mismatch
    if state == "OK":
        if (default_cache and current_cache and default_cache != current_cache):
            state = "WARN"
        elif (default_write and current_write and default_write != current_write):
            state = "WARN"
    
    return {"changed": False, "msg": ", ".join(msg_parts),
            "data": {"state": state, "metrics": {}, "details": ""}}
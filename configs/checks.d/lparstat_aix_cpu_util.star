# CPU utilization check for AIX lparstat output
# Reads 'lparstat -a' output, parses CPU utilization and entitlement metrics

def _is_number(s):
    """Check if string represents a number (including negative and decimal)."""
    if not s:
        return False
    # Handle negative sign
    if s.startswith("-"):
        s = s[1:]
    # Check for digits and at most one decimal point
    decimal_count = 0
    for c in s:
        if c == ".":
            decimal_count += 1
            if decimal_count > 1:
                return False
        elif not c.isdigit():
            return False
    return decimal_count <= 1 and len(s) > 0


def _parse_lparstat_output(output):
    """Parse lparstat -a output into structured data."""
    if not output:
        return None
    
    lines = output.strip().split("\n")
    if len(lines) < 4:
        return {"update_required": True}
    
    # Parse first line (system config)
    system_config = {}
    if lines[0]:
        for token in lines[0].split():
            if "=" in token:
                parts = token.split("=", 1)
                if len(parts) == 2:
                    system_config[parts[0]] = parts[1]
    
    # SMT handling: "on" means 2 threads
    if system_config.get("smt", "").lower() == "on":
        system_config["smt"] = "2"
    
    # Parse header line (second line) - column names
    headers = lines[1].split() if len(lines) > 1 else []
    
    # Parse data line (fourth line)
    values = lines[3].split() if len(lines) > 3 else []
    
    # Build cpu dict from known column indices
    cpu = {}
    util = {}
    
    # Map column names to indices for the value line
    header_to_idx = {}
    for i, h in enumerate(headers):
        header_to_idx[h.lstrip("%")] = i
    
    # Extract CPU metrics (user, sys, idle, wait)
    for name in ("user", "sys", "idle", "wait"):
        idx = header_to_idx.get(name)
        if idx != None and idx < len(values):
            val_str = values[idx]
            if _is_number(val_str):
                cpu[name] = float(val_str)
    
    # Extract utilization metrics (everything else)
    for i, h in enumerate(headers):
        name = h.lstrip("%")
        if name not in ("user", "sys", "idle", "wait"):
            uom = "%" if "%" in h else ""
            if i < len(values):
                val_str = values[i]
                if _is_number(val_str):
                    util[name] = (float(val_str), uom)
    
    return {
        "system_config": system_config,
        "util": util,
        "cpu": cpu,
        "update_required": False,
    }


def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run(["lparstat", "-a"], mutates=False)
        section = _parse_lparstat_output(res.stdout if res.rc == 0 else "")
        
        # Check if we need to discover CPU utilization service
        if section == None or section.get("update_required"):
            return {
                "changed": False,
                "msg": "discovered 0 items (data unavailable)",
                "data": {"discovery": []}
            }
        
        cpu = section.get("cpu", {})
        has_all_keys = (cpu.get("user") != None and 
                       cpu.get("sys") != None and 
                       cpu.get("wait") != None and 
                       cpu.get("idle") != None)
        
        if has_all_keys:
            return {
                "changed": False,
                "msg": "discovered 1 items",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": ["util", "sys", "wait", "idle"]}]}
            }
        
        return {
            "changed": False,
            "msg": "discovered 0 items (insufficient CPU data)",
            "data": {"discovery": []}
        }
    
    # Check mode - single item (item is always "" for this check)
    res = ctx.run(["lparstat", "-a"], mutates=False)
    section = _parse_lparstat_output(res.stdout if res.rc == 0 else "")
    
    # Handle agent not updated
    if section == None or section.get("update_required"):
        return {
            "changed": False,
            "msg": "Please upgrade your AIX agent.",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    cpu = section.get("cpu", {})
    
    # Check required CPU metrics exist
    user_val = cpu.get("user")
    sys_val = cpu.get("sys")
    wait_val = cpu.get("wait")
    idle_val = cpu.get("idle")
    
    if user_val == None or sys_val == None or wait_val == None or idle_val == None:
        return {
            "changed": False,
            "msg": "CPU utilization: insufficient data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Get utilization metrics
    util = section.get("util", {})
    metrics = {}
    
    # CPU utilization metrics (from section)
    for name, (value, uom) in util.items():
        metrics[name] = value
    
    # Add standard CPU components
    metrics["user"] = user_val
    metrics["sys"] = sys_val
    metrics["idle"] = idle_val
    metrics["wait"] = wait_val
    
    # Build summary message
    summary_parts = []
    util_val, util_uom = util.get("util", (0, "%"))
    summary_parts.append("util: %f%s" % (util_val, util_uom))
    summary_parts.append("user: %f%%" % user_val)
    summary_parts.append("sys: %f%%" % sys_val)
    summary_parts.append("wait: %f%%" % wait_val)
    summary_parts.append("idle: %f%%" % idle_val)
    
    # Entitlement metrics if available
    system_config = section.get("system_config", {})
    ent_val = system_config.get("ent")
    if ent_val != None and _is_number(ent_val):
        cpu_entitlement = float(ent_val)
        phys_cpu_consumption, _unit = util.get("physc", (0, ""))
        metrics["cpu_entitlement"] = cpu_entitlement
        metrics["cpu_entitlement_util"] = phys_cpu_consumption
        summary_parts.append("entitlement: %f CPUs" % cpu_entitlement)
        summary_parts.append("physc: %f CPUs" % phys_cpu_consumption)
    
    # Determine state (always OK for this check - no thresholds applied)
    return {
        "changed": False,
        "msg": ", ".join(summary_parts),
        "data": {
            "state": "OK",
            "metrics": metrics,
            "details": ""
        }
    }
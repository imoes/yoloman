# ===== starlark check: checkmk.ups_cps_inphase =====

# ===== constants =====

_BASE_OID = ".1.3.6.1.4.1.3808.1.1.1.3.2"


# ===== helper functions =====

def _is_numeric(s):
    """Check if string s represents a numeric value (including decimals and sign)."""
    if s == None or len(s) == 0:
        return False
    # Allow optional sign, digits, and at most one decimal point
    seen_dot = False
    for c in s:
        if c >= '0' and c <= '9':
            continue
        elif c == '.':
            if seen_dot:
                return False
            seen_dot = True
        elif c == '+' or c == '-':
            # Sign allowed only at start
            if s != s[0]:
                return False
        else:
            return False
    return True

def _snmp_value_to_float(value_str):
    """Parse SNMP value string to float, return None if empty or invalid."""
    if value_str == None or value_str.strip() == "":
        return None
    val = value_str.strip()
    if not _is_numeric(val):
        return None
    # Guard-based parsing: no try/except
    result = 0.0
    if val != "":
        # Simple conversion by hand to avoid try/except
        sign = 1
        start = 0
        if val[0] == '-':
            sign = -1
            start = 1
        elif val[0] == '+':
            start = 1
        
        int_part = 0
        frac_part = 0.0
        frac_div = 1.0
        dot_found = False
        
        for i in range(start, len(val)):
            c = val[i]
            if c == '.':
                dot_found = True
            elif c >= '0' and c <= '9':
                digit = ord(c) - ord('0')
                if dot_found:
                    frac_div *= 10
                    frac_part = frac_part * 10 + digit
                else:
                    int_part = int_part * 10 + digit
        
        result = float(sign * (int_part + frac_part / frac_div)) if dot_found else float(sign * int_part)
    
    return result / 10


def _check_levels(value, metric_name, levels_upper, levels_lower, human_func):
    """Check value against upper/lower thresholds, return (state, msg)."""
    if value == None:
        return ("UNKNOWN", "no data")

    upper_warn, upper_crit = levels_upper
    lower_warn, lower_crit = levels_lower

    # Check upper levels
    if upper_crit != None and value >= upper_crit:
        return ("CRIT", "value above critical threshold")
    if upper_warn != None and value >= upper_warn:
        return ("WARN", "value above warning threshold")

    # Check lower levels
    if lower_crit != None and value <= lower_crit:
        return ("CRIT", "value below critical threshold")
    if lower_warn != None and value <= lower_warn:
        return ("WARN", "value below warning threshold")

    return ("OK", "value within normal range")

def _format_value(value, metric_name):
    """Format value for display based on metric name."""
    if metric_name == "voltage":
        return "%fV" % value
    elif metric_name == "frequency":
        return "%fHz" % value
    else:
        return str(value)


# ===== main entry point =====

def main(ctx, params):
    # ----- discovery mode -----
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        # Fetch voltage (OID 1) and frequency (OID 4) from the base OID
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On",
            host, "%s.1" % _BASE_OID, "%s.4" % _BASE_OID
        ], mutates=False)
        
        # Parse output: build dict of item -> metrics
        data = {}
        current_item = "1"
        current_metrics = {}
        
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            
            # Format: OID = TYPE: value
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_part, value_part = parts
            
            # Extract the actual OID tail (remove base)
            if oid_part.startswith("%s." % _BASE_OID):
                tail = oid_part[len("%s." % _BASE_OID):]
                
                # Check if this is the voltage (tail == "1") or frequency (tail == "4")
                if tail == "1":
                    val = _snmp_value_to_float(value_part.split(": ", 1)[-1])
                    if val != None:
                        current_metrics["voltage"] = val
                elif tail == "4":
                    val = _snmp_value_to_float(value_part.split(": ", 1)[-1])
                    if val != None:
                        current_metrics["frequency"] = val
        
        # Only yield item if we have at least one metric
        if current_metrics:
            data[current_item] = current_metrics
        
        # Build discovery result
        items = []
        for item_name, metrics in data.items():
            items.append({
                "item": item_name,
                "params": {},
                "metrics": [k for k in metrics.keys()]
            })
        
        return {
            "changed": False,
            "msg": "discovered %d input phase(s)" % len(items),
            "data": {"discovery": items}
        }
    
    # ----- check mode -----
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    # Fetch data from SNMP
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On",
        host, "%s.1" % _BASE_OID, "%s.4" % _BASE_OID
    ], mutates=False)
    
    # Parse output to extract metrics for the requested item
    found = False
    metrics = {"voltage": None, "frequency": None}
    
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        
        # Format: OID = TYPE: value
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_part, value_part = parts
        
        # Check if this is the voltage (tail == "1") or frequency (tail == "4")
        if oid_part.startswith("%s." % _BASE_OID):
            tail = oid_part[len("%s." % _BASE_OID):]
            value_str = value_part.split(": ", 1)[-1] if ": " in value_part else value_part
            
            if tail == "1":
                val = _snmp_value_to_float(value_str)
                if val != None:
                    metrics["voltage"] = val
            elif tail == "4":
                val = _snmp_value_to_float(value_str)
                if val != None:
                    metrics["frequency"] = val
    
    # Check if item exists (we only have one item "1", so check accordingly)
    if not (metrics["voltage"] != None or metrics["frequency"] != None):
        return {
            "changed": False,
            "msg": "no data for item %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Apply thresholds (upper and lower levels)
    # Check voltage first if present, otherwise frequency
    metric_name = "voltage" if metrics["voltage"] != None else "frequency"
    value = metrics[metric_name]
    
    # Get thresholds (use defaults if not provided)
    levels_upper = params.get("levels_upper", (None, None))
    levels_lower = params.get("levels_lower", (0, 0))
    
    state, _ = _check_levels(value, metric_name, levels_upper, levels_lower, _format_value)
    
    # Build summary message
    summary = "%s: %s" % (metric_name.capitalize(), _format_value(value, metric_name))
    
    # Build metrics dict with only valid numeric values
    perfdata = {}
    for m in ["voltage", "frequency"]:
        if metrics[m] != None:
            perfdata[m] = metrics[m]
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": perfdata,
            "details": ""
        }
    }
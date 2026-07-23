# Module-level constants for state mapping
STATE_OK = 0
STATE_WARN = 1
STATE_CRIT = 2
STATE_UNKNOWN = 3


def main(ctx, params):
    # Discovery mode: enumerate items (organizations)
    if params.get("_discover"):
        # Read the agent section data (simulating the agent plugin's JSON output)
        # The Checkmk agent section "cisco_meraki_org_api_response_codes" is populated
        # from a JSON payload provided by the Cisco Meraki agent plugin.
        # For Checkmk agent-based monitoring, this section is typically provided by
        # the agent as a single-line JSON section.
        # We assume the data is available via a file path that the Checkmk agent 
        # plugin would use. For this translation, we use a standard path.
        file_path = "/var/lib/yolo-man/cisco_meraki_org_api_response_codes.json"
        if not ctx.file_exists(file_path):
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        
        content = ctx.file_read(file_path)
        if not content:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        
        data = json.decode(content)
        if not isinstance(data, list):
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        
        items = []
        for org in data:
            if not isinstance(org, dict):
                continue
            org_name = org.get("organization_name", "")
            org_id = org.get("organization_id", "")
            identifier = org_name + "/" + org_id
            if identifier:
                items.append({"item": identifier, "params": {"state_api_not_enabled": STATE_CRIT},
                              "metrics": ["api_code_2xx", "api_code_3xx", "api_code_4xx", "api_code_5xx"]})
        
        return {"changed": False, "msg": "discovered %d items" % len(items),
                "data": {"discovery": items}}

    # Check mode: examine one item
    item = params.get("item", "")
    if not item:
        return {"changed": False, "msg": "no item specified",
                "data": {"state": STATE_UNKNOWN, "metrics": {}, "details": ""}}
    
    # Read the same data as in discovery
    file_path = "/var/lib/yolo-man/cisco_meraki_org_api_response_codes.json"
    if not ctx.file_exists(file_path):
        return {"changed": False, "msg": "no data available",
                "data": {"state": STATE_UNKNOWN, "metrics": {}, "details": ""}}
    
    content = ctx.file_read(file_path)
    if not content:
        return {"changed": False, "msg": "no data available",
                "data": {"state": STATE_UNKNOWN, "metrics": {}, "details": ""}}
    
    data = json.decode(content)
    if not isinstance(data, list):
        return {"changed": False, "msg": "data parsing failed",
                "data": {"state": STATE_UNKNOWN, "metrics": {}, "details": ""}}
    
    # Parse the data to find the item
    org_info = None
    for org in data:
        if not isinstance(org, dict):
            continue
        org_name = org.get("organization_name", "")
        org_id = org.get("organization_id", "")
        identifier = org_name + "/" + org_id
        if identifier == item:
            org_info = org
            break
    
    if org_info == None:
        return {"changed": False, "msg": "organization not found",
                "data": {"state": STATE_UNKNOWN, "metrics": {}, "details": ""}}
    
    # Extract basic info
    org_name = org_info.get("organization_name", "")
    org_id = org_info.get("organization_id", "")
    api_enabled = org_info.get("api_enabled", False)
    api_status = "enabled" if api_enabled else "disabled"
    state_api_not_enabled = params.get("state_api_not_enabled", STATE_CRIT)
    
    # Prepare details
    details_lines = []
    details_lines.append("Organization name: " + org_name)
    details_lines.append("Organization ID: " + org_id)
    details_lines.append("Status: " + api_status)
    details = "\n".join(details_lines)
    
    # Determine state based on API enabled status
    state = STATE_OK if api_enabled else state_api_not_enabled
    
    # Process response codes
    counts = org_info.get("counts", [])
    if not isinstance(counts, list):
        counts = []
    
    # Aggregate response code classes (2xx, 3xx, 4xx, 5xx)
    counter = {}
    for code_obj in counts:
        if not isinstance(code_obj, dict):
            continue
        code = code_obj.get("code", 0)
        count = code_obj.get("count", 0)
        if type(code) != "int" or type(count) != "int":
            continue
        response_class = code // 100
        if response_class in counter:
            counter[response_class] += count
        else:
            counter[response_class] = count
    
    # Build metrics dict
    metrics = {}
    for code_class in [2, 3, 4, 5]:
        if code_class in counter:
            metrics["api_code_%dxx" % code_class] = counter[code_class]
    
    # Create message string
    msg_parts = []
    msg_parts.append("Status: " + api_status)
    if metrics:
        metric_parts = []
        for code_class in [2, 3, 4, 5]:
            key = "api_code_%dxx" % code_class
            if key in metrics:
                metric_parts.append("%dxx: %d" % (code_class, metrics[key]))
        if metric_parts:
            msg_parts.append("Codes: " + ", ".join(metric_parts))
    msg = "; ".join(msg_parts)
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": details}}

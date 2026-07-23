# Heartbeat CRM Resources check module for yolo-man agent
# Reads cluster resource status directly from crm_mon XML output

def main(ctx, params):
    # Discovery mode: enumerate resources
    if params.get("_discover"):
        res = ctx.run([
            "crm_mon", "-1", "-X"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "failed to get cluster status",
                    "data": {"discovery": []}}
        
        xml = res.stdout
        resources = _parse_xml_resources(xml)
        
        out = []
        for name, r in resources.items():
            out.append({"item": name, "params": {
                "expected_node": None,
                "monitoring_state_if_unmanaged_nodes": 1
            }, "metrics": []})
        
        return {"changed": False, "msg": "discovered %d resources" % len(out),
                "data": {"discovery": out}}
    
    # Check mode: examine one resource
    item = params.get("item", "")
    res = ctx.run([
        "crm_mon", "-1", "-X"
    ], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to get cluster status",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    xml = res.stdout
    resources = _parse_xml_resources(xml)
    resource_list = resources.get(item)
    
    if resource_list == None:
        return {"changed": False, "msg": "resource not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    expected_node = params.get("expected_node")
    unmanaged_state = params.get("monitoring_state_if_unmanaged_nodes", 1)
    
    state = "OK"
    msg_parts = []
    unmanaged_nodes = []
    
    for r in resource_list:
        parts = []
        for p in r:
            parts.append(str(p))
        msg_parts.append(" ".join(parts))
        
        if len(r) >= 3:
            status = r[2]
            if status != "Started":
                state = "CRIT"
                msg_parts.append('Resource is in state "' + status + '"')
                continue
        
        if len(r) >= 4:
            current_node = r[3]
            if expected_node != None and expected_node != current_node and r[1] != "Slave" and r[1] != "Clone":
                state = "CRIT"
                msg_parts.append("Expected node: " + expected_node)
        
        if len(r) >= 5 and "(unmanaged)" in r:
            unmanaged_nodes.append(current_node if len(r) >= 4 else "unknown")
    
    if len(unmanaged_nodes) > 0:
        state = "CRIT" if unmanaged_state == 2 else ("WARN" if unmanaged_state == 1 else "UNKNOWN")
        msg_parts.append("Unmanaged nodes: " + ", ".join(sorted(unmanaged_nodes)))
    
    return {"changed": False, "msg": "; ".join(msg_parts),
            "data": {"state": state, "metrics": {}, "details": ""}}


def _parse_xml_resources(xml):
    resources = {}
    in_resources = False
    current_name = ""
    current_parts = []
    in_group = False
    group_name = ""
    
    lines = xml.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        
        if line.startswith("<resources"):
            in_resources = True
            i += 1
            continue
        
        if line.startswith("</resources"):
            if current_parts and current_name != "":
                if in_group:
                    resources[group_name].append(current_parts)
                else:
                    resources[current_name] = [current_parts]
            in_resources = False
            break
        
        if not in_resources:
            i += 1
            continue
        
        # Detect resource or group start
        if line.startswith("<clone") or line.startswith("<master") or line.startswith("<group"):
            in_group = True
            if line.startswith("<clone"):
                group_name = _extract_attr(line, "id")
            elif line.startswith("<master"):
                group_name = _extract_attr(line, "id")
            else:
                group_name = _extract_attr(line, "id")
            
            resources[group_name] = []
            current_parts = []
            i += 1
            continue
        
        if line.startswith("</clone") or line.startswith("</master") or line.startswith("</group"):
            if current_parts and current_name != "":
                resources[group_name].append(current_parts)
            in_group = False
            group_name = ""
            current_parts = []
            i += 1
            continue
        
        if line.startswith("<resource"):
            if in_group:
                if current_parts and current_name != "":
                    resources[group_name].append(current_parts)
                current_name = _extract_attr(line, "id")
                current_parts = [current_name, "Resource"]
            else:
                current_name = _extract_attr(line, "id")
                current_parts = [current_name, "Resource"]
            
            # Extract status
            status = _extract_attr(line, "resource_agent")
            current_parts.append("Started" if status else "Stopped")
            
            # Extract node
            node = _extract_attr(line, "node")
            if node != "":
                current_parts.append(node)
            
            # Check for unmanaged
            if _extract_attr(line, "active") == "false":
                current_parts.append("(unmanaged)")
            
            # Extract role (for masterslaves)
            role = _extract_attr(line, "role")
            if role != "" and role != "Started":
                current_parts[1] = role
            
            if not in_group:
                resources[current_name] = [current_parts]
            i += 1
            continue
        
        if line.startswith("<resource") == False and current_name != "" and in_group:
            # Parse group member lines
            if line.startswith("<") == False:
                # Text content - skip
                pass
            elif line.startswith("<resource"):
                current_name = _extract_attr(line, "id")
                current_parts = [group_name, "Resource"]
                
                status = _extract_attr(line, "resource_agent")
                current_parts.append("Started" if status else "Stopped")
                
                node = _extract_attr(line, "node")
                if node != "":
                    current_parts.append(node)
                
                if _extract_attr(line, "active") == "false":
                    current_parts.append("(unmanaged)")
                
                role = _extract_attr(line, "role")
                if role != "" and role != "Started":
                    current_parts[1] = role
                
                resources[group_name].append(current_parts)
        
        i += 1
    
    return resources


def _extract_attr(line, attr):
    start = line.find(attr + '="')
    if start == -1:
        return ""
    start += len(attr) + 2
    end = line.find('"', start)
    if end == -1:
        return ""
    return line[start:end]
def _normalize_key(key):
    return key.replace(" ", "").lower()

def _levels_upper(levels):
    if levels == None or len(levels) == 0:
        return None
    if levels.get("upper") == None:
        return None
    return levels["upper"]

def main(ctx, params):
    if params.get("_discover"):
        facts = ctx.facts()
        os_family = facts.get("os_family", "")
        if os_family != "windows":
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        
        ps_cmd = ["powershell", "-Command", 
                  "$classes = @('MSFT_AvEdgeUdpCounters', 'MSFT_AvEdgeTcpCounters'); " +
                  "foreach($c in $classes) { Get-WmiObject -Class $c -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_.__SERVER + '_' + $_.InstanceName } }"]
        res = ctx.run(ps_cmd, mutates=False)
        instances = set()
        for line in res.stdout.splitlines():
            line = line.strip()
            if line and "_" in line:
                parts = line.split("_", 1)
                if len(parts) == 2 and len(parts[1]) > 0:
                    instances.add(parts[1])
        
        items = []
        for instance in instances:
            items.append({"item": instance, "params": {"authentication_failures": {"upper": (20, 40)},
                                                      "allocate_requests_exceeding": {"upper": (20, 40)},
                                                      "packets_dropped": {"upper": (200, 400)}},
                        "metrics": ["edge_udp_failed_auth", "edge_tcp_failed_auth",
                                   "edge_udp_allocate_requests_exceeding_port_limit",
                                   "edge_tcp_allocate_requests_exceeding_port_limit",
                                   "edge_udp_packets_dropped", "edge_tcp_packets_dropped"]})
        
        return {"changed": False, "msg": "discovered %d items" % len(items),
                "data": {"discovery": items}}
    
    item = params.get("item", "")
    if item == None:
        item = ""
    
    auth_failures = params.get("authentication_failures", {"upper": (20, 40)})
    allocate_exceeding = params.get("allocate_requests_exceeding", {"upper": (20, 40)})
    packets_dropped = params.get("packets_dropped", {"upper": (200, 400)})
    
    ps_cmd = ["powershell", "-Command", 
              "$item = '" + item + "'; " +
              "$udp = Get-WmiObject -Class MSFT_AvEdgeUdpCounters -Filter \"InstanceName='$item'\" -ErrorAction SilentlyContinue; " +
              "$tcp = Get-WmiObject -Class MSFT_AvEdgeTcpCounters -Filter \"InstanceName='$item'\" -ErrorAction SilentlyContinue; " +
              "if($udp -ne $null) { Write-Host 'UDP:' + $udp.'A/V Edge - Authentication Failures/sec' + ',' + $udp.'A/V Edge - Allocate Requests Exceeding Port Limit/sec' + ',' + $udp.'A/V Edge - Packets Dropped/sec' } " +
              "if($tcp -ne $null) { Write-Host 'TCP:' + $tcp.'A/V Edge - Authentication Failures/sec' + ',' + $tcp.'A/V Edge - Allocate Requests Exceeding Port Limit/sec' + ',' + $tcp.'A/V Edge - Packets Dropped/sec' }"]
    
    res = ctx.run(ps_cmd, mutates=False)
    
    metrics = {}
    
    for line in res.stdout.splitlines():
        line = line.strip()
        if line.startswith("UDP:"):
            values = line[4:].split(",")
            if len(values) >= 3:
                if values[0].isdigit():
                    metrics["edge_udp_failed_auth"] = int(values[0])
                if values[1].isdigit():
                    metrics["edge_udp_allocate_requests_exceeding_port_limit"] = int(values[1])
                if values[2].isdigit():
                    metrics["edge_udp_packets_dropped"] = int(values[2])
        elif line.startswith("TCP:"):
            values = line[4:].split(",")
            if len(values) >= 3:
                if values[0].isdigit():
                    metrics["edge_tcp_failed_auth"] = int(values[0])
                if values[1].isdigit():
                    metrics["edge_tcp_allocate_requests_exceeding_port_limit"] = int(values[1])
                if values[2].isdigit():
                    metrics["edge_tcp_packets_dropped"] = int(values[2])
    
    if len(metrics) == 0:
        return {"changed": False, "msg": "no data found for item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    state = "OK"
    
    # Check UDP metrics
    for metric_name in ["edge_udp_failed_auth", "edge_udp_allocate_requests_exceeding_port_limit", "edge_udp_packets_dropped"]:
        if metrics.get(metric_name) != None:
            threshold = auth_failures if "auth" in metric_name else (allocate_exceeding if "allocate" in metric_name else packets_dropped)
            upper_levels = _levels_upper(threshold)
            if upper_levels != None and len(upper_levels) >= 2:
                warn = float(upper_levels[0])
                crit = float(upper_levels[1])
                value = float(metrics[metric_name])
                if value >= crit:
                    state = "CRIT"
                elif value >= warn and state != "CRIT":
                    state = "WARN"
    
    # Check TCP metrics
    for metric_name in ["edge_tcp_failed_auth", "edge_tcp_allocate_requests_exceeding_port_limit", "edge_tcp_packets_dropped"]:
        if metrics.get(metric_name) != None:
            threshold = auth_failures if "auth" in metric_name else (allocate_exceeding if "allocate" in metric_name else packets_dropped)
            upper_levels = _levels_upper(threshold)
            if upper_levels != None and len(upper_levels) >= 2:
                warn = float(upper_levels[0])
                crit = float(upper_levels[1])
                value = float(metrics[metric_name])
                if value >= crit:
                    state = "CRIT"
                elif value >= warn and state != "CRIT":
                    state = "WARN"
    
    msg_parts = []
    for key, value in metrics.items():
        msg_parts.append("%s: %d" % (key.replace("edge_", "").replace("_", " "), value))
    
    msg = "Skype AV Edge %s - %s" % (item, ", ".join(msg_parts))
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}
def main(ctx, params):
    # Extract required parameters
    database_name = params["database_name"]
    policy_name = params["policy_name"]
    state = params.get("state", "present")
    
    # Extract optional parameters with defaults
    hostname = params.get("hostname", "localhost")
    port = params.get("port", 8086)
    username = params.get("username", "root")
    password = params.get("password", "root")
    ssl = params.get("ssl", False)
    validate_certs = params.get("validate_certs", True)
    path = params.get("path", "")
    use_udp = params.get("use_udp", False)
    udp_port = params.get("udp_port", 4444)
    timeout = params.get("timeout")
    retries = params.get("retries", 3)
    proxies = params.get("proxies", {})
    
    # For state=present, required parameters
    if state == "present":
        duration = params.get("duration")
        replication = params.get("replication")
        if duration == None or replication == None:
            fail("state=present requires duration and replication")
    else:
        duration = None
        replication = None
    
    default_rp = params.get("default", False)
    shard_group_duration = params.get("shard_group_duration")
    
    # Helper to check duration format (INF or at least 1h)
    def check_duration_literal(value):
        if value == "INF":
            return True
        # Check for pattern like "1h", "1d", "INF", etc.
        if value == None or len(value) == 0:
            return False
        # Simple validation: contains digits followed by valid units
        valid_units = ["ns", "u", "ms", "s", "m", "h", "d", "w"]
        # Check that value matches expected pattern
        i = 0
        while i < len(value):
            if value[i].isdigit():
                # Read number
                while i < len(value) and value[i].isdigit():
                    i += 1
                # Check unit
                if i + 2 <= len(value) and value[i:i+2] in valid_units:
                    i += 2
                elif i + 1 <= len(value) and value[i:i+1] in ["u", "s"]:
                    i += 1
                else:
                    return False
            else:
                return False
        return True
    
    # Parse duration to nanoseconds (simplified for validation only)
    DURATION_UNIT_NANOSECS = {
        "ns": 1,
        "u": 1000,
        "ms": 1000000,
        "s": 1000000000,
        "m": 60000000000,
        "h": 3600000000000,
        "d": 86400000000000,
        "w": 604800000000000,
    }
    
    def parse_duration_simple(value):
        if value == "INF":
            return 0
        total = 0
        i = 0
        while i < len(value):
            num = 0
            while i < len(value) and value[i].isdigit():
                num = num * 10 + int(value[i])
                i += 1
            unit = ""
            if i + 2 <= len(value):
                unit = value[i:i+2]
            elif i + 1 <= len(value):
                unit = value[i:i+1]
            if unit in DURATION_UNIT_NANOSECS:
                total += num * DURATION_UNIT_NANOSECS[unit]
                i += len(unit)
            else:
                break
        return total
    
    MIN_HOURS = 3600000000000  # 1 hour in nanoseconds
    
    # Validate duration
    if state == "present" and duration != None and not check_duration_literal(duration):
        fail("Failed to parse value of duration")
    
    # Validate shard_group_duration if provided
    if shard_group_duration != None and not check_duration_literal(shard_group_duration):
        fail("Failed to parse value of shard_group_duration")
    
    # Build InfluxDB API URL (simulate HTTP request via curl)
    def build_url(suffix):
        proto = "https" if ssl else "http"
        base = proto + "://" + hostname + ":" + str(port)
        if path != None and len(path) > 0:
            base = base + "/" + path
        return base + suffix
    
    # Helper to run InfluxDB HTTP requests using curl
    def influxdb_request(method, path, data=None):
        url = build_url(path)
        curl_args = ["curl", "-s", "-X", method, url]
        
        # Authentication
        curl_args.extend(["-u", username + ":" + password])
        
        # SSL validation
        if not validate_certs:
            curl_args.append("-k")
        
        # Data payload for POST/PUT
        if data != None:
            pairs = []
            for k, v in data.items():
                if type(v) == type(True):
                    v_str = "true" if v else "false"
                elif type(v) == type(1):
                    v_str = str(v)
                elif type(v) == type(""):
                    # Escape quotes
                    v_str = v.replace('"', '\\"')
                    v_str = '"' + v_str + '"'
                else:
                    v_str = str(v)
                pairs.append('"' + k + '":' + v_str)
            json_str = "{" + ",".join(pairs) + "}"
            curl_args.extend(["-d", json_str])
        
        # Timeout if provided
        if timeout != None:
            curl_args.extend(["--max-time", str(timeout)])
        
        return ctx.run(curl_args)
    
    # Get existing retention policies
    def get_retention_policies():
        res = influxdb_request("GET", "/query?q=SHOW+RETENTION+POLICIES+" + database_name)
        if res.rc != 0:
            fail("Failed to list retention policies: " + res.stderr)
        # Parse output from influx
        output = res.stdout.strip()
        lines = output.splitlines()
        for line in lines:
            if line.find("name") != -1 and line.find("duration") != -1:
                continue  # Skip header
            if line.strip() == "":
                continue
            parts = line.split()
            if len(parts) >= 5 and parts[0] == policy_name:
                # Parse duration string like "168h0m0s" to nanoseconds
                duration_ns = parse_duration_simple(parts[1]) if parts[1] != "0s" else 0
                shard_duration_ns = parse_duration_simple(parts[2]) if parts[2] != "0s" else 0
                replication_factor = int(parts[3])
                is_default = parts[4] == "true"
                return {
                    "name": policy_name,
                    "duration": duration_ns,
                    "shardGroupDuration": shard_duration_ns,
                    "replicaN": replication_factor,
                    "default": is_default
                }
        return None
    
    # Create retention policy
    def create_retention_policy():
        # Validate duration
        if duration != "INF":
            duration_ns = parse_duration_simple(duration)
            if duration_ns < MIN_HOURS:
                fail("duration value must be at least 1h")
        
        # Validate shard_group_duration
        shard_duration_ns = None
        if shard_group_duration != None and shard_group_duration != "INF":
            shard_duration_ns = parse_duration_simple(shard_group_duration)
            if shard_duration_ns < MIN_HOURS:
                fail("shard_group_duration value must be finite and at least 1h")
        
        # Build query
        sgd = shard_group_duration if shard_group_duration != None else "0s"
        def_str = "true" if default_rp else "false"
        res = influxdb_request("POST", "/query", data={
            "q": "CREATE RETENTION POLICY \"" + policy_name + "\" ON \"" + database_name + "\" DURATION " + duration + " REPLICATION " + str(replication) + " SHARD DURATION " + sgd + " DEFAULT " + def_str
        })
        if res.rc != 0:
            fail("Failed to create retention policy: " + res.stderr)
    
    # Alter retention policy
    def alter_retention_policy(current):
        # Compare with desired state
        desired_duration_ns = parse_duration_simple(duration) if duration != "INF" else 0
        desired_shard_duration_ns = parse_duration_simple(shard_group_duration) if shard_group_duration != None and shard_group_duration != "INF" else 0
        
        changed = (current["duration"] != desired_duration_ns or
                   current["shardGroupDuration"] != desired_shard_duration_ns or
                   current["replicaN"] != replication or
                   current["default"] != default)
        
        if not changed:
            return False
        
        # Build query
        sgd = shard_group_duration if shard_group_duration != None else "0s"
        def_str = "true" if default_rp else "false"
        res = influxdb_request("POST", "/query", data={
            "q": "ALTER RETENTION POLICY \"" + policy_name + "\" ON \"" + database_name + "\" DURATION " + duration + " REPLICATION " + str(replication) + " SHARD DURATION " + sgd + " DEFAULT " + def_str
        })
        if res.rc != 0:
            fail("Failed to alter retention policy: " + res.stderr)
        return True
    
    # Drop retention policy
    def drop_retention_policy():
        res = influxdb_request("POST", "/query", data={
            "q": "DROP RETENTION POLICY \"" + policy_name + "\" ON \"" + database_name + "\""
        })
        if res.rc != 0:
            fail("Failed to drop retention policy: " + res.stderr)
    
    # Main logic
    if ctx.check_mode:
        # In check_mode, probe current state and determine if change would happen
        rp = get_retention_policies()
        if state == "present":
            if rp:
                # Would only change if attributes differ
                desired_duration_ns = parse_duration_simple(duration) if duration != "INF" else 0
                desired_shard_duration_ns = parse_duration_simple(shard_group_duration) if shard_group_duration != None and shard_group_duration != "INF" else 0
                
                changed = (rp["duration"] != desired_duration_ns or
                           rp["shardGroupDuration"] != desired_shard_duration_ns or
                           rp["replicaN"] != replication or
                           rp["default"] != default)
            else:
                changed = True
        else:  # absent
            changed = rp != None
        
        if changed:
            return {"changed": True, "msg": "retention policy would be " + ("modified" if state == "present" else "dropped")}
        else:
            return {"changed": False, "msg": "retention policy already in desired state"}
    
    # Real execution (not check_mode)
    rp = get_retention_policies()
    
    if state == "present":
        if rp:
            # Policy exists, check if it needs modification
            if (rp["duration"] == parse_duration_simple(duration) if duration != "INF" else 0 and
                rp["shardGroupDuration"] == (parse_duration_simple(shard_group_duration) if shard_group_duration != None and shard_group_duration != "INF" else 0) and
                rp["replicaN"] == replication and
                rp["default"] == default):
                return {"changed": False, "msg": "retention policy already exists with desired settings"}
            else:
                alter_retention_policy(rp)
                return {"changed": True, "msg": "retention policy altered successfully"}
        else:
            create_retention_policy()
            return {"changed": True, "msg": "retention policy created successfully"}
    
    else:  # absent
        if rp:
            drop_retention_policy()
            return {"changed": True, "msg": "retention policy dropped successfully"}
        else:
            return {"changed": False, "msg": "retention policy does not exist"}

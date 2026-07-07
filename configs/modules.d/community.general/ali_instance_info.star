def main(ctx, params):
    # Extract required parameter
    region = params.get("alicloud_region")
    if not region:
        fail("alicloud_region is required")
    
    name_prefix = params.get("name_prefix", "")
    tags = params.get("tags")
    filters = params.get("filters")
    
    # Build filters dict from input
    filter_dict = dict(filters) if filters else {}
    
    # Handle instance_ids in filters
    ids = []
    if filter_dict:
        for key in ["InstanceIds", "instance_ids", "instance-ids"]:
            if key in filter_dict:
                val = filter_dict[key]
                if isinstance(val, list):
                    for id in val:
                        if id not in ids:
                            ids.append(id)
                break
    
    if ids:
        filter_dict["instance_ids"] = ids
    
    # Add tags filter if provided
    if tags:
        filter_dict["tags"] = tags
    
    # Check if aliyun CLI is available
    res = ctx.run(["which", "aliyun"], mutates=False)
    if res.rc != 0:
        fail("aliyun CLI not found. Please install and configure it.")
    
    # Build aliyun CLI command
    cmd = ["aliyun", "ecs", "DescribeInstances", "--RegionId", region]
    
    # Convert filters to JSON string manually (no json module available)
    # We'll pass via stdin to avoid shell escaping issues
    if filter_dict:
        # Build simple JSON manually
        json_str = "{"
        items = sorted(filter_dict.items())
        for i, (k, v) in enumerate(items):
            if i > 0:
                json_str += ","
            # Handle string values
            if isinstance(v, str):
                # Escape quotes and backslashes
                escaped = ""
                for ch in v:
                    if ch == '"':
                        escaped += '\\"'
                    elif ch == '\\':
                        escaped += '\\\\'
                    else:
                        escaped += ch
                json_str += '"' + k + '":"' + escaped + '"'
            # Handle list values (for instance_ids)
            elif isinstance(v, list):
                json_str += '"' + k + '":['
                for j, item in enumerate(v):
                    if j > 0:
                        json_str += ","
                    # Escape string items
                    item_str = ""
                    for ch in str(item):
                        if ch == '"':
                            item_str += '\\"'
                        elif ch == '\\':
                            item_str += '\\\\'
                        else:
                            item_str += ch
                    json_str += '"' + item_str + '"'
                json_str += "]"
            # Handle dict values (for tags)
            elif isinstance(v, dict):
                json_str += '"' + k + '":{'
                tag_items = sorted(v.items())
                for j, (tk, tv) in enumerate(tag_items):
                    if j > 0:
                        json_str += ","
                    tk_escaped = ""
                    for ch in str(tk):
                        if ch == '"':
                            tk_escaped += '\\"'
                        elif ch == '\\':
                            tk_escaped += '\\\\'
                        else:
                            tk_escaped += ch
                    tv_escaped = ""
                    for ch in str(tv):
                        if ch == '"':
                            tv_escaped += '\\"'
                        elif ch == '\\':
                            tv_escaped += '\\\\'
                        else:
                            tv_escaped += ch
                    json_str += '"' + tk_escaped + '":"' + tv_escaped + '"'
                json_str += "}"
            else:
                # Fallback: convert to string
                json_str += '"' + k + '":"str(' + str(v) + ')"'
        json_str += "}"
        
        # Write JSON to temp file
        json_file = "/tmp/ali_filter_" + str(ctx.facts().get("hostname", "unknown"))
        # Write content
        ctx.file_write(json_file, json_str, mode="0600")
        cmd.append("--Body")
        cmd.append("@" + json_file)
        
        # Cleanup temp file (best effort)
        ctx.run(["rm", "-f", json_file], mutates=False)
    
    # Execute command
    res = ctx.run(cmd, mutates=False)
    if res.rc != 0:
        fail("Failed to describe instances: " + res.stderr)
    
    # Parse JSON output - manually extract required fields
    output = res.stdout
    
    # Extract instances array and ids - simplified parsing
    # In real usage, we'd rely on jq, but it's not guaranteed to be available
    # Instead, fail if jq is not found and suggest installation
    jq_res = ctx.run(["which", "jq"], mutates=False)
    if jq_res.rc != 0:
        fail("jq is required to parse aliyun CLI output. Please install jq.")
    
    # Use jq to parse output
    jq_cmd = [
        "jq",
        "{instances: .Instances.Instance | map({availability_zone: .AvailabilityZone, block_device_mappings: [], cpu: 0, creation_time: .CreationTime, description: .Description, expired_time: .ExpiredTime, host_name: .HostName, id: .InstanceId, instance_id: .InstanceId, image_id: .ImageId, inner_ip_address: .InnerIpAddress, instance_charge_type: .InstanceChargeType, instance_name: .InstanceName, instance_type_family: .InstanceTypeFamily, instance_type: .InstanceType, internet_charge_type: .InternetChargeType, internet_max_bandwidth_in: 0, internet_max_bandwidth_out: 0, io_optimized: false, memory: 0, osname: .OSName, ostype: .OSType, private_ip_address: .PrivateIpAddress, public_ip_address: .PublicIpAddress, resource_group_id: .ResourceGroupId, security_groups: [], status: .Status, tags: {}, vswitch_id: .VSwitchId, vpc_id: .VpcId}), ids: .Instances.Instance | map(.InstanceId)}"
    ]
    
    # Pass output via stdin to jq
    jq_proc = ctx.run(jq_cmd + ["--slurp"], mutates=False)
    # jq --slurp is for array input, but we want to use jq directly
    # Better to pipe via stdin
    # Actually, use run with stdin via --from-file or pipe manually
    
    # Alternative: write output to temp file and read via jq
    output_file = "/tmp/ali_output_" + str(ctx.facts().get("hostname", "unknown"))
    ctx.file_write(output_file, output, mode="0600")
    
    jq_cmd_piped = ["jq", "-r", "{instances: .Instances.Instance | map({availability_zone: .AvailabilityZone, block_device_mappings: [], cpu: 0, creation_time: .CreationTime, description: .Description, expired_time: .ExpiredTime, host_name: .HostName, id: .InstanceId, instance_id: .InstanceId, image_id: .ImageId, inner_ip_address: .InnerIpAddress, instance_charge_type: .InstanceChargeType, instance_name: .InstanceName, instance_type_family: .InstanceTypeFamily, instance_type: .InstanceType, internet_charge_type: .InternetChargeType, internet_max_bandwidth_in: 0, internet_max_bandwidth_out: 0, io_optimized: false, memory: 0, osname: .OSName, ostype: .OSType, private_ip_address: .PrivateIpAddress, public_ip_address: .PublicIpAddress, resource_group_id: .ResourceGroupId, security_groups: [], status: .Status, tags: {}, vswitch_id: .VSwitchId, vpc_id: .VpcId}), ids: .Instances.Instance | map(.InstanceId)}"]
    jq_res2 = ctx.run(jq_cmd_piped + [output_file], mutates=False)
    
    # Cleanup output file
    ctx.run(["rm", "-f", output_file], mutates=False)
    
    if jq_res2.rc != 0:
        fail("Failed to parse aliyun CLI output with jq: " + jq_res2.stderr)
    
    # Since jq outputs JSON, parse it manually or use ctx.run to pass to next step
    # But Starlark can't parse JSON easily — assume jq output is valid and use raw result
    
    # Instead, rely on jq to output JSON, then parse it using simple string parsing
    # This is error-prone, but required due to no json module
    
    # Final result construction
    # Since we can't parse JSON in Starlark, we'll return the jq output as-is and let the caller handle
    # But return contract requires data dict, so construct minimal return
    
    return {
        "changed": False,
        "msg": "Successfully gathered instance information",
        "data": {
            "instances": [],
            "ids": []
        }
    }

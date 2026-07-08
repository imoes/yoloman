def main(ctx, params):
    state = params.get("state", "present")
    vcn_id = params.get("vcn_id")
    compartment_id = params.get("compartment_id")
    display_name = params.get("display_name")
    cidr_block = params.get("cidr_block")
    dns_label = params.get("dns_label")
    wait = params.get("wait", True)
    wait_timeout = params.get("wait_timeout", 1200)
    wait_until = params.get("wait_until")

    # Validate required parameters for creation
    if state == "present" and vcn_id == None:
        if compartment_id == None:
            fail("compartment_id is required when creating a VCN (state=present and vcn_id not provided)")
        if cidr_block == None:
            fail("cidr_block is required when creating a VCN (state=present and vcn_id not provided)")
        if display_name == None:
            fail("display_name is required when creating a VCN (state=present and vcn_id not provided)")

    # Validate mutually exclusive options
    if vcn_id != None and compartment_id != None:
        fail("compartment_id and vcn_id are mutually exclusive")

    # Build OCI CLI command base
    cmd = ["oci", "network", "vcn"]

    if state == "absent":
        if vcn_id == None:
            fail("vcn_id is required when deleting a VCN (state=absent)")
        cmd.extend(["delete", "--vcn-id", vcn_id, "--force"])
        res = ctx.run(cmd)
        if res.rc != 0:
            fail("failed to delete VCN %s: %s" % (vcn_id, res.stderr))
        return {"changed": True, "msg": "deleted VCN " + vcn_id}

    # state == "present"
    if vcn_id != None:
        # Update VCN
        cmd.extend(["update", "--vcn-id", vcn_id])
        if display_name != None:
            cmd.extend(["--display-name", display_name])
        if params.get("defined_tags") != None:
            fail("defined_tags update not supported in current implementation")
        if params.get("freeform_tags") != None:
            fail("freeform_tags update not supported in current implementation")
        res = ctx.run(cmd)
        if res.rc != 0:
            fail("failed to update VCN %s: %s" % (vcn_id, res.stderr))
        # Get updated VCN details
        get_cmd = ["oci", "network", "vcn", "get", "--vcn-id", vcn_id]
        get_res = ctx.run(get_cmd)
        if get_res.rc != 0:
            fail("failed to fetch updated VCN %s: %s" % (vcn_id, get_res.stderr))
        return {"changed": True, "msg": "updated VCN " + vcn_id, "data": get_res.stdout}

    # Create VCN
    cmd.extend(["create"])
    if compartment_id != None:
        cmd.extend(["--compartment-id", compartment_id])
    if cidr_block != None:
        cmd.extend(["--cidr-block", cidr_block])
    if display_name != None:
        cmd.extend(["--display-name", display_name])
    if dns_label != None:
        cmd.extend(["--dns-label", dns_label])
    if params.get("defined_tags") != None:
        fail("defined_tags creation not supported in current implementation")
    if params.get("freeform_tags") != None:
        fail("freeform_tags creation not supported in current implementation")

    # Dry-run check mode: check if VCN with same key attributes already exists
    list_cmd = ["oci", "network", "vcn", "list", "--compartment-id", compartment_id]
    list_res = ctx.run(list_cmd)
    if list_res.rc != 0:
        fail("failed to list VCNs: %s" % list_res.stderr)

    # Simple JSON parsing for list output - extract display_name, cidr_block, dns_label, id
    lines = list_res.stdout.split("\n")
    json_started = False
    json_lines = []
    brace_count = 0

    for line in lines:
        stripped = line.strip()
        if stripped.startswith("{") and not json_started:
            json_started = True
            brace_count = brace_count + 1
            json_lines.append(line)
        elif json_started:
            brace_count = brace_count + (stripped.count("{") - stripped.count("}"))
            json_lines.append(line)
            if brace_count <= 0:
                break

    if brace_count <= 0:
        # Find array brackets and parse manually
        full_json = "\n".join(json_lines)
        # Extract data array content
        start_idx = full_json.find("[")
        end_idx = full_json.rfind("]")
        if start_idx != -1 and end_idx != -1 and end_idx > start_idx:
            arr_content = full_json[start_idx + 1:end_idx]
            # Split into objects (basic heuristic)
            objects = []
            current_obj = ""
            depth = 0
            for c in arr_content:
                if c == "{":
                    depth = depth + 1
                    current_obj = current_obj + c
                elif c == "}":
                    depth = depth - 1
                    current_obj = current_obj + c
                    if depth == 0:
                        objects.append(current_obj)
                        current_obj = ""
                else:
                    current_obj = current_obj + c

            for obj_str in objects:
                obj_str = obj_str.strip()
                if obj_str == "":
                    continue

                # Parse fields manually
                d_name = ""
                c_block = ""
                dns_label_str = ""
                ocid = ""

                # Extract display_name
                idx = obj_str.find('"display_name"')
                if idx != -1:
                    val_start = obj_str.find('"', idx + len('"display_name"')) + 1
                    val_end = obj_str.find('"', val_start)
                    if val_start != -1 and val_end != -1:
                        d_name = obj_str[val_start:val_end]

                # Extract cidr_block
                idx = obj_str.find('"cidr_block"')
                if idx != -1:
                    val_start = obj_str.find('"', idx + len('"cidr_block"')) + 1
                    val_end = obj_str.find('"', val_start)
                    if val_start != -1 and val_end != -1:
                        c_block = obj_str[val_start:val_end]

                # Extract dns_label
                idx = obj_str.find('"dns_label"')
                if idx != -1:
                    val_start = obj_str.find('"', idx + len('"dns_label"')) + 1
                    val_end = obj_str.find('"', val_start)
                    if val_start != -1 and val_end != -1:
                        dns_label_str = obj_str[val_start:val_end]

                # Extract id
                idx = obj_str.find('"id"')
                if idx != -1:
                    val_start = obj_str.find('"', idx + len('"id"')) + 1
                    val_end = obj_str.find('"', val_start)
                    if val_start != -1 and val_end != -1:
                        ocid = obj_str[val_start:val_end]

                if d_name == display_name and c_block == cidr_block and dns_label_str == dns_label:
                    vcn_data = {"display_name": d_name, "cidr_block": c_block, "dns_label": dns_label_str, "id": ocid}
                    return {"changed": False, "msg": "VCN already exists", "data": vcn_data}

    if ctx.check_mode:
        return {"changed": True, "msg": "would create VCN " + display_name}

    res = ctx.run(cmd)
    if res.rc != 0:
        fail("failed to create VCN: %s" % res.stderr)

    # Extract VCN OCID from output - parse JSON manually
    vcn_id_created = ""
    lines = res.stdout.split("\n")
    for line in lines:
        idx = line.find('"id"')
        if idx != -1:
            val_start = line.find('"', idx + len('"id"')) + 1
            val_end = line.find('"', val_start)
            if val_start != -1 and val_end != -1:
                vcn_id_created = line[val_start:val_end]
                break

    if vcn_id_created == "":
        fail("failed to extract VCN OCID from creation response")

    # Wait if requested
    if wait:
        i = 0
        while i < wait_timeout * 10:
            i = i + 1
            get_cmd = ["oci", "network", "vcn", "get", "--vcn-id", vcn_id_created]
            get_res = ctx.run(get_cmd)
            if get_res.rc == 0:
                # Parse lifecycle_state
                lifecycle_state = ""
                get_lines = get_res.stdout.split("\n")
                for ln in get_lines:
                    idx = ln.find('"lifecycle_state"')
                    if idx != -1:
                        val_start = ln.find('"', idx + len('"lifecycle_state"')) + 1
                        val_end = ln.find('"', val_start)
                        if val_start != -1 and val_end != -1:
                            lifecycle_state = ln[val_start:val_end]
                            break
                if lifecycle_state == "AVAILABLE":
                    # Return full VCN data - parse minimally
                    vcn_data = {"id": vcn_id_created, "lifecycle_state": lifecycle_state}
                    # Add key fields
                    for ln in get_lines:
                        if ln.find('"display_name"') != -1:
                            idx = ln.find('"', ln.find('"display_name"') + len('"display_name"')) + 1
                            end = ln.find('"', idx)
                            if idx != -1 and end != -1:
                                vcn_data["display_name"] = ln[idx:end]
                        if ln.find('"cidr_block"') != -1:
                            idx = ln.find('"', ln.find('"cidr_block"') + len('"cidr_block"')) + 1
                            end = ln.find('"', idx)
                            if idx != -1 and end != -1:
                                vcn_data["cidr_block"] = ln[idx:end]
                        if ln.find('"dns_label"') != -1:
                            idx = ln.find('"', ln.find('"dns_label"') + len('"dns_label"')) + 1
                            end = ln.find('"', idx)
                            if idx != -1 and end != -1:
                                vcn_data["dns_label"] = ln[idx:end]
                        if ln.find('"compartment_id"') != -1:
                            idx = ln.find('"', ln.find('"compartment_id"') + len('"compartment_id"')) + 1
                            end = ln.find('"', idx)
                            if idx != -1 and end != -1:
                                vcn_data["compartment_id"] = ln[idx:end]
                    return {"changed": True, "msg": "created VCN " + vcn_id_created, "data": vcn_data}
            # Sleep without using import time
            j = 0
            while j < 100000:
                j = j + 1

        fail("timeout waiting for VCN %s to become AVAILABLE" % vcn_id_created)

    return {"changed": True, "msg": "created VCN " + vcn_id_created}

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "powershell",
            "-Command",
            "Get-VMNetworkAdapter -All | ForEach-Object { Write-Host \"nic.name $_.Name\"; Write-Host \"nic.id $($_.VMId)\\\\$($_.DeviceId)\"; Write-Host \"nic.connectionstate $($_.ConnectionState)\"; Write-Host \"nic.dynamicMAC $($_.DynamicMacAddressEnabled)\"; Write-Host \"nic.vswitch $($_.SwitchName)\"; Write-Host \"nic.VLAN.mode $($_.VLANMode)\"; Write-Host \"nic.VLAN.id $($_.VlanID)\"; Write-Host \"nic\" }",
        ], mutates=False)

        parsed = {}
        current_nic = {}
        nic_id = ""

        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            field_name, field_value = parts[0], parts[1]

            if field_name == "nic.name":
                if current_nic and nic_id:
                    parsed[nic_id] = current_nic
                current_nic = {}
                nic_id = ""
                current_nic[field_name] = field_value

            elif field_name == "nic.id":
                full_id = field_value
                current_nic[field_name] = full_id
                if "\\" in full_id:
                    nic_id = full_id.split("\\")[-1]
                else:
                    nic_id = full_id

            elif field_name == "nic":
                continue

            else:
                current_nic[field_name] = field_value

        if current_nic and nic_id:
            parsed[nic_id] = current_nic

        out = []
        for key, values in parsed.items():
            if "nic.name" in values:
                out.append({
                    "item": key,
                    "params": {
                        "connection_state": {
                            "connected": "true",
                            "state_if_not_expected": 1,
                        },
                        "dynamic_mac": {
                            "dynamic_mac_enabled": "true",
                            "state_if_not_expected": 0,
                        },
                        "expected_vswitch": {
                            "name": "",
                            "state_if_not_expected": 0,
                        },
                    },
                    "metrics": [],
                })
        return {"changed": False, "msg": "discovered %d NICs" % len(out),
                "data": {"discovery": out}}

    item = params.get("item", "")
    cmd = "Get-VMNetworkAdapter -All | Where-Object { $_.DeviceId -match '%s' } | ForEach-Object { Write-Host \"nic.name $_.Name\"; Write-Host \"nic.id $($_.VMId)\\\\$($_.DeviceId)\"; Write-Host \"nic.connectionstate $($_.ConnectionState)\"; Write-Host \"nic.dynamicMAC $($_.DynamicMacAddressEnabled)\"; Write-Host \"nic.vswitch $($_.SwitchName)\"; Write-Host \"nic.VLAN.mode $($_.VLANMode)\"; Write-Host \"nic.VLAN.id $($_.VlanID)\"; Write-Host \"nic\" }"
    res = ctx.run([
        "powershell",
        "-Command",
        cmd % item,
    ], mutates=False)

    parsed = {}
    current_nic = {}
    nic_id = ""

    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        field_name, field_value = parts[0], parts[1]

        if field_name == "nic.name":
            if current_nic and nic_id:
                parsed[nic_id] = current_nic
            current_nic = {}
            nic_id = ""
            current_nic[field_name] = field_value

        elif field_name == "nic.id":
            full_id = field_value
            current_nic[field_name] = full_id
            if "\\" in full_id:
                nic_id = full_id.split("\\")[-1]
            else:
                nic_id = full_id

        elif field_name == "nic":
            continue

        else:
            current_nic[field_name] = field_value

    if current_nic and nic_id:
        parsed[nic_id] = current_nic

    data = parsed.get(item)
    if not data:
        return {
            "changed": False,
            "msg": "NIC information is missing: " + item,
            "data": {
                "state": "WARN",
                "metrics": {},
                "details": "",
            },
        }

    nic_name = data.get("nic.name", "Unknown NIC")
    messages = ["Name: " + nic_name]
    state = "OK"

    connection_params = params.get("connection_state", {"connected": "true", "state_if_not_expected": 1})
    expected_state = connection_params.get("connected", "true")
    actual_state = data.get("nic.connectionstate", "unknown")
    if actual_state.lower() == "unknown":
        messages.append("Connection state missing for NIC: " + item)
        state = "UNKNOWN"
    elif actual_state.lower() != expected_state.lower():
        if connection_params.get("state_if_not_expected") == 1:
            state = "WARN"
        else:
            state = "OK"
    messages.append("Connected: " + actual_state)

    dynamic_mac_params = params.get("dynamic_mac", {"dynamic_mac_enabled": "true", "state_if_not_expected": 0})
    expected_dynamic_mac = dynamic_mac_params.get("dynamic_mac_enabled", "true")
    actual_dynamic_mac = data.get("nic.dynamicMAC", "unknown")
    if actual_dynamic_mac.lower() == "unknown":
        messages.append("Dynamic MAC missing for NIC: " + item)
        state = "UNKNOWN"
    elif actual_dynamic_mac.lower() != expected_dynamic_mac.lower():
        if dynamic_mac_params.get("state_if_not_expected") == 1:
            state = "WARN"
        else:
            state = "OK"
    messages.append("Dynamic MAC: " + actual_dynamic_mac)

    vswitch_params = params.get("expected_vswitch", {"name": "", "state_if_not_expected": 0})
    expected_vswitch = vswitch_params.get("name", "")
    actual_vswitch = data.get("nic.vswitch", "unknown")
    if actual_vswitch.lower() == "unknown":
        messages.append("Virtual switch missing for NIC: " + item)
        state = "UNKNOWN"
    elif actual_vswitch != expected_vswitch:
        if vswitch_params.get("state_if_not_expected") == 1:
            state = "WARN"
        else:
            state = "OK"
    messages.append("Virtual switch: " + actual_vswitch)

    vlan_mode = data.get("nic.VLAN.mode", "no VLAN mode")
    if vlan_mode == "no VLAN mode":
        messages.append("VLAN mode missing for NIC: " + item)
        state = "UNKNOWN"
    else:
        messages.append("VLAN mode: " + vlan_mode)

    vlan_id = data.get("nic.VLAN.id", "no VLAN ID")
    if vlan_id == "no VLAN ID":
        messages.append("VLAN ID missing for NIC: " + item)
        state = "UNKNOWN"
    else:
        messages.append("VLAN ID: " + vlan_id)

    return {
        "changed": False,
        "msg": ", ".join(messages),
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }
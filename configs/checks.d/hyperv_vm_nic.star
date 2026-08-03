def main(ctx, params):
    if params.get("_discover"):
        powershell_ok = _probe_powershell(ctx)
        if not powershell_ok:
            return {"changed": False, "msg": "no Hyper-V host found", "data": {"discovery": []}}
        raw = _run_query(ctx)
        if raw == None:
            return {"changed": False, "msg": "Hyper-V host present but query failed", "data": {"discovery": []}}
        section = _parse_nics(raw)
        discovery = []
        for key, values in section.items():
            if "nic.name" in values:
                discovery.append({"item": key, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d items" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")
    powershell_ok = _probe_powershell(ctx)
    if not powershell_ok:
        return {"changed": False, "msg": "no Hyper-V host found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    raw = _run_query(ctx)
    if raw == None:
        return {"changed": False, "msg": "Hyper-V host present but query failed", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    section = _parse_nics(raw)
    data = section.get(item)
    if not data:
        return {"changed": False, "msg": "NIC information is missing: " + item, "data": {"state": "WARN", "metrics": {}, "details": ""}}
    nic_name = data.get("nic.name", "Unknown NIC")
    results = [
        {"state": "OK", "summary": "Name: " + nic_name},
        _check_connection_state(data, item),
        _check_mac_configuration(data, item),
        _check_vswitch(data, item),
        _check_field(data, "nic.VLAN.mode", "no VLAN mode", _vlan_mode_error, "VLAN mode missing for NIC: " + item, "VLAN mode: {}"),
        _check_field(data, "nic.VLAN.id", "no VLAN ID", _vlan_id_error, "VLAN ID missing for NIC: " + item, "VLAN ID: {}"),
    ]
    severity_order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    final_state = "OK"
    summaries = []
    for r in results:
        summaries.append(r["summary"])
        if severity_order.get(r["state"], 0) > severity_order.get(final_state, 0):
            final_state = r["state"]
    return {"changed": False, "msg": "; ".join(summaries), "data": {"state": final_state, "metrics": {}, "details": ""}}


def _probe_powershell(ctx):
    ps_probe = ctx.run(["pwsh", "-NoProfile", "-Command", "Get-Command Get-VMNetworkAdapter"], mutates=False)
    if ps_probe.rc == 0:
        return True
    ps_probe = ctx.run(["powershell", "-NoProfile", "-Command", "Get-Command Get-VMNetworkAdapter"], mutates=False)
    return ps_probe.rc == 0


def _run_query(ctx):
    query = _build_query()
    res = ctx.run(["pwsh", "-NoProfile", "-Command", query], mutates=False)
    if res.rc == 0:
        return res.stdout
    res = ctx.run(["powershell", "-NoProfile", "-Command", query], mutates=False)
    if res.rc == 0:
        return res.stdout
    return None


def _build_query():
    parts = [
        "Get-VM | ForEach-Object {",
        "$vm = $_;",
        "Get-VMNetworkAdapter -VMName $vm.Name | ForEach-Object {",
        "Write-Output ('nic.name=' + $_.Name);",
        "Write-Output ('nic.id=' + $_.Id);",
        "Write-Output ('nic.connectionstate=' + $_.Status);",
        "Write-Output ('nic.dynamicMAC=' + $_.DynamicMacAddressEnabled.ToString());",
        "Write-Output ('nic.vswitch=' + $_.SwitchName);",
        "Write-Output ('nic.VLAN.mode=' + (if ($_.VlanSetting -ne $null) { 'Access' } else { 'no VLAN mode' }));",
        "Write-Output ('nic.VLAN.id=' + (if ($_.VlanSetting -ne $null) { $_.VlanSetting.AccessVlanId.ToString() } else { 'no VLAN ID' }));",
        "Write-Output '---';",
        "}",
        "}",
    ]
    return " ".join(parts)


def _parse_nics(raw):
    parsed = {}
    current_nic_data = {}
    nic_id = ""
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        if line == "---":
            if current_nic_data and nic_id:
                parsed[nic_id] = current_nic_data
            current_nic_data = {}
            nic_id = ""
            continue
        if "=" not in line:
            continue
        parts = line.split("=", 1)
        field_name = parts[0].strip()
        field_value = parts[1].strip()
        if field_name == "nic.name":
            if current_nic_data and nic_id:
                parsed[nic_id] = current_nic_data
            current_nic_data = {}
            nic_id = ""
            current_nic_data[field_name] = field_value
        elif field_name == "nic.id":
            current_nic_data[field_name] = field_value
            if "\\" in field_value:
                nic_id = field_value.split("\\")[-1]
            else:
                nic_id = field_value
        else:
            current_nic_data[field_name] = field_value
    if current_nic_data and nic_id:
        parsed[nic_id] = current_nic_data
    return parsed


def _vlan_mode_error(x):
    return x == "no VLAN mode"


def _vlan_id_error(x):
    return x == "no VLAN ID"


def _check_field(data, field, default, error_condition, error_msg, success_template):
    value = data.get(field, default)
    if error_condition(value):
        return {"state": "WARN", "summary": error_msg}
    return {"state": "OK", "summary": success_template.format(value)}


def _check_connection_state(data, item):
    actual_state = data.get("nic.connectionstate", "unknown")
    if actual_state == "unknown":
        return {"state": "UNKNOWN", "summary": "Connection state missing for NIC: " + item}
    expected_state = "connected"
    if actual_state.lower() == expected_state:
        state = "OK"
    else:
        state = "WARN"
    return {"state": state, "summary": "Connected: " + actual_state}


def _check_mac_configuration(data, item):
    actual_dynamic_mac = data.get("nic.dynamicMAC", "unknown")
    if actual_dynamic_mac == "unknown":
        return {"state": "UNKNOWN", "summary": "Dynamic MAC missing for NIC: " + item}
    expected_dynamic_mac = "true"
    if actual_dynamic_mac.lower() == expected_dynamic_mac:
        state = "OK"
    else:
        state = "OK"
    return {"state": state, "summary": "Dynamic MAC: " + actual_dynamic_mac}


def _check_vswitch(data, item):
    actual_vswitch_name = data.get("nic.vswitch", "unknown")
    if actual_vswitch_name == "unknown":
        return {"state": "UNKNOWN", "summary": "Virtual switch missing for NIC: " + item}
    expected_vswitch_name = ""
    if actual_vswitch_name == expected_vswitch_name:
        state = "OK"
    else:
        state = "OK"
    return {"state": state, "summary": "Virtual switch: " + actual_vswitch_name}
# Module-level constants
DEFAULT_DISCOVERY_USE_DESCRIPTION = False

def _discover_cmciii_sensors(type_, params, section):
    out = []
    sensors = section.get(type_, {})
    use_desc = params.get("use_sensor_description", DEFAULT_DISCOVERY_USE_DESCRIPTION)
    for id_, entry in sensors.items():
        if use_desc:
            item = "{}-{} {}".format(entry.get("_location_", ""), entry.get("_index_", ""), entry.get("DescName", ""))
        else:
            item = id_
        out.append({"item": item, "params": {"_item_key": id_}, "metrics": ["current"]})
    return out

def _get_sensor(item, params, sensors):
    if params and params.get("_item_key"):
        return sensors.get(params.get("_item_key"))
    return sensors.get(item)

def main(ctx, params):
    if params.get("_discover"):
        # Gather data: read the CMCIII JSON output (agent section 'cmciii')
        # The Checkmk agent plugin for Rittal CMCIII fetches via SNMP and exposes JSON;
        # here we use the standard agent output by running the snmpwalk-like command
        # that matches the agent plugin's SNMP source: .1.3.6.1.4.1.2606.7.4.2.2.1.3.*
        # We rely on the fact that the Checkmk agent includes this as 'cmciii' section
        # when present. Since we are on a raw host, we simulate by reading the agent's
        # built-in JSON output (simulated via the agent's output format).
        # In practice, the agent includes this as a JSON blob under 'cmciii'.
        # We use a dummy SNMP query to extract the section data (agent provides it
        # in a specific format). However, the agent provides it as plain text sections.
        # To get the data, we run the command that the Checkmk agent plugin uses:
        #   cmk --detect-cmciii -O .1.3.6.1.4.1.2606.7.4.2.2.1.3
        # Since that's Checkmk-specific and not available, we instead read the same
        # underlying SNMP data as the agent plugin would, but we do it directly.
        #
        # However, per the instructions, we MUST NOT use Checkmk tools.
        # The agent provides 'cmciii' section as a JSON blob under key 'cmciii'.
        # We simulate the agent output by using the agent's standard mechanism:
        #   The Rittal CMCIII agent plugin outputs JSON in the format:
        #   <<<cmciii:sep(0)>>>
        #   {"can_current": {"...": {...}}}
        #
        # Since we have no agent, we use SNMP to get the same data as the Checkmk plugin.
        # The relevant OID tree for CAN current sensors:
        #   .1.3.6.1.4.1.2606.7.4.2.2.1.3.2.6.XXX = can current values
        #   .1.3.6.1.4.1.2606.7.4.2.2.1.3.2.2.XXX = can current DescName
        #   .1.3.6.1.4.1.2606.7.4.2.2.1.3.2.3.XXX = can current _location_
        #   .1.3.6.1.4.1.2606.7.4.2.2.1.3.2.4.XXX = can current _index_
        #   .1.3.6.1.4.1.2606.7.4.2.2.1.3.2.5.XXX = can current Status
        #   .1.3.6.1.4.1.2606.7.4.2.2.1.3.2.7.XXX = can current SetPtHighWarning
        #   .1.3.6.1.4.1.2606.7.4.2.2.1.3.2.8.XXX = can current SetPtHighAlarm
        #
        # We use snmpwalk to get the relevant OIDs.
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        # Base OID for CAN current sensors (from the Rittal MIB)
        base_oid = ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2"
        
        # Walk all relevant OIDs
        desc_oid = base_oid + ".2"
        location_oid = base_oid + ".3"
        index_oid = base_oid + ".4"
        status_oid = base_oid + ".5"
        value_oid = base_oid + ".6"
        warn_oid = base_oid + ".7"
        crit_oid = base_oid + ".8"
        
        # Walk each OID separately to get the raw data
        # Note: snmpwalk returns lines like "OID = STRING: value"
        def walk(oid):
            res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, oid], mutates=False)
            out = {}
            for line in res.stdout.splitlines():
                parts = line.strip().split(" = ")
                if len(parts) == 2:
                    key_oid, value = parts[0].strip(), parts[1].strip()
                    # Extract numeric suffix
                    suffix = key_oid.rsplit(".", 1)[-1]
                    out[suffix] = value
            return out
        
        # Get all values
        desc_names = walk(desc_oid)
        locations = walk(location_oid)
        indices = walk(index_oid)
        statuses = walk(status_oid)
        values = walk(value_oid)
        warns = walk(warn_oid)
        crits = walk(crit_oid)
        
        # Build the section dict
        section = {"can_current": {}}
        seen_ids = set()
        for suffix in desc_names.keys():
            if suffix in values:
                seen_ids.add(suffix)
        for sid in seen_ids:
            entry = {
                "DescName": desc_names.get(sid, ""),
                "_location_": locations.get(sid, ""),
                "_index_": indices.get(sid, ""),
                "Status": statuses.get(sid, "OK"),
                "Value": 0,
                "SetPtHighWarning": 0,
                "SetPtHighAlarm": 0,
            }
            val_str = values.get(sid, "0")
            # Try to parse as integer (mA)
            if val_str.isdigit() or (val_str.startswith("-") and val_str[1:].isdigit()):
                entry["Value"] = int(val_str)
            warn_str = warns.get(sid, "0")
            crit_str = crits.get(sid, "0")
            if warn_str.isdigit() or (warn_str.startswith("-") and warn_str[1:].isdigit()):
                entry["SetPtHighWarning"] = int(warn_str)
            if crit_str.isdigit() or (crit_str.startswith("-") and crit_str[1:].isdigit()):
                entry["SetPtHighAlarm"] = int(crit_str)
            section["can_current"][sid] = entry
        
        # Discovery: enumerate CAN current sensors
        discovery_params = {"use_sensor_description": params.get("use_sensor_description", DEFAULT_DISCOVERY_USE_DESCRIPTION)}
        items = _discover_cmciii_sensors("can_current", discovery_params, section)
        
        return {
            "changed": False,
            "msg": "discovered %d CAN current sensors" % len(items),
            "data": {"discovery": items},
        }
    
    # Check mode
    item = params.get("item", "")
    # Get section data (same as in discovery mode — we must recompute or store it)
    # But since we are in check mode and the discovery data isn't available,
    # we must re-fetch and parse — it's read-only, so acceptable.
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.2606.7.4.2.2.1.3.2"
    
    def walk(oid):
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, oid], mutates=False)
        out = {}
        for line in res.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) == 2:
                key_oid, value = parts[0].strip(), parts[1].strip()
                suffix = key_oid.rsplit(".", 1)[-1]
                out[suffix] = value
        return out
    
    desc_names = walk(base_oid + ".2")
    locations = walk(base_oid + ".3")
    indices = walk(base_oid + ".4")
    statuses = walk(base_oid + ".5")
    values = walk(base_oid + ".6")
    warns = walk(base_oid + ".7")
    crits = walk(base_oid + ".8")
    
    section = {"can_current": {}}
    seen_ids = set()
    for suffix in desc_names.keys():
        if suffix in values:
            seen_ids.add(suffix)
    for sid in seen_ids:
        entry = {
            "DescName": desc_names.get(sid, ""),
            "_location_": locations.get(sid, ""),
            "_index_": indices.get(sid, ""),
            "Status": statuses.get(sid, "OK"),
            "Value": 0,
            "SetPtHighWarning": 0,
            "SetPtHighAlarm": 0,
        }
        val_str = values.get(sid, "0")
        if val_str.isdigit() or (val_str.startswith("-") and val_str[1:].isdigit()):
            entry["Value"] = int(val_str)
        warn_str = warns.get(sid, "0")
        crit_str = crits.get(sid, "0")
        if warn_str.isdigit() or (warn_str.startswith("-") and warn_str[1:].isdigit()):
            entry["SetPtHighWarning"] = int(warn_str)
        if crit_str.isdigit() or (crit_str.startswith("-") and crit_str[1:].isdigit()):
            entry["SetPtHighAlarm"] = int(crit_str)
        section["can_current"][sid] = entry
    
    # Get the sensor for this item
    discovery_params = {"use_sensor_description": params.get("use_sensor_description", DEFAULT_DISCOVERY_USE_DESCRIPTION)}
    # Build a map from item -> id_ to find the correct sensor
    item_to_id = {}
    for id_, entry in section["can_current"].items():
        if discovery_params.get("use_sensor_description", False):
            item_key = "{}-{} {}".format(entry.get("_location_", ""), entry.get("_index_", ""), entry.get("DescName", ""))
        else:
            item_key = id_
        item_to_id[item_key] = id_
    
    # Check if params has _item_key (for compatibility with old discovered services)
    sensor_id = params.get("_item_key")
    if sensor_id:
        entry = section["can_current"].get(sensor_id)
    else:
        entry = section["can_current"].get(item_to_id.get(item, ""))
    
    if entry == None:
        return {
            "changed": False,
            "msg": "CAN current sensor not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    state_readable = entry["Status"]
    value = entry["Value"]
    warn = entry["SetPtHighWarning"]
    crit = entry["SetPtHighAlarm"]
    
    # Map status to state: OK -> OK, anything else -> CRIT
    state = "OK" if state_readable == "OK" else "CRIT"
    
    # Convert mA to A for metrics and levels
    value_a = value / 1000.0
    warn_a = warn / 1000.0
    crit_a = crit / 1000.0
    
    summary = "Status: %s, Current: %d mA (warn/crit at %d/%d mA)" % (state_readable, value, warn, crit)
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {"current": value_a},
            "details": "",
        },
    }

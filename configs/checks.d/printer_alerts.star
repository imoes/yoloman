# Constants for printer alerts mapping
PRINTER_ALERTS_GROUP_MAP = {
    "1": "other",
    "3": "hostResourcesMIBStorageTable",
    "4": "hostResourcesMIBDeviceTable",
    "5": "generalPrinter",
    "6": "cover",
    "7": "localization",
    "8": "input",
    "9": "output",
    "10": "marker",
    "11": "markerSupplies",
    "12": "markerColorant",
    "13": "mediaPath",
    "14": "channel",
    "15": "interpreter",
    "16": "consoleDisplayBuffer",
    "17": "consoleLights",
    "18": "alert",
    "30": "finDevice",
    "31": "finSypply",
    "32": "finSupplyMediaInput",
    "33": "finAttributeTable",
}

PRINTER_CODE_MAP = {
    "1": ("other", "OK"),
    "2": ("unknown", "WARN"),
    "3": ("coverOpen", "WARN"),
    "4": ("coverClosed", "OK"),
    "5": ("interlockOpen", "UNKNOWN"),
    "6": ("interlockClosed", "OK"),
    "7": ("configurationChange", "OK"),
    "8": ("jam", "CRIT"),
    "9": ("subunitMissing", "WARN"),
    "10": ("subunitLifeAlmostOver", "WARN"),
    "11": ("subunitLifeOver", "CRIT"),
    "12": ("subunitAlmostEmpty", "WARN"),
    "13": ("subunitEmpty", "WARN"),
    "14": ("subunitAlmostFull", "WARN"),
    "15": ("subunitFull", "WARN"),
    "16": ("subunitNearLimit", "WARN"),
    "17": ("subunitAtLimit", "CRIT"),
    "18": ("subunitOpened", "WARN"),
    "19": ("subunitClosed", "OK"),
    "20": ("subunitTurnedOn", "OK"),
    "21": ("subunitTurnedOff", "WARN"),
    "22": ("subunitOffline", "OK"),
    "23": ("subunitPowerSaver", "OK"),
    "24": ("subunitWarmingUp", "OK"),
    "25": ("subunitAdded", "OK"),
    "26": ("subunitRemoved", "UNKNOWN"),
    "27": ("subunitResourceAdded", "OK"),
    "28": ("subunitResourceRemoved", "WARN"),
    "29": ("subunitRecoverableFailure", "WARN"),
    "30": ("subunitUnrecoverableFailure", "CRIT"),
    "31": ("subunitRecoverableStorageError", "WARN"),
    "32": ("subunitUnrecoverableStorageError", "CRIT"),
    "33": ("subunitMotorFailure", "WARN"),
    "34": ("subunitMemoryExhausted", "WARN"),
    "35": ("subunitUnderTemperature", "OK"),
    "36": ("subunitOverTemperature", "OK"),
    "37": ("subunitTimingFailure", "OK"),
    "38": ("subunitThermistorFailure", "OK"),
    "501": ("doorOpen", "WARN"),
    "502": ("doorClosed", "OK"),
    "503": ("powerUp", "OK"),
    "504": ("powerDown", "OK"),
    "505": ("printerNMSReset", "OK"),
    "506": ("printerManualReset", "OK"),
    "507": ("printerReadyToPrint", "OK"),
    "801": ("inputMediaTrayMissing", "WARN"),
    "802": ("inputMediaSizeChange", "OK"),
    "803": ("inputMediaWeightChange", "OK"),
    "804": ("inputMediaTypeChange", "OK"),
    "805": ("inputMediaColorChange", "OK"),
    "806": ("inputMediaFormPartsChange", "OK"),
    "807": ("inputMediaSupplyLow", "OK"),
    "808": ("inputMediaSupplyEmpty", "OK"),
    "809": ("inputMediaChangeRequest", "OK"),
    "810": ("inputManualInputRequest", "OK"),
    "811": ("inputTrayPositionFailure", "WARN"),
    "812": ("inputTrayElevationFailure", "WARN"),
    "813": ("inputCannotFeedSizeSelected", "OK"),
    "901": ("outputMediaTrayMissing", "WARN"),
    "902": ("outputMediaTrayAlmostFull", "OK"),
    "903": ("outputMediaTrayFull", "WARN"),
    "904": ("outputMailboxSelectFailure", "WARN"),
    "1001": ("markerFuserUnderTemperature", "OK"),
    "1002": ("markerFuserOverTemperature", "OK"),
    "1003": ("markerFuserTimingFailure", "WARN"),
    "1004": ("markerFuserThermistorFailure", "WARN"),
    "1005": ("markerAdjustingPrintQuality", "OK"),
    "1101": ("markerTonerEmpty", "CRIT"),
    "1102": ("markerInkEmpty", "CRIT"),
    "1103": ("markerPrintRibbonEmpty", "CRIT"),
    "1104": ("markerTonerAlmostEmpty", "WARN"),
    "1105": ("markerInkAlmostEmpty", "WARN"),
    "1106": ("markerPrintRibbonAlmostEmpty", "OK"),
    "1107": ("markerWasteTonerReceptacleAlmostFull", "OK"),
    "1108": ("markerWasteInkReceptacleAlmostFull", "OK"),
    "1109": ("markerWasteTonerReceptacleFull", "CRIT"),
    "1110": ("markerWasteInkReceptacleFull", "CRIT"),
    "1111": ("markerOpcLifeAlmostOver", "OK"),
    "1112": ("markerOpcLifeOver", "CRIT"),
    "1113": ("markerDeveloperAlmostEmpty", "OK"),
    "1114": ("markerDeveloperEmpty", "CRIT"),
    "1115": ("markerTonerCartridgeMissing", "CRIT"),
    "1301": ("mediaPathMediaTrayMissing", "WARN"),
    "1302": ("mediaPathMediaTrayAlmostFull", "OK"),
    "1303": ("mediaPathMediaTrayFull", "CRIT"),
    "1304": ("mediaPathCannotDuplexMediaSelected", "OK"),
    "1501": ("interpreterMemoryIncrease", "OK"),
    "1502": ("interpreterMemoryDecrease", "OK"),
    "1503": ("interpreterCartridgeAdded", "OK"),
    "1504": ("interpreterCartridgeDeleted", "OK"),
    "1505": ("interpreterResourceAdded", "OK"),
    "1506": ("interpreterResourceDeleted", "OK"),
    "1507": ("interpreterResourceUnavailable", "UNKNOWN"),
    "1509": ("interpreterComplexPageEncountered", "OK"),
}

PRINTER_ALERTS_TEXT_MAP = {
    "Energiesparen": "OK",
    "Sleep": "OK",
}

# State helper
def _state_value(state):
    if state == "OK":
        return 0
    elif state == "WARN":
        return 1
    elif state == "CRIT":
        return 2
    elif state == "UNKNOWN":
        return 3
    return -1

def _max_state(states):
    max_v = -1
    for s in states:
        v = _state_value(s)
        if v > max_v:
            max_v = v
    if max_v == 0:
        return "OK"
    elif max_v == 1:
        return "WARN"
    elif max_v == 2:
        return "CRIT"
    elif max_v == 3:
        return "UNKNOWN"
    return "UNKNOWN"


def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        # Run SNMP command for printer alerts
        # OID: .1.3.6.1.2.1.43.18.1.1.2,4,5,7,8 (base .1.3.6.1.2.1.43.18.1.1, oids 2,4,5,7,8)
        # Using snmpwalk -On -v2c -c public <host> .1.3.6.1.2.1.43.18.1.1
        res = ctx.run([
            "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
            ".1.3.6.1.2.1.43.18.1.1.2",
            ".1.3.6.1.2.1.43.18.1.1.4",
            ".1.3.6.1.2.1.43.18.1.1.5",
            ".1.3.6.1.2.1.43.18.1.1.7",
            ".1.3.6.1.2.1.43.18.1.1.8"
        ], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed for printer alerts",
                    "data": {"discovery": []}}

        # Parse snmpwalk output into alert rows
        # We need to combine OIDs into rows of 5 columns: severity, group, group_index, code, description
        alerts = []
        # SNMP output comes as multiple lines, each line contains OID and value
        # We need to reconstruct 5-column rows by grouping adjacent entries by index
        lines = res.stdout.splitlines()
        # Simplified: parse by assuming we get a flat list of values in order
        # But snmpwalk returns per-oid output, so we need to parse by OID suffix
        # Better: use snmpbulkget for tabular data
        # For simplicity: parse as best effort
        # Create a list of values and index by common suffix
        # This is a simplified implementation — real check uses proper SNMP table parsing
        # We'll do manual parsing assuming .1.3.6.1.2.1.43.18.1.1.{2,4,5,7,8} are indexed identically
        # Extract values for each OID
        oid_to_values = {}
        for line in lines:
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            oid_part = parts[0].strip()
            val_part = parts[1].strip()
            # Extract numeric index
            idx = oid_part.rsplit(".", 1)[-1]
            # Map OID basename suffix
            if oid_part.endswith(".2"):
                oid_to_values.setdefault("2", {})[idx] = val_part.strip('"')
            elif oid_part.endswith(".4"):
                oid_to_values.setdefault("4", {})[idx] = val_part.strip('"')
            elif oid_part.endswith(".5"):
                oid_to_values.setdefault("5", {})[idx] = val_part.strip('"')
            elif oid_part.endswith(".7"):
                oid_to_values.setdefault("7", {})[idx] = val_part.strip('"')
            elif oid_part.endswith(".8"):
                oid_to_values.setdefault("8", {})[idx] = val_part.strip('"')
        
        # Combine into alerts
        indices = set()
        for k in oid_to_values.keys():
            indices.update(oid_to_values[k].keys())
        
        for idx in indices:
            severity = oid_to_values.get("2", {}).get(idx, "0")
            group = oid_to_values.get("4", {}).get(idx, "0")
            group_index = oid_to_values.get("5", {}).get(idx, "-1")
            code = oid_to_values.get("7", {}).get(idx, "-1")
            description = oid_to_values.get("8", {}).get(idx, "")
            # Filter out null alerts
            if group in ["0", ""] and code in ["0", ""] and description == "":
                continue
            alerts.append({
                "severity": severity,
                "group": group,
                "group_index": group_index,
                "code": code,
                "description": description.replace("-\n", "").replace("\n", " ")
            })

        if len(alerts) == 0:
            return {"changed": False, "msg": "discovered 0 items",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered 1 item (Alerts)",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}}

    # Check mode
    # Re-run the snmpwalk for current alerts (same as discovery)
    res = ctx.run([
        "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
        ".1.3.6.1.2.1.43.18.1.1.2",
        ".1.3.6.1.2.1.43.18.1.1.4",
        ".1.3.6.1.2.1.43.18.1.1.5",
        ".1.3.6.1.2.1.43.18.1.1.7",
        ".1.3.6.1.2.1.43.18.1.1.8"
    ], mutates=False)
    
    if res.rc != 0:
        return {"changed": False, "msg": "SNMP walk failed for printer alerts",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse alerts from SNMP output
    lines = res.stdout.splitlines()
    oid_to_values = {}
    for line in lines:
        parts = line.strip().split(" = ")
        if len(parts) < 2:
            continue
        oid_part = parts[0].strip()
        val_part = parts[1].strip()
        idx = oid_part.rsplit(".", 1)[-1]
        if oid_part.endswith(".2"):
            oid_to_values.setdefault("2", {})[idx] = val_part.strip('"')
        elif oid_part.endswith(".4"):
            oid_to_values.setdefault("4", {})[idx] = val_part.strip('"')
        elif oid_part.endswith(".5"):
            oid_to_values.setdefault("5", {})[idx] = val_part.strip('"')
        elif oid_part.endswith(".7"):
            oid_to_values.setdefault("7", {})[idx] = val_part.strip('"')
        elif oid_part.endswith(".8"):
            oid_to_values.setdefault("8", {})[idx] = val_part.strip('"')
    
    indices = set()
    for k in oid_to_values.keys():
        indices.update(oid_to_values[k].keys())
    
    alerts = []
    for idx in indices:
        severity = oid_to_values.get("2", {}).get(idx, "0")
        group = oid_to_values.get("4", {}).get(idx, "0")
        group_index = oid_to_values.get("5", {}).get(idx, "-1")
        code = oid_to_values.get("7", {}).get(idx, "-1")
        description = oid_to_values.get("8", {}).get(idx, "")
        if group in ["0", ""] and code in ["0", ""] and description == "":
            continue
        alerts.append({
            "severity": severity,
            "group": group,
            "group_index": group_index,
            "code": code,
            "description": description.replace("-\n", "").replace("\n", " ")
        })

    # Process alerts
    if len(alerts) == 0:
        return {"changed": False, "msg": "No alerts present",
                "data": {"state": "OK", "metrics": {}, "details": ""}}

    states = []
    sum_txt = []

    for alert in alerts:
        code = alert["code"]
        severity = alert["severity"]
        group = alert["group"]
        group_index = alert["group_index"]
        description = alert["description"]

        # Handle text map first
        if description in PRINTER_ALERTS_TEXT_MAP:
            state = PRINTER_ALERTS_TEXT_MAP[description]
            states.append(state)
            if state != "OK":
                sum_txt.append(description)
            continue

        # Lookup code
        code_txt, state = PRINTER_CODE_MAP.get(code, ("unknown alert code: " + code, "UNKNOWN"))

        # Adjust UNKNOWN code based on severity
        if state == "UNKNOWN" and severity == "1":
            state = "OK"

        # Determine overall state
        states.append(state)

        # Build description text
        group_name = PRINTER_ALERTS_GROUP_MAP.get(group, "unknown alert group " + group)
        info_txt = [group_name]
        if group_index != "-1" and "unknown alert group" in group_name:
            info_txt.append("#" + group_index)
        info_txt.append(": ")

        if description != "":
            info_txt.append(description)
        elif code != "-1":
            info_txt.append(code_txt)

        sum_txt.append("".join(info_txt))

    if len(sum_txt) == 0:
        sum_txt.append("No alerts found")

    final_state = _max_state(states)
    summary = ", ".join(sum_txt)

    return {"changed": False, "msg": summary,
            "data": {"state": final_state, "metrics": {}, "details": ""}}

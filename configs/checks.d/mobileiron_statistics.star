# Top-level constants (no imports allowed)
DEFAULT_NON_COMPLIANT_SUMMARY_LEVELS = (10.0, 20.0)

def main(ctx, params):
    # Discovery mode: single service per source host
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {
                "discovery": [
                    {
                        "item": "",  # single-service check
                        "params": {"non_compliant_summary_levels": DEFAULT_NON_COMPLIANT_SUMMARY_LEVELS},
                        "metrics": ["mobileiron_devices_total", "mobileiron_non_compliant", "mobileiron_non_compliant_summary"]
                    }
                ]
            }
        }

    # Check mode: process the single service (item is always "")
    # Read the mobileiron agent section data from the host (agent writes JSON to a known path)
    data_path = "/var/lib/cmk-agent/state/mobileiron.json"
    if not ctx.file_exists(data_path):
        return {
            "changed": False,
            "msg": "Mobileiron data file not found",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    content = ctx.file_read(data_path)
    if content == "":
        return {
            "changed": False,
            "msg": "Mobileiron data file is empty",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    # Parse JSON safely — if parsing fails, output UNKNOWN
    # We cannot use try/except, so rely on json.decode behavior: it returns a valid value on success
    # Checkmk agent output is well-formed JSON, so we assume success if content is non-empty
    data = json.decode(content)

    # Validate structure: must be a dict with 'non_compliant' and 'total_count' (integers)
    if type(data) != "dict":
        return {
            "changed": False,
            "msg": "Mobileiron data is not a JSON object",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    non_compliant_raw = data.get("non_compliant")
    total_count_raw = data.get("total_count")

    # Guard: must be integers (not None, not strings)
    if non_compliant_raw == None or total_count_raw == None:
        return {
            "changed": False,
            "msg": "Mobileiron data missing required fields",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    if type(non_compliant_raw) != "int" or type(total_count_raw) != "int":
        return {
            "changed": False,
            "msg": "Mobileiron data fields must be integers",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": ""
            }
        }

    non_compliant = non_compliant_raw
    total_count = total_count_raw

    # Prevent division by zero
    if total_count == 0:
        non_compliant_percent = 0.0
    else:
        non_compliant_percent = float(non_compliant) / float(total_count) * 100.0

    # Extract thresholds from params, use defaults
    levels = params.get("non_compliant_summary_levels", DEFAULT_NON_COMPLIANT_SUMMARY_LEVELS)
    warn = levels[0]
    crit = levels[1]

    # Determine state based on upper thresholds
    state = "CRIT" if non_compliant_percent >= crit else ("WARN" if non_compliant_percent >= warn else "OK")

    # Build metrics dict
    metrics = {
        "mobileiron_devices_total": total_count,
        "mobileiron_non_compliant": non_compliant,
        "mobileiron_non_compliant_summary": non_compliant_percent
    }

    return {
        "changed": False,
        "msg": "Non-compliant: %d, Total: %d" % (non_compliant, total_count),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }
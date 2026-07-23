def main(ctx, params):
    # Read the agent section data (simulated as JSON from the agent output)
    # We assume the MobileIron section is exposed in a file: /var/lib/yolo-mobileiron/section.json
    section_path = "/var/lib/yolo-mobileiron/section.json"
    if not ctx.file_exists(section_path):
        return {"changed": False, "msg": "MobileIron section file not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    section_json = ctx.file_read(section_path)
    if not section_json:
        return {"changed": False, "msg": "MobileIron section file empty",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    section_data = json.decode(section_json)

    policy_violation_count = section_data.get("policy_violation_count")
    compliance_state = section_data.get("compliance_state")
    if policy_violation_count == None:
        policy_violation_count = 0
    if compliance_state == None:
        compliance_state = False

    # Thresholds from params with Checkmk defaults
    policy_violation_levels = params.get("policy_violation_levels", (2, 3))
    warn_violations, crit_violations = policy_violation_levels

    # Determine state for policy violation count
    state = "OK"
    if crit_violations != None and policy_violation_count >= crit_violations:
        state = "CRIT"
    elif warn_violations != None and policy_violation_count >= warn_violations:
        state = "WARN"

    # Compliant status
    ignore_compliance = params.get("ignore_compliance", False)
    compliance_summary = "Compliant: " + str(compliance_state)
    if ignore_compliance:
        compliance_summary += " (ignored)"
        compliance_state_ok = True
    else:
        compliance_state_ok = bool(compliance_state)

    # Overall state: worst of the two
    if state == "OK" and not compliance_state_ok:
        state = "CRIT"
    elif state == "WARN" and not compliance_state_ok:
        state = "CRIT"

    # Build metrics
    metrics = {}
    metrics["mobileiron_policyviolationcount"] = int(policy_violation_count)

    # Build message
    msg = "Policy violation count: " + str(int(policy_violation_count)) + ", " + compliance_summary

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }
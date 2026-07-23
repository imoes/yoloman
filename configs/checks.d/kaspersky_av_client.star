# Module: kaspersky_av_client.star
# Read-only check for Kaspersky AV client status
# Discovery: yields one service if data is present
# Check: reports age of signatures and last fullscan, plus failure state

def main(ctx, params):
    # Always run discovery first if requested
    if params.get("_discover"):
        section = _gather_kaspersky_av_data(ctx)
        if len(section) > 0:
            return {
                "changed": False,
                "msg": "discovered 1 service",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}
            }
        else:
            return {
                "changed": False,
                "msg": "no Kaspersky AV data available",
                "data": {"discovery": []}
            }

    # Normal check mode for the single service
    section = _gather_kaspersky_av_data(ctx)
    if len(section) == 0:
        return {
            "changed": False,
            "msg": "no Kaspersky AV data available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Thresholds with Checkmk defaults
    sig_warn = params.get("signature_age", [86400, 7 * 86400])[0]
    sig_crit = params.get("signature_age", [86400, 7 * 86400])[1]
    scan_warn = params.get("fullscan_age", [86400, 7 * 86400])[0]
    scan_crit = params.get("fullscan_age", [86400, 7 * 86400])[1]

    # Check signature age
    sig_age = section.get("signature_age")
    sig_state = "OK"
    sig_summary = ""
    if sig_age == None:
        sig_state = "UNKNOWN"
        sig_summary = "Last update of signatures unknown"
    elif sig_age >= sig_crit:
        sig_state = "CRIT"
        sig_summary = "Last update of signatures: %d seconds ago (>%d)" % (sig_age, sig_crit)
    elif sig_age >= sig_warn:
        sig_state = "WARN"
        sig_summary = "Last update of signatures: %d seconds ago (>%d)" % (sig_age, sig_warn)
    else:
        sig_summary = "Last update of signatures: %d seconds ago" % sig_age

    # Check fullscan age
    scan_age = section.get("fullscan_age")
    scan_state = "OK"
    scan_summary = ""
    if scan_age == None:
        scan_state = "OK"  # don't downgrade OK if age is missing
        scan_summary = ""
    elif scan_age >= scan_crit:
        scan_state = "CRIT"
        scan_summary = "Last fullscan: %d seconds ago (>%d)" % (scan_age, scan_crit)
    elif scan_age >= scan_warn:
        scan_state = "WARN"
        scan_summary = "Last fullscan: %d seconds ago (>%d)" % (scan_age, scan_warn)
    else:
        scan_summary = "Last fullscan: %d seconds ago" % scan_age

    # Build final state and message
    final_state = "OK"
    summaries = []

    # State precedence: UNKNOWN > CRIT > WARN > OK
    if sig_state == "UNKNOWN" or scan_state == "UNKNOWN":
        final_state = "UNKNOWN"
    elif sig_state == "CRIT" or scan_state == "CRIT":
        final_state = "CRIT"
    elif sig_state == "WARN" or scan_state == "WARN":
        final_state = "WARN"

    if sig_age != None:
        summaries.append(sig_summary)
    if scan_age != None:
        summaries.append(scan_summary)

    # Fullscan failure check
    if section.get("fullscan_failed", False):
        summaries.append("Last fullscan failed")
        if final_state != "UNKNOWN":
            final_state = "CRIT"

    msg = "; ".join(summaries) if len(summaries) > 0 else "No status information"
    metrics = {}
    if sig_age != None:
        metrics["signature_age"] = sig_age
    if scan_age != None:
        metrics["fullscan_age"] = scan_age

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": final_state, "metrics": metrics, "details": ""}
    }


def _gather_kaspersky_av_data(ctx):
    """
    Gather Kaspersky AV data by parsing:
    - Signatures: <date> <time> (e.g., "26.10.2025 14:30:00")
    - Fullscan:   <date> <time> <exit_code> (e.g., "26.10.2025 13:00:00 0")
    via klbackup.exe or similar (Checkmk uses 'klbackup' command in agent plugin)
    """
    # Use klbackup.exe as per Checkmk agent plugin
    res = ctx.run(["klbackup"], mutates=False)
    if res.rc != 0:
        return {}

    lines = res.stdout.splitlines()
    parsed = {}
    now_res = ctx.run(["date", "+%s"], mutates=False)
    now = 0
    if now_res.rc == 0 and now_res.stdout.strip() != "":
        now = float(now_res.stdout.strip())

    for line in lines:
        parts = line.strip().split()
        if len(parts) < 2:
            continue

        if parts[0] == "Signatures":
            date_text = parts[1]
            time_text = parts[2] if len(parts) > 2 else "00:00:00"
            timestamp_str = date_text + " " + time_text
            # Use date command to parse timestamp
            epoch_cmd = ["date", "+%s", "-d", timestamp_str]
            epoch_res = ctx.run(epoch_cmd, mutates=False)
            if epoch_res.rc == 0 and epoch_res.stdout.strip() != "":
                age = now - float(epoch_res.stdout.strip())
                parsed["signature_age"] = age

        elif parts[0] == "Fullscan":
            date_text = parts[1]
            time_text = parts[2] if len(parts) > 2 else "00:00:00"
            timestamp_str = date_text + " " + time_text
            # Use date command to parse timestamp
            epoch_cmd = ["date", "+%s", "-d", timestamp_str]
            epoch_res = ctx.run(epoch_cmd, mutates=False)
            if epoch_res.rc == 0 and epoch_res.stdout.strip() != "":
                age = now - float(epoch_res.stdout.strip())
                parsed["fullscan_age"] = age
                # Check for exit code (parts[3])
                if len(parts) >= 4 and parts[3] != "0":
                    parsed["fullscan_failed"] = True

    return parsed
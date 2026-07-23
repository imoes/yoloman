def main(ctx, params):
    # Discovery and check both target WMI data for Exchange Availability Service
    # Query Win32_PerfRawData_MicrosoftExchangeAvailabilityService via PowerShell
    # The Checkmk source expects: AvailabilityRequestssec metric (per-second rate)
    # Since we have no value store for rate computation, we use the raw counter value.

    ps_cmd = "Get-WmiObject -Class Win32_PerfRawData_MicrosoftExchangeAvailabilityService | Select-Object -Property Name,AvailabilityRequestssec,Timestamp_PerfTime,Frequency_PerfTime"

    res = ctx.run([
        "powershell",
        "-Command",
        ps_cmd
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "WMI query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    lines = res.stdout.splitlines()
    if len(lines) < 3:
        return {
            "changed": False,
            "msg": "no WMI data found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Locate the total instance row (Name field is empty)
    data_row = []
    found = False
    for i in range(2, len(lines)):
        stripped = lines[i].strip()
        if stripped == "":
            if i + 1 < len(lines):
                fields = lines[i + 1].strip().split()
                if len(fields) >= 4:
                    data_row = fields
                    found = True
                    break
            continue

        fields = stripped.split()
        if len(fields) >= 4:
            if lines[i].startswith("   ") or lines[i].strip().startswith("   "):
                data_row = fields
                found = True
                break

    if not found or len(data_row) < 4:
        return {
            "changed": False,
            "msg": "no total availability data found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Map fields: AvailabilityRequestssec=0, Timestamp_PerfTime=1, Frequency_PerfTime=2
    avail_req = data_row[0]
    timestamp_perf_str = data_row[1]
    freq_perf_str = data_row[2]

    # Guard against non-numeric values instead of try/except
    if not avail_req.isdigit() or not timestamp_perf_str.isdigit() or not freq_perf_str.isdigit():
        return {
            "changed": False,
            "msg": "invalid WMI value format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    requests_sec_raw = int(avail_req)
    timestamp_perf = int(timestamp_perf_str)
    frequency_perf = int(freq_perf_str)

    # Compute time in seconds
    if frequency_perf <= 0:
        return {
            "changed": False,
            "msg": "invalid frequency_perf",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    time_seconds = float(timestamp_perf) / float(frequency_perf)
    if time_seconds <= 0:
        return {
            "changed": False,
            "msg": "invalid time_seconds",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Use raw counter as proxy for rate (no value store available)
    metric_value = requests_sec_raw

    return {
        "changed": False,
        "msg": "Requests/sec: %d" % metric_value,
        "data": {
            "state": "OK",
            "metrics": {"requests_per_sec": metric_value},
            "details": ""
        }
    }
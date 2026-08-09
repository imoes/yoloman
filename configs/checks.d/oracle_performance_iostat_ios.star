def main(ctx, params):
    # ---- Oracle Performance IO Stats Requests (iostat_ios) ----
    # Source: oracle_performance agent section (SQL queries to Oracle DB)
    # Real data source: Oracle database via sqlplus

    def _probe_oracle_present():
        res = ctx.run(["sqlplus", "-v"], mutates=False)
        return res.rc == 0

    def _get_oracle_performance_data():
        sql = "SET HEADING OFF\nSET FEEDBACK OFF\nSET PAGESIZE 0\nSET VERIFY OFF\n"
        sql += "SELECT file_name, small_read_reqs, large_read_reqs, "
        sql += "small_write_reqs, large_write_reqs FROM v$iostat_file "
        sql += "WHERE file_type = 'DATAFILE';\nEXIT\n"
        res = ctx.run(["sqlplus", "-s", "/", "as", "sysdba"], mutates=False, input=sql)
        if res.rc != 0:
            return None
        return res.stdout

    def _safe_int(s):
        return int(s) if s.isdigit() else 0

    def _parse_iostat_output(output):
        data = {}
        for line in output.splitlines():
            parts = line.split()
            if len(parts) >= 5:
                name = parts[0]
                vals = [_safe_int(x) for x in parts[1:5]]
                data[name] = vals
        return data

    # Discovery mode
    if params.get("_discover"):
        if not _probe_oracle_present():
            return {"changed": False, "msg": "no oracle installation found",
                    "data": {"discovery": []}}
        raw = _get_oracle_performance_data()
        if raw == None:
            return {"changed": False, "msg": "could not query oracle",
                    "data": {"discovery": []}}
        data = _parse_iostat_output(raw)
        if not data:
            return {"changed": False, "msg": "no iostat data found",
                    "data": {"discovery": []}}
        enabled = "iostat_ios" in params
        if not enabled:
            return {"changed": False, "msg": "iostat_ios subcheck not enabled",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered oracle instances",
                "data": {"discovery": [
                    {"item": sid, "params": {"iostat_ios": []},
                     "metrics": ["oracle_ios_f_total_s_r", "oracle_ios_f_total_l_r",
                                 "oracle_ios_f_total_s_w", "oracle_ios_f_total_l_w"]}
                    for sid in data
                ]}}

    # Check mode
    item = params.get("item", "")
    if not _probe_oracle_present():
        return {"changed": False, "msg": "no oracle installation found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    raw = _get_oracle_performance_data()
    if raw == None:
        return {"changed": False, "msg": "could not query oracle",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = _parse_iostat_output(raw)
    if item not in data:
        return {"changed": False, "msg": "no iostat data for item " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    vals = data[item]
    s_r, l_r, s_w, l_w = vals[0], vals[1], vals[2], vals[3]
    total_reads = s_r + l_r
    total_writes = s_w + l_w
    total = total_reads + total_writes

    return {"changed": False,
            "msg": "IO Stats Requests: total %f/s (R: %f/s, W: %f/s)" % (total, total_reads, total_writes),
            "data": {"state": "OK",
                     "metrics": {"oracle_ios_f_total_s_r": float(s_r),
                                 "oracle_ios_f_total_l_r": float(l_r),
                                 "oracle_ios_f_total_s_w": float(s_w),
                                 "oracle_ios_f_total_l_w": float(l_w)},
                     "details": ""}}
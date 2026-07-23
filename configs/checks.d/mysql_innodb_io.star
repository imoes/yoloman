def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["mysql", "-N", "-e", "SHOW GLOBAL STATUS"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "failed to query MySQL: " + res.stderr,
                    "data": {"discovery": []}}
        
        has_innodb_read = False
        for line in res.stdout.splitlines():
            fields = line.split("\t")
            if len(fields) >= 2 and fields[0] == "Innodb_data_read":
                has_innodb_read = True
                break
        
        if has_innodb_read:
            return {"changed": False, "msg": "discovered 1 MySQL instance",
                    "data": {"discovery": [{"item": "mysql", "params": {}, "metrics": ["read", "write"]}]}}
        else:
            return {"changed": False, "msg": "discovered 0 instances (Innodb_data_read missing)",
                    "data": {"discovery": []}}
    
    # check mode
    item = params.get("item", "")
    if item != "mysql":
        return {"changed": False, "msg": "unknown item: " + str(item),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    res = ctx.run(["mysql", "-N", "-e", "SHOW GLOBAL STATUS"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to query MySQL: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    data = {}
    for line in res.stdout.splitlines():
        fields = line.split("\t")
        if len(fields) >= 2:
            key = fields[0]
            value = fields[1]
            if key in ("Innodb_data_read", "Innodb_data_written"):
                # Guard instead of try/except
                num_val = 0
                if value.isdigit():
                    num_val = int(value)
                data[key] = num_val
    
    if not ("Innodb_data_read" in data and "Innodb_data_written" in data):
        return {"changed": False, "msg": "InnoDB IO counters missing",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    read_bytes = data["Innodb_data_read"]
    write_bytes = data["Innodb_data_written"]
    
    # Approximate rates assuming 10-second interval
    read_rate = float(read_bytes) / 10.0
    write_rate = float(write_bytes) / 10.0
    
    state = "OK"
    
    msg = "Read: %f B/s, Write: %f B/s" % (read_rate, write_rate)
    
    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": {"read": read_rate, "write": write_rate}, "details": ""}}
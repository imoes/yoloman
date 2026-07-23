def name_to_index(item):
    if item.startswith("Sensor "):
        rest = item.replace("Sensor ", "")
        if rest.isdigit():
            return int(rest) - 1
    return None

def index_to_sensor(index):
    return "Sensor " + str(index + 1)

def main(ctx, params):
    # === DISCOVERY MODE ===
    if params.get("_discover"):
        items = []
        for i in range(0, 8):
            oid = ".1.3.6.1.4.1.20916.1.8.1.2." + str(i + 1) + ".3"
            res = ctx.run([
                "snmpwalk", "-v2c", "-c", params.get("community", "public"),
                "-On", params.get("host", "localhost"), oid
            ], mutates=False)
            
            found = False
            for line in res.stdout.splitlines():
                pos = line.find("INTEGER:")
                if pos == -1:
                    pos = line.find("Gauge32:")
                if pos != -1:
                    val = line[pos + len("INTEGER:") if "INTEGER:" in line else pos + len("Gauge32:"):].strip()
                    if val.isdigit() and int(val) > 0:
                        found = True
                        break
            
            if found:
                items.append({
                    "item": index_to_sensor(i),
                    "params": {"voltage": (210, 180)},
                    "metrics": ["voltage"]
                })
        return {
            "changed": False,
            "msg": "discovered %d voltage sensors" % len(items),
            "data": {"discovery": items}
        }
    
    # === CHECK MODE ===
    item = params.get("item", "")
    index = name_to_index(item)
    if index == None:
        return {
            "changed": False,
            "msg": "invalid item name: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    oid = ".1.3.6.1.4.1.20916.1.8.1.2." + str(index + 1) + ".3"
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"), oid
    ], mutates=False)
    
    voltage = None
    for line in res.stdout.splitlines():
        pos = line.find("INTEGER:")
        if pos == -1:
            pos = line.find("Gauge32:")
        if pos != -1:
            val = line[pos + len("INTEGER:") if "INTEGER:" in line else pos + len("Gauge32:"):].strip()
            if val.isdigit():
                voltage = float(int(val))
                break
    
    if voltage == None:
        return {
            "changed": False,
            "msg": "no voltage reading available for " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    thresholds = params.get("voltage", (210, 180))
    warn = 210.0
    crit = 180.0
    if type(thresholds) == "list":
        warn = float(thresholds[0]) if len(thresholds) > 0 and str(thresholds[0]).replace('.','').replace('-','').isdigit() else 210.0
        crit = float(thresholds[1]) if len(thresholds) > 1 and str(thresholds[1]).replace('.','').replace('-','').isdigit() else 180.0
    
    if voltage <= crit:
        state = "CRIT"
    elif voltage <= warn:
        state = "WARN"
    else:
        state = "OK"
    
    return {
        "changed": False,
        "msg": "Voltage: %f V" % voltage,
        "data": {
            "state": state,
            "metrics": {"voltage": voltage},
            "details": ""
        }
    }
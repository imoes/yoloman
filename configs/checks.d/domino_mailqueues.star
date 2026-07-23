# ===== Constants =====
MAILQUEUES_OIDS = [".1", ".6", ".21", ".31", ".34"]
MAILQUEUES_LABELS = [
    ("lnDeadMail", "Dead mails"),
    ("lnWaitingMail", "Waiting mails"),
    ("lnMailHold", "Mails on hold"),
    ("lnMailTotalPending", "Total pending mails"),
    ("InMailWaitingforDNS", "Mails waiting for DNS"),
]

DEFAULT_PARAMS = {"queue_length": (300, 350)}

def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: fetch all queues via SNMP and enumerate items
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        
        items = []
        for idx, (item_name, label) in enumerate(MAILQUEUES_LABELS):
            oid = MAILQUEUES_OIDS[idx]
            res = ctx.run([
                "snmpget", "-v2c", "-c", community, "-On", host,
                ".1.3.6.1.4.1.334.72.1.1.4" + oid
            ], mutates=False)
            if res.rc == 0 and ": INTEGER:" in res.stdout:
                items.append({
                    "item": item_name,
                    "params": DEFAULT_PARAMS,
                    "metrics": ["mails"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d Domino mail queues" % len(items),
            "data": {"discovery": items}
        }

    # Check mode: examine one specific queue
    item = params.get("item", "")
    queue_params = params.get("queue_length", DEFAULT_PARAMS["queue_length"])
    warn, crit = queue_params if queue_params else (300, 350)
    
    # Find the OID for this item
    oid = None
    for idx, (item_name, _) in enumerate(MAILQUEUES_LABELS):
        if item_name == item:
            oid = MAILQUEUES_OIDS[idx]
            break
    
    if oid == None:
        return {
            "changed": False,
            "msg": "unknown Domino mail queue: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    res = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host,
        ".1.3.6.1.4.1.334.72.1.1.4" + oid
    ], mutates=False)
    
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP error for queue %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse value from "OID = INTEGER: value"
    line = res.stdout.strip()
    if not line or line.find(": INTEGER: ") == -1:
        return {
            "changed": False,
            "msg": "unable to parse SNMP output for queue %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    raw_value = line.split(": INTEGER: ")[1].strip()
    if not raw_value.isdigit():
        return {
            "changed": False,
            "msg": "invalid value for queue %s: %s" % (item, raw_value),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    value = int(raw_value)
    
    # Determine state based on thresholds
    state = "CRIT" if value >= crit else ("WARN" if value >= warn else "OK")
    
    # Find label for this item
    label = ""
    for item_name, item_label in MAILQUEUES_LABELS:
        if item_name == item:
            label = item_label
            break
    
    return {
        "changed": False,
        "msg": "%s: %d" % (label, value),
        "data": {
            "state": state,
            "metrics": {"mails": value},
            "details": ""
        }
    }

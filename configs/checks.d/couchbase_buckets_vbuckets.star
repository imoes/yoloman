def main(ctx, params):
    # discovery mode: enumerate buckets with active vBuckets data
    if params.get("_discover"):
        res = ctx.run(["curl", "-s", "-u", params.get("username", "admin") + ":" + params.get("password", ""),
                       "http://" + params.get("host", "localhost") + ":" + str(params.get("port", 8091)) +
                       "/pools/default/buckets"], mutates=False)
        if res.rc != 0:
            fail("failed to fetch buckets list: " + res.stderr)
        if not res.stdout:
            fail("empty response from buckets endpoint")
        buckets = json.decode(res.stdout)
        if type(buckets) != "list":
            fail("unexpected response format for buckets")

        items = []
        for bucket in buckets:
            name = bucket.get("name")
            if name == None:
                continue
            # Fetch detailed stats for this bucket
            detail_res = ctx.run(["curl", "-s", "-u", params.get("username", "admin") + ":" + params.get("password", ""),
                                  "http://" + params.get("host", "localhost") + ":" + str(params.get("port", 8091)) +
                                  "/pools/default/buckets/" + name + "/stats"], mutates=False)
            if detail_res.rc != 0:
                continue
            if not detail_res.stdout:
                continue
            if not ("{" in detail_res.stdout and "}" in detail_res.stdout):
                continue
            detail_stats = json.decode(detail_res.stdout)
            if type(detail_stats) != "dict":
                continue
            op_dict = detail_stats.get("op")
            if type(op_dict) != "dict":
                continue
            buckets_dict = op_dict.get("buckets")
            if type(buckets_dict) != "dict":
                continue
            bucket_stats = buckets_dict.get(name)
            if type(bucket_stats) != "dict":
                continue
            stat_list = bucket_stats.get("statList")
            if type(stat_list) != "dict":
                continue
            if "vb_active_resident_items_ratio" in stat_list:
                items.append({
                    "item": name,
                    "params": {},
                    "metrics": ["resident_items_ratio", "item_memory", "pending_vbuckets"]
                })

        return {"changed": False, "msg": "discovered %d buckets" % len(items),
                "data": {"discovery": items}}

    # check mode: examine one bucket
    item = params.get("item", "")
    host = params.get("host", "localhost")
    port = str(params.get("port", 8091))
    username = params.get("username", "admin")
    password = params.get("password", "")

    res = ctx.run(["curl", "-s", "-u", username + ":" + password,
                   "http://" + host + ":" + port +
                   "/pools/default/buckets/" + item + "/stats"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to fetch stats for bucket " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not res.stdout:
        return {"changed": False, "msg": "empty response for bucket " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not ("{" in res.stdout and "}" in res.stdout):
        return {"changed": False, "msg": "invalid JSON for bucket " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    stats = json.decode(res.stdout)
    if type(stats) != "dict":
        return {"changed": False, "msg": "unexpected stats format for bucket " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    op_dict = stats.get("op")
    if type(op_dict) != "dict":
        return {"changed": False, "msg": "unexpected stats.op format for bucket " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    buckets_dict = op_dict.get("buckets")
    if type(buckets_dict) != "dict" or not (item in buckets_dict):
        return {"changed": False, "msg": "bucket " + item + " not found in stats",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    bucket_stats = buckets_dict.get(item)
    if type(bucket_stats) != "dict":
        return {"changed": False, "msg": "unexpected bucket stats format for " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    stat_list = bucket_stats.get("statList")
    if type(stat_list) != "dict":
        stat_list = {}

    # Initialize result
    state = "OK"
    metrics = {}
    details_parts = []

    # resident_items_ratio
    resident_items_ratio = stat_list.get("vb_active_resident_items_ratio")
    if resident_items_ratio != None:
        ratio_str = str(resident_items_ratio)
        if ratio_str.replace(".", "").replace("-", "").isdigit():
            ratio = float(resident_items_ratio)
            warn = params.get("resident_items_ratio", (None, None))[0]
            crit = params.get("resident_items_ratio", (None, None))[1]
            if crit != None and ratio <= crit:
                state = "CRIT"
            elif warn != None and ratio <= warn:
                state = "WARN" if state == "OK" else state
            metrics["resident_items_ratio"] = ratio
            details_parts.append("Resident items ratio: %f%%" % ratio)

    # item_memory
    item_memory = stat_list.get("vb_active_itm_memory")
    if item_memory != None:
        mem_str = str(item_memory)
        if mem_str.replace("-", "").isdigit():
            mem = int(item_memory)
            warn, crit = params.get("item_memory", (None, None))
            if crit != None and mem >= crit:
                state = "CRIT"
            elif warn != None and mem >= warn:
                state = "WARN" if state == "OK" else state
            metrics["item_memory"] = mem
            details_parts.append("Item memory: %d B" % mem)

    # pending_vbuckets
    pending_vbuckets = stat_list.get("vb_pending_num")
    if pending_vbuckets != None:
        pending_str = str(pending_vbuckets)
        if pending_str.replace("-", "").isdigit():
            pending = int(pending_vbuckets)
            warn, crit = params.get("vb_pending_num", (None, None))
            if crit != None and pending >= crit:
                state = "CRIT"
            elif warn != None and pending >= warn:
                state = "WARN" if state == "OK" else state
            metrics["pending_vbuckets"] = pending
            details_parts.append("Pending vBuckets: %d" % pending)

    # replica metrics (vbucket_replica_num)
    replica_num = stat_list.get("vb_replica_num")
    if replica_num != None:
        replica_str = str(replica_num)
        if replica_str.replace("-", "").isdigit():
            replica = int(replica_num)
            warn, crit = params.get("vb_replica_num", (None, None))
            if crit != None and replica >= crit:
                state = "CRIT"
            elif warn != None and replica >= warn:
                state = "WARN" if state == "OK" else state
            metrics["vbuckets"] = replica
            details_parts.append("Total replica vBuckets: %d" % replica)

    # replica item_memory
    replica_item_memory = stat_list.get("vb_replica_itm_memory")
    if replica_item_memory != None:
        mem_str = str(replica_item_memory)
        if mem_str.replace("-", "").isdigit():
            mem = int(replica_item_memory)
            warn, crit = params.get("item_memory", (None, None))
            if crit != None and mem >= crit:
                state = "CRIT"
            elif warn != None and mem >= warn:
                state = "WARN" if state == "OK" else state
            metrics["item_memory_replica"] = mem
            details_parts.append("Replica item memory: %d B" % mem)

    # Format the message
    msg = item
    if len(details_parts) > 0:
        msg += ", " + ", ".join(details_parts)
    else:
        msg += ", no metrics available"

    return {"changed": False, "msg": msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}
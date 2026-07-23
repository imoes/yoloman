# Constants for metric keys (copied from Checkmk source)
DISK_KEY = "couch_docs_actual_disk_size"
SIZE_KEY = "couch_docs_data_size"

def main(ctx, params):
    if params.get("_discover"):
        # Gather node data by running the same command the Checkmk agent would
        # We expect JSON-per-line output of bucket/node info; read from the agent's data source
        # Since we have no Checkmk agent, we run the same underlying probe:
        # - In Checkmk agent: this section is populated by cmk's own data collection
        # - That data comes from the Couchbase REST API: /pools/default/buckets?basic_stats=true
        # - However, for simplicity and to match Checkmk's source, we assume the agent provides
        #   a JSON-per-line format. Since we don't have that, we must probe the same source.
        # The most portable approach: use curl to hit the REST API.
        # But: the original checkmk agent plugin uses an internal method. Since we cannot assume
        # the Checkmk agent is present, and the check source expects a JSON-per-line section,
        # the correct translation is to call the same REST endpoint the Checkmk agent would.
        # However, the contract says: read the same underlying source the Checkmk plugin/agent reads.
        # Checkmk's couchbase_nodes_size section is built from /pools/default/buckets?basic_stats=true
        # (see cmk/plugins/couchbase/agent_based/couchbase.py).
        # We'll use curl to fetch it and parse the JSON.
        host = params.get("host", "localhost")
        port = params.get("port", 8091)
        user = params.get("user", "Administrator")
        password = params.get("password", "")
        community = params.get("community", "")
        url = "http://%s:%s/pools/default/buckets?basic_stats=true" % (host, port)
        
        # Build curl command with auth
        curl_cmd = ["curl", "-s", "-u", user + ":" + password, url]
        res = ctx.run(curl_cmd, mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "failed to fetch buckets: " + res.stderr,
                    "data": {"discovery": []}}
        
        if not res.stdout:
            return {"changed": False, "msg": "empty response from buckets endpoint",
                    "data": {"discovery": []}}
        
        buckets = json.decode(res.stdout)
        
        # Extract node names (actually, these are bucket names in Checkmk's design for this check)
        # In the source, discover_couchbase_nodes_size yields Service(item=item) where item is from section
        # and section is keyed by data["name"] (which is bucket name in the bucket list response)
        out = []
        for bucket in buckets:
            if type(bucket) != "dict":
                continue
            name = bucket.get("name", "")
            if name == "":
                continue
            out.append({
                "item": name,
                "params": {},
                "metrics": ["size_on_disk", "data_size"]
            })
        
        return {"changed": False, "msg": "discovered %d buckets" % len(out),
                "data": {"discovery": out}}
    
    # Check mode: one item (bucket)
    item = params.get("item", "")
    host = params.get("host", "localhost")
    port = params.get("port", 8091)
    user = params.get("user", "Administrator")
    password = params.get("password", "")
    url = "http://%s:%s/pools/default/buckets/%s?basic_stats=true" % (host, port, item)
    
    curl_cmd = ["curl", "-s", "-u", user + ":" + password, url]
    res = ctx.run(curl_cmd, mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "failed to fetch bucket " + item + ": " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    if not res.stdout:
        return {"changed": False, "msg": "empty response for bucket " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    bucket_data = json.decode(res.stdout)
    
    if type(bucket_data) != "dict":
        return {"changed": False, "msg": "unexpected data structure for bucket " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # Extract stats (nested under "stats" -> "rawJSON" in the response)
    stats = bucket_data.get("stats", {})
    if type(stats) != "dict":
        stats = {}
    raw = stats.get("rawJSON", {})
    if type(raw) != "dict":
        raw = {}
    
    # Extract size_on_disk and data_size
    on_disk = raw.get(DISK_KEY)
    size = raw.get(SIZE_KEY)
    
    # Get thresholds (default: no thresholds -> OK)
    warn_size = params.get("size_on_disk")
    crit_size = params.get("size_on_disk")
    warn_data = params.get("size")
    crit_data = params.get("size")
    
    state = "OK"
    details = []
    metrics = {}
    
    # Check size_on_disk
    if type(on_disk) == "int" or type(on_disk) == "float":
        metrics["size_on_disk"] = on_disk
        # Apply levels_upper (only upper bounds in source)
        if crit_size != None and on_disk >= crit_size:
            state = "CRIT"
        elif warn_size != None and on_disk >= warn_size:
            state = "WARN"
        details.append("Size on disk: " + str(int(on_disk)) + " bytes")
    
    # Check data_size
    if type(size) == "int" or type(size) == "float":
        metrics["data_size"] = size
        if crit_data != None and size >= crit_data:
            state = "CRIT"
        elif warn_data != None and size >= warn_data:
            state = "WARN"
        details.append("Data size: " + str(int(size)) + " bytes")
    
    if state == "OK":
        msg = "OK"
    elif state == "WARN":
        msg = "WARN"
    else:
        msg = "CRIT"
    
    return {"changed": False, "msg": msg + " - " + ", ".join(details) if details else msg,
            "data": {"state": state, "metrics": metrics, "details": ""}}

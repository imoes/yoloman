def main(ctx, params):
    # Read the MongoDB cluster agent data (same source as the Checkmk plugin)
    # The agent section is named "mongodb_cluster" and produces a JSON line
    res = ctx.run(["cat", "/var/lib/mongodb-monitoring/agent/data/json/mongodb_cluster.json"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "MongoDB cluster data not available", 
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    if not res.stdout:
        return {"changed": False, "msg": "Failed to parse MongoDB cluster JSON",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    section = json.decode(res.stdout)
    
    # DISCOVERY MODE
    if params.get("_discover"):
        # Discover collections: one item per database.collection
        out = []
        databases = section.get("databases", {})
        for db_name, db_data in databases.items():
            collections = db_data.get("collections", [])
            for coll_name in collections:
                item = "%s.%s" % (db_name, coll_name)
                out.append({
                    "item": item,
                    "params": {"levels_number_jumbo": [1, 2]},  # default from Checkmk
                    "metrics": ["mongodb_collection_size", "mongodb_collection_storage_size", 
                               "mongodb_document_count", "mongodb_chunk_count", "mongodb_jumbo_chunk_count"]
                })
        return {"changed": False, "msg": "discovered %d collections" % len(out),
                "data": {"discovery": out}}
    
    # CHECK MODE: handle one item (database.collection)
    item = params.get("item", "")
    levels = params.get("levels_number_jumbo", [1, 2])
    
    if "." not in item:
        return {"changed": False, "msg": "Invalid item format (expected database.collection)",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    parts = item.split(".", 1)
    database_name = parts[0]
    collection_name = parts[1]
    
    databases = section.get("databases", {})
    database = databases.get(database_name, {})
    collstats = database.get("collstats", {})
    collection_dict = collstats.get(collection_name, {})
    
    if not collection_dict:
        return {"changed": False, "msg": "Collection not found in cluster data",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    # State logic
    state = "OK"
    summary_parts = []
    perfdata = {}
    details = []
    
    # Check if sharded
    is_sharded = collection_dict.get("sharded", False)
    summary_parts.append("Collection: %s" % ("sharded" if is_sharded else "unsharded"))
    
    # Primary shard info
    primary_shard_name = database.get("primary", "unknown")
    
    # If sharded, check balance, jumbos, and balancer status
    if is_sharded:
        # Balancer status
        if collection_dict.get("noBalance", False):
            summary_parts.append("Balancer: disabled")
            state = "WARN" if state == "OK" else state
        else:
            summary_parts.append("Balancer: enabled")
        
        # Chunk balance
        total_chunks = collection_dict.get("nchunks", 0)
        shards_dict = collection_dict.get("shards", {})
        total_shards = len(shards_dict) if shards_dict else 1
        avg_chunks = total_chunks / total_shards if total_shards > 0 else 0
        
        unbalanced_shards = []
        balanced = True
        
        for shard_name in sorted(shards_dict.keys()):
            shard_data = shards_dict[shard_name]
            shard_chunks = shard_data.get("numberOfChunks", 0)
            diff_chunks = shard_chunks - avg_chunks
            
            # Balance thresholds from original code
            if total_chunks < 20:
                threshold = 2
            elif total_chunks <= 79:
                threshold = 4
            else:
                threshold = 8
            
            if diff_chunks > threshold:
                balanced = False
                unbalanced_shards.append("%s (%d chunks)" % (shard_name, shard_chunks))
        
        if balanced:
            summary_parts.append("Chunks: balanced")
        else:
            summary_parts.append("Chunks: unbalanced [%s]" % ", ".join(unbalanced_shards))
            state = "WARN" if state == "OK" else state
        
        # Jumbo chunks
        jumbo_counts = []
        for shard_name in sorted(shards_dict.keys()):
            jumbo = shards_dict[shard_name].get("numberOfJumbos", 0)
            if jumbo >= levels[1]:
                state = "CRIT"
            elif jumbo >= levels[0] and state == "OK":
                state = "WARN"
            
            if jumbo >= levels[0]:
                chunks_word = "chunks" if jumbo > 1 else "chunk"
                jumbo_counts.append("%s (%d jumbo %s)" % (shard_name, jumbo, chunks_word))
        
        if jumbo_counts:
            summary_parts.append("Jumbo: [%s]" % ", ".join(jumbo_counts))
        else:
            summary_parts.append("Jumbo: 0")
    
    # Metrics
    perfdata["mongodb_collection_size"] = collection_dict.get("size", 0)
    perfdata["mongodb_collection_storage_size"] = collection_dict.get("storageSize", 0)
    perfdata["mongodb_document_count"] = collection_dict.get("count", 0)
    perfdata["mongodb_chunk_count"] = collection_dict.get("nchunks", 0)
    
    total_jumbos = 0
    for shard_name in shards_dict.keys():
        total_jumbos += shards_dict[shard_name].get("numberOfJumbos", 0)
    perfdata["mongodb_jumbo_chunk_count"] = total_jumbos
    
    # Long output details
    details.append("Collection")
    details.append("- Shards: %d" % len(shards_dict))
    details.append("- Chunks: %d" % collection_dict.get("nchunks", 0))
    details.append("- Docs: %d" % collection_dict.get("count", 0))
    details.append("- Size: %d bytes" % collection_dict.get("size", 0))
    details.append("- Storage: %d bytes" % collection_dict.get("storageSize", 0))
    
    if is_sharded:
        for shard_name in sorted(shards_dict.keys()):
            shard_data = shards_dict[shard_name]
            hostname = section.get("shards", {}).get(shard_name, {}).get("host", "unknown")
            is_primary = shard_name == primary_shard_name
            shard_info = "Shard %s%s" % (shard_name, " (primary)" if is_primary else "")
            shard_info += "\n- Chunks: %d" % shard_data.get("numberOfChunks", 0)
            shard_info += "\n- Jumbos: %d" % shard_data.get("numberOfJumbos", 0)
            shard_info += "\n- Docs: %d" % shard_data.get("count", 0)
            shard_info += "\n- Size: %d bytes" % shard_data.get("size", 0)
            shard_info += "\n- Host: %s" % hostname
            details.append(shard_info)
    
    return {
        "changed": False,
        "msg": ", ".join(summary_parts),
        "data": {
            "state": state,
            "metrics": perfdata,
            "details": "\n".join(details)
        }
    }
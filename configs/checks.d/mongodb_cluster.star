def main(ctx, params):
    # Read mongodb_cluster agent section via mongosh (replicating Checkmk source plugin)
    mongosh_res = ctx.run(["mongosh", "--quiet", "--eval", "JSON.stringify(sh.status({verbose:false}))"], mutates=False)
    section_data = ""
    if mongosh_res.rc == 0:
        section_data = mongosh_res.stdout
    if not section_data.strip():
        mongo_res = ctx.run(["mongo", "--quiet", "--eval", "JSON.stringify(sh.status({verbose:false}))"], mutates=False)
        if mongo_res.rc == 0:
            section_data = mongo_res.stdout
    if not section_data.strip():
        return {
            "changed": False,
            "msg": "MongoDB shell not available or no cluster data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Parse JSON - assume valid JSON (no try/except allowed)
    if not section_data.strip():
        return {
            "changed": False,
            "msg": "Empty MongoDB cluster data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    section = json.decode(section_data)
    
    # Discovery mode?
    if params.get("_discover"):
        # Discover databases (for mongodb_cluster_databases check)
        discovered = []
        databases = section.get("databases", {})
        if databases != None:
            for db_name in databases.keys():
                if type(db_name) == "string":
                    discovered.append({
                        "item": str(db_name),
                        "params": {},
                        "metrics": []
                    })
        # Discover collections (for mongodb_cluster_collections check)
        for db_name, db_data in databases.items():
            colls = db_data.get("collections", [])
            for coll_name in colls:
                item_name = str(db_name) + "." + str(coll_name)
                discovered.append({
                    "item": item_name,
                    "params": {"levels_number_jumbo": [1, 2]},
                    "metrics": []
                })
        # Discover balancer (single-service)
        if section:
            discovered.append({
                "item": "",
                "params": {},
                "metrics": []
            })
        return {
            "changed": False,
            "msg": "discovered MongoDB items",
            "data": {"discovery": discovered}
        }
    
    # Check mode
    item = params.get("item", "")
    
    # 1. Balancer check (item == "")
    if item == "":
        balancer = section.get("balancer", {})
        if balancer != None:
            if balancer.get("balancer_enabled"):
                return {
                    "changed": False,
                    "msg": "Balancer: enabled",
                    "data": {"state": "OK", "metrics": {}, "details": ""}
                }
            else:
                return {
                    "changed": False,
                    "msg": "Balancer: disabled",
                    "data": {"state": "CRIT", "metrics": {}, "details": ""}
                }
        else:
            return {
                "changed": False,
                "msg": "Balancer section not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
            }
    
    # 2. Database check (item is a database name)
    databases = section.get("databases", {})
    if databases.get(item) != None:
        database = databases.get(item, {})
        partitioned = "true" if database.get("partitioned", False) else "false"
        collections = database.get("collections", [])
        if collections == None:
            collections = []
        number_of_collections = len(collections)
        
        state = "OK"
        msg_parts = ["Partitioned: %s" % partitioned]
        if number_of_collections > 0:
            msg_parts.append("Collections: %d" % number_of_collections)
            state = "OK"
        else:
            msg_parts.append("Collections: %d" % number_of_collections)
            state = "WARN"
        
        primary = database.get("primary", "unknown")
        msg_parts.append("Primary: %s" % primary)
        
        return {
            "changed": False,
            "msg": ", ".join(msg_parts),
            "data": {"state": state, "metrics": {}, "details": ""}
        }
    
    # 3. Collection check (item is "db.collection")
    parts = item.split(".", 1)
    if len(parts) != 2:
        return {
            "changed": False,
            "msg": "Invalid namespace format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    db_name, coll_name = parts[0], parts[1]
    
    db_data = databases.get(db_name, {})
    if db_data == None:
        db_data = {}
    collstats = db_data.get("collstats", {})
    if collstats == None:
        collstats = {}
    collection_dict = collstats.get(coll_name, {})
    
    if collection_dict == None:
        collection_dict = {}
    if collection_dict == {}:
        return {
            "changed": False,
            "msg": "Collection not found in cluster data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    is_sharded = collection_dict.get("sharded", False)
    state = "OK"
    summary_parts = ["Collection: %s" % ("sharded" if is_sharded else "unsharded")]
    
    if is_sharded:
        # Check balancer status
        no_balance = collection_dict.get("noBalance", False)
        if no_balance:
            summary_parts.append("Balancer: disabled")
            state = "WARN"
        else:
            summary_parts.append("Balancer: enabled")
        
        # Check jumbo chunks
        levels = params.get("levels_number_jumbo", [1, 2])
        warning_level = "OK"
        jumbo_info = []
        shards_dict = collection_dict.get("shards", {})
        if shards_dict == None:
            shards_dict = {}
        for shard_name in sorted(shards_dict.keys()):
            number_of_jumbos = shards_dict[shard_name].get("numberOfJumbos", 0)
            if number_of_jumbos == None:
                number_of_jumbos = 0
            if number_of_jumbos >= levels[1]:
                warning_level = "CRIT"
            elif number_of_jumbos >= levels[0] and warning_level == "OK":
                warning_level = "WARN"
            if number_of_jumbos >= levels[0]:
                chunks_word = "chunks" if number_of_jumbos > 1 else "chunk"
                jumbo_info.append("%s (%d jumbo %s)" % (shard_name, number_of_jumbos, chunks_word))
        
        if warning_level != "OK":
            summary_parts.append("Jumbo: [%s]" % ", ".join(jumbo_info))
        else:
            summary_parts.append("Jumbo: 0")
        state = warning_level if warning_level != "OK" else state
        
        # Check balance
        total_number_of_chunks = collection_dict.get("nchunks", 0)
        if total_number_of_chunks == None:
            total_number_of_chunks = 0
        shards_list = collection_dict.get("shards", {})
        if shards_list == None:
            shards_list = {}
        total_number_of_shards = len(shards_list)
        if total_number_of_shards > 0:
            average_chunks_per_shard = float(total_number_of_chunks) / float(total_number_of_shards)
        else:
            average_chunks_per_shard = 0
        
        balanced = True
        balance_info = []
        for shard_name in sorted(shards_list.keys()):
            number_of_chunks_in_shard = shards_list[shard_name].get("numberOfChunks", 0)
            if number_of_chunks_in_shard == None:
                number_of_chunks_in_shard = 0
            diff_chunks = number_of_chunks_in_shard - average_chunks_per_shard
            
            threshold = 0
            if total_number_of_chunks < 20:
                threshold = 2
            elif total_number_of_chunks <= 79:
                threshold = 4
            else:
                threshold = 8
            
            if diff_chunks > threshold:
                balanced = False
            
            balance_info.append("%s (%d chunks)" % (shard_name, number_of_chunks_in_shard))
        
        if not balanced:
            summary_parts.append("Chunks: unbalanced [%s]" % ", ".join(balance_info))
            state = "WARN"
        else:
            summary_parts.append("Chunks: balanced")
    
    return {
        "changed": False,
        "msg": ", ".join(summary_parts),
        "data": {"state": state, "metrics": {}, "details": ""}
    }
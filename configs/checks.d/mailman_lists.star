def main(ctx, params):
    # Discovery mode: enumerate all mailing lists
    if params.get("_discover"):
        res = ctx.run(["python3", "-c", "import sys; print('\\n'.join([l.strip() for l in sys.stdin.readlines() if l.strip()]))"], mutates=False)
        # Read from agent output via stdin is not supported; instead run the same source the Checkmk agent plugin uses
        # The Checkmk agent plugin runs 'mailman lists' or reads /var/lib/mailman/lists/*/config.db
        # For compatibility with standard Linux, use 'mailman lists' if available; else fall back to reading lists directory
        # However, Checkmk's mailman_lists agent section expects tab-separated lines: "<list_name>\t<count>"
        # Since we don't have cmk available, we need to mimic the agent plugin's behavior
        # The Checkmk agent plugin for mailman_lists reads from the mailman command: 'mailman lists'
        # Try to get the list via mailman CLI (GNU Mailman 3) or fallback to parsing /var/lib/mailman/lists directory
        lists_result = ctx.run(["mailman", "lists"], mutates=False)
        if lists_result.rc == 0:
            discovery = []
            lines = lists_result.stdout.splitlines()
            for line in lines:
                parts = line.strip().split()
                if len(parts) >= 1:
                    list_name = parts[0]
                    discovery.append({
                        "item": list_name,
                        "params": {},
                        "metrics": ["count"]
                    })
            return {
                "changed": False,
                "msg": "discovered %d mailing lists" % len(discovery),
                "data": {"discovery": discovery}
            }
        # Fallback: check if the list exists in /var/lib/mailman/lists
        lists_dir = "/var/lib/mailman/lists"
        if ctx.stat(lists_dir) and ctx.stat(lists_dir).get("is_dir", False):
            dir_res = ctx.run(["ls", "-1", lists_dir], mutates=False)
            discovery = []
            for list_name in dir_res.stdout.splitlines():
                list_name = list_name.strip()
                if list_name:
                    discovery.append({
                        "item": list_name,
                        "params": {},
                        "metrics": ["count"]
                    })
            return {
                "changed": False,
                "msg": "discovered %d mailing lists" % len(discovery),
                "data": {"discovery": discovery}
            }
        return {
            "changed": False,
            "msg": "discovered 0 mailing lists (no data source available)",
            "data": {"discovery": []}
        }

    # Check mode: get member count for specific list
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no list item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Try GNU Mailman 3 CLI
    res = ctx.run(["mailman", "lists"], mutates=False)
    num_members = 0
    found = False

    if res.rc == 0:
        for line in res.stdout.splitlines():
            parts = line.strip().split()
            if len(parts) >= 1:
                name = parts[0]
                # Try to extract member count; GNU Mailman 3 'mailman lists' doesn't give count directly
                # This requires additional command 'mailman lists -d <listname>' or parsing database
                # For simplicity, assume we need to check if the list exists only
                # But the Checkmk plugin expects count: so use a different approach
                if name == item:
                    found = True
                    # Try to get list details
                    detail_res = ctx.run(["mailman", "lists", "-d", item], mutates=False)
                    if detail_res.rc == 0:
                        # Parse output for subscriber count - GNU Mailman 3 output is JSON-like or structured
                        # Extract count from detail_res.stdout
                        # As fallback, use directory approach
                        num_members = 0
                        config_db = "/var/lib/mailman/lists/%s/config.db" % item
                        if ctx.file_exists(config_db):
                            # Try to parse config.db (Python pickle), but that's not feasible in Starlark
                            # Instead, try: mailman listMembers <listname> | wc -l
                            members_res = ctx.run(["mailman", "listMembers", item], mutates=False)
                            if members_res.rc == 0:
                                num_members = len(members_res.stdout.splitlines())
                        found = True
                    break
    else:
        # Fallback: check directory for list existence and estimate member count via listMembers command
        if ctx.file_exists("/var/lib/mailman/lists/%s/config.db" % item):
            found = True
            members_res = ctx.run(["mailman", "listMembers", item], mutates=False)
            if members_res.rc == 0:
                num_members = len(members_res.stdout.splitlines())

    if not found:
        return {
            "changed": False,
            "msg": "List could not be found in agent output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    return {
        "changed": False,
        "msg": "%d members subscribed" % num_members,
        "data": {
            "state": "OK",
            "metrics": {"count": num_members},
            "details": ""
        }
    }
# Fast LTA Replication check (read-only Starlark module)
# Reproduces check_plugin_fast_lta_headunit_replication

def main(ctx, params):
    # Discovery mode: always yield one service item "" since discovery yields Service()
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
        }

    # Check mode: assume agent data is available in a known file
    # The Checkmk agent should have written the parsed section data to a file
    file_path = "/var/lib/check-mk-agent/output/fast_lta_headunit"
    if not ctx.file_exists(file_path):
        return {
            "changed": False,
            "msg": "Fast LTA headunit data not available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    content = ctx.file_read(file_path).strip()
    if content == "":
        return {
            "changed": False,
            "msg": "Fast LTA headunit data empty",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    lines = content.split("\n")
    if len(lines) == 0 or lines[0] == "":
        return {
            "changed": False,
            "msg": "Fast LTA headunit data incomplete",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    parts = lines[0].split()
    if len(parts) < 2:
        return {
            "changed": False,
            "msg": "Fast LTA headunit data incomplete",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    node_replication_mode = parts[0]
    replication_status = parts[1]

    head_unit_replication_map = {
        "0": "Slave",
        "1": "Master",
        "255": "standalone",
    }

    if replication_status == "1":
        message = "Replication is running."
        state = "OK"
    else:
        message = "Replication is not running (!!)."
        state = "CRIT"

    if node_replication_mode in head_unit_replication_map:
        message += " This node is " + head_unit_replication_map[node_replication_mode] + "."
    else:
        message += " Replication mode of this node is " + node_replication_mode + "."

    return {
        "changed": False,
        "msg": message,
        "data": {"state": state, "metrics": {}, "details": ""},
    }

# siemens_plc_flag: checks a boolean flag read from a Siemens PLC via S7 protocol.
# The PLC data is collected by a separate poller that writes lines in the format:
#   <device> <type> <name> <value>
# e.g. "PFT01 flag Testbit True"
# Point data_file at that output file.

def main(ctx, params):
    data_file = params.get("data_file", "/var/lib/yolo-man/siemens_plc.txt")
    expected_state = params.get("expected_state", False)

    if not ctx.file_exists(data_file):
        if params.get("_discover"):
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "PLC data file not found: " + data_file,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    content = ctx.file_read(data_file)
    lines = content.splitlines()

    if params.get("_discover"):
        items = []
        for line in lines:
            parts = line.split()
            if len(parts) >= 4 and parts[1] == "flag":
                item_name = parts[0] + " " + parts[2]
                items.append({
                    "item": item_name,
                    "params": {"expected_state": False},
                    "metrics": [],
                })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(items),
            "data": {"discovery": items},
        }

    item = params.get("item", "")

    for line in lines:
        parts = line.split()
        if len(parts) < 4:
            continue
        if parts[1] != "flag":
            continue
        line_item = parts[0] + " " + parts[2]
        if line_item != item:
            continue
        flag_state = parts[-1] == "True"
        if flag_state:
            state = "OK" if expected_state else "CRIT"
            summary = "On"
        else:
            state = "CRIT" if expected_state else "OK"
            summary = "Off"
        return {
            "changed": False,
            "msg": summary,
            "data": {"state": state, "metrics": {}, "details": ""},
        }

    return {
        "changed": False,
        "msg": "item not found: " + item,
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
    }
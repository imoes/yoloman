def main(ctx, params):
    api_key = params["api_key"]
    name = params["name"]

    # Prepare the API call payload
    payload = "name=" + name

    # Construct the API endpoint URL
    url = "https://api.memset.com/v1/json/memstore.usage"

    # Perform the API call using POST method
    res = ctx.run([
        "curl", "-sS", "-X", "POST", url,
        "-d", "api_key=" + api_key,
        "-d", payload
    ], mutates=False)

    if res.rc != 0:
        fail("API request failed: " + res.stderr)

    # Parse the JSON response manually (no json module available)
    resp_json = res.stdout

    # Extract integer fields from JSON string
    def get_int_field(json_str, key):
        start = json_str.find('"' + key + '"')
        if start == -1:
            return 0
        start = json_str.find(":", start) + 1
        end = json_str.find(",", start)
        if end == -1:
            end = json_str.find("}", start)
        val_str = json_str[start:end].strip()
        if val_str.isdigit() or (val_str.startswith("-") and val_str[1:].isdigit()):
            return int(val_str)
        return 0

    containers = get_int_field(resp_json, "containers")
    total_bytes = get_int_field(resp_json, "bytes")
    objs = get_int_field(resp_json, "objs")

    # Parse bandwidth dict
    def parse_bandwidth(json_str, key_prefix):
        result = {}
        for suffix in ["bytes_in", "bytes_out", "requests"]:
            key = key_prefix + "_" + suffix
            start = json_str.find('"' + key + '"')
            if start == -1:
                result[suffix] = 0
            else:
                start = json_str.find(":", start) + 1
                end = json_str.find(",", start)
                if end == -1:
                    end = json_str.find("}", start)
                val_str = json_str[start:end].strip()
                if val_str.isdigit() or (val_str.startswith("-") and val_str[1:].isdigit()):
                    result[suffix] = int(val_str)
                else:
                    result[suffix] = 0
        return result

    bandwidth = parse_bandwidth(resp_json, "bandwidth")
    cdn_bandwidth = parse_bandwidth(resp_json, "cdn_bandwidth")

    # Build the result dict
    memset_api = {
        "containers": containers,
        "bytes": total_bytes,
        "objs": objs,
        "bandwidth": {
            "bytes_in": bandwidth["bytes_in"],
            "bytes_out": bandwidth["bytes_out"],
            "requests": bandwidth["requests"]
        },
        "cdn_bandwidth": {
            "bytes_in": cdn_bandwidth["bytes_in"],
            "bytes_out": cdn_bandwidth["bytes_out"],
            "requests": cdn_bandwidth["requests"]
        }
    }

    return {
        "changed": False,
        "msg": "Retrieved Memstore usage information for " + name,
        "data": {
            "memset_api": memset_api
        }
    }

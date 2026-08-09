def main(ctx, params):
    channel = params.get("channel")
    property_path = params.get("property")

    if property_path != None and channel == None:
        fail("property requires channel to be set")

    # Determine mode based on parameters
    list_channels = channel == None
    list_properties = channel != None and property_path == None
    get_property = channel != None and property_path != None

    if list_channels:
        res = ctx.run(["xfconf-query", "-l"], mutates=False)
        if res.rc != 0:
            fail("failed to list channels: " + res.stderr)
        lines = res.stdout.strip().splitlines()
        # Skip first line ("Channels:") and strip leading whitespace
        channels = [line.lstrip() for line in lines[1:] if line.lstrip()]
        return {"changed": False, "msg": "fetched channels", "data": {"channels": channels}}

    if list_properties:
        res = ctx.run(["xfconf-query", "-l", "-c", channel], mutates=False)
        if res.rc != 0:
            fail("failed to list properties for channel " + channel + ": " + res.stderr)
        properties = res.stdout.strip().splitlines()
        return {"changed": False, "msg": "fetched properties for channel " + channel, "data": {"properties": properties}}

    # get_property case
    res = ctx.run(["xfconf-query", "-c", channel, "-p", property_path], mutates=False)
    if res.rc != 0:
        fail("failed to read property " + property_path + " from channel " + channel + ": " + res.stderr)

    output = res.stdout.strip()
    is_array = "Value is an array with" in output

    if is_array:
        lines = output.splitlines()
        # Remove first two lines (the "Value is an array..." lines)
        array_values = [line.strip() for line in lines[2:] if line.strip()]
        return {
            "changed": False,
            "msg": "fetched property " + property_path + " from channel " + channel,
            "data": {
                "value": "",
                "value_array": array_values,
                "is_array": True
            }
        }

    return {
        "changed": False,
        "msg": "fetched property " + property_path + " from channel " + channel,
        "data": {
            "value": output,
            "is_array": False
        }
    }

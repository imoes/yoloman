def main(ctx, params):
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered DMI Sysinfo service",
            "data": {
                "discovery": [
                    {"item": "", "params": {}, "metrics": []}
                ]
            },
        }

    # Read the DMI sysinfo file (same source Checkmk agent would read)
    # Standard Linux paths for DMI info
    dmi_path = "/sys/devices/virtual/dmi/id/"
    if not ctx.file_exists(dmi_path):
        return {
            "changed": False,
            "msg": "DMI info not available",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    # Gather all DMI fields we need
    fields = {
        "Manufacturer": "sys_vendor",
        "Product Name": "product_name",
        "Version": "product_version",
        "Serial Number": "product_serial",
    }
    
    data = {}
    for key, filename in fields.items():
        filepath = dmi_path + filename
        if ctx.file_exists(filepath):
            content = ctx.file_read(filepath)
            if len(content) > 0:
                value = content.strip()
                if len(value) > 0:
                    data[key] = value

    # Checkmk-style output
    manufacturer = data.get("Manufacturer", "Unknown")
    product_name = data.get("Product Name", "Unknown")
    version = data.get("Version", "Unknown")
    serial = data.get("Serial Number", "Unknown")

    summary = "Manufacturer: %s, Product-Name: %s, Version: %s, S/N: %s" % (
        manufacturer, product_name, version, serial
    )

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": "OK",
            "metrics": {},
            "details": "",
        },
    }

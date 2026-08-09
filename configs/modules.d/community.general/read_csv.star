def main(ctx, params):
    path = params["path"]
    dialect = params.get("dialect", "excel")
    key = params.get("key")
    fieldnames = params.get("fieldnames")
    unique = params.get("unique", True)
    delimiter = params.get("delimiter")
    skipinitialspace = params.get("skipinitialspace")
    strict = params.get("strict")

    # Set defaults based on dialect
    if dialect == "excel":
        if delimiter == None:
            delimiter = ","
        if skipinitialspace == None:
            skipinitialspace = False
    elif dialect == "excel-tab":
        if delimiter == None:
            delimiter = "\t"
        if skipinitialspace == None:
            skipinitialspace = False
    elif dialect == "unix":
        if delimiter == None:
            delimiter = ","
        if skipinitialspace == None:
            skipinitialspace = False
    else:
        fail("Unsupported dialect: " + dialect)

    # Read file content (ctx.file_read fail()s on error)
    content = ctx.file_read(path)

    lines = content.split("\n")
    if len(lines) > 0 and lines[-1] == "":
        lines = lines[:-1]

    # Detect header and fieldnames
    header = []
    data_lines = []
    if fieldnames != None:
        header = fieldnames
        data_lines = lines
    elif len(lines) > 0:
        header = lines[0].split(delimiter)
        data_lines = lines[1:] if len(lines) > 1 else []

    # Validate key exists in header if provided
    if key != None and key not in header:
        fail("Key '%s' was not found in the CSV header fields: %s" % (key, ", ".join(header)))

    # Parse CSV data manually (simple handling, no quote escaping for core functionality)
    def parse_line(line, delimiter, skipinitialspace):
        if skipinitialspace:
            parts = line.split(delimiter)
            return [p.strip() for p in parts]
        else:
            return line.split(delimiter)

    result_dict = {}
    result_list = []

    if key == None:
        for line in data_lines:
            if line.strip() == "":
                continue
            row = parse_line(line, delimiter, skipinitialspace)
            if len(row) != len(header):
                fail("Row has %d fields, expected %d" % (len(row), len(header)))
            entry = {}
            for i, field in enumerate(header):
                entry[field] = row[i] if i < len(row) else ""
            result_list.append(entry)
    else:
        for line in data_lines:
            if line.strip() == "":
                continue
            row = parse_line(line, delimiter, skipinitialspace)
            if len(row) != len(header):
                fail("Row has %d fields, expected %d" % (len(row), len(header)))
            entry = {}
            for i, field in enumerate(header):
                entry[field] = row[i] if i < len(row) else ""
            key_value = entry.get(key, "")
            if unique and key_value in result_dict:
                fail("Key '%s' is not unique for value '%s'" % (key, key_value))
            result_dict[key_value] = entry

    return {"changed": False, "msg": "CSV read successfully", "data": {"dict": result_dict, "list": result_list}}

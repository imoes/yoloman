def main(ctx, params):
    alerta_url = params["alerta_url"]
    customer = params["customer"]
    match = params["match"]
    state = params.get("state", "present")
    api_key = params.get("api_key")
    api_username = params.get("api_username")
    api_password = params.get("api_password")

    # Build headers
    headers = {"Content-Type": "application/json"}
    if api_key != None:
        headers["Authorization"] = "Key " + api_key
    elif api_username != None and api_password != None:
        # basic auth header: "Basic " + base64(username:password)
        auth_str = api_username + ":" + api_password
        auth_bytes = []
        for i in range(len(auth_str)):
            auth_bytes.append(ord(auth_str[i]))
        # Simple base64 encoding without external library
        b64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        b64 = ""
        i = 0
        while i < len(auth_bytes):
            b1 = auth_bytes[i]
            b2 = 0
            b3 = 0
            if i + 1 < len(auth_bytes):
                b2 = auth_bytes[i + 1]
            if i + 2 < len(auth_bytes):
                b3 = auth_bytes[i + 2]
            combined = (b1 << 16) + (b2 << 8) + b3
            b64 += b64_chars[(combined >> 18) & 63]
            b64 += b64_chars[(combined >> 12) & 63]
            b64 += b64_chars[(combined >> 6) & 63]
            b64 += b64_chars[combined & 63]
            i += 3
        # Remove padding
        pad = len(auth_str) % 3
        if pad == 1:
            b64 = b64[:-2] + "=="
        elif pad == 2:
            b64 = b64[:-1] + "="
        headers["Authorization"] = "Basic " + b64
    else:
        fail("Either api_key or both api_username and api_password must be provided")

    # Construct base URL
    base_url = alerta_url.rstrip("/")
    customers_url = base_url + "/api/customers"
    customer_url = base_url + "/api/customer"

    # Get all customers (paginated)
    page = 1
    all_customers = []
    while True:
        url = customers_url + "?page=" + str(page) if page > 1 else customers_url
        res = ctx.run(["curl", "-s", "-S", "-X", "GET", "-H", "Content-Type: application/json", "-H", headers["Authorization"], url], mutates=False)
        if res.rc != 0:
            fail("Failed to fetch customers: " + res.stderr)
        data = ctx.from_json(res.stdout)
        customers = data.get("customers", [])
        all_customers.extend(customers)
        pages = data.get("pages", 1)
        if page >= pages:
            break
        page += 1

    # Find customer id
    customer_id = None
    for c in all_customers:
        if c.get("customer") == customer and c.get("match") == match:
            customer_id = c.get("id")
            break

    if state == "present":
        if customer_id != None:
            return {"changed": False, "msg": "Customer " + customer + " already exists", "response": {"customers": all_customers}}
        else:
            if ctx.check_mode:
                return {"changed": True, "msg": "would create customer " + customer}
            payload = ctx.to_json({"customer": customer, "match": match})
            res = ctx.run(["curl", "-s", "-S", "-X", "POST", "-H", "Content-Type: application/json", "-H", headers["Authorization"], "-d", payload, customer_url], mutates=True)
            if res.rc != 0:
                fail("Failed to create customer: " + res.stderr)
            new_customer = ctx.from_json(res.stdout)
            return {"changed": True, "msg": "Customer " + customer + " created", "response": new_customer}

    elif state == "absent":
        if customer_id == None:
            return {"changed": False, "msg": "Customer " + customer + " does not exist", "response": {"customers": all_customers}}
        else:
            if ctx.check_mode:
                return {"changed": True, "msg": "would delete customer " + customer + " with id " + customer_id}
            res = ctx.run(["curl", "-s", "-S", "-X", "DELETE", "-H", "Content-Type: application/json", "-H", headers["Authorization"], customer_url + "/" + customer_id], mutates=True)
            if res.rc != 0:
                fail("Failed to delete customer " + customer_id + ": " + res.stderr)
            return {"changed": True, "msg": "Customer " + customer + " with id " + customer_id + " deleted", "response": {"id": customer_id}}

    else:
        fail("Unsupported state: " + state)

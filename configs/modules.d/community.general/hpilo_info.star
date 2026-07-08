def main(ctx, params):
    host = params["host"]
    login = params.get("login", "Administrator")
    password = params.get("password", "admin")
    ssl_version_str = params.get("ssl_version", "TLSv1")

    # Map ssl_version string to Python's ssl.PROTOCOL_* constants using string
    ssl_map = {
        "SSLv3": "PROTOCOL_SSLv3",
        "SSLv23": "PROTOCOL_SSLv23",
        "TLSv1": "PROTOCOL_TLSv1",
        "TLSv1_1": "PROTOCOL_TLSv1_1",
        "TLSv1_2": "PROTOCOL_TLSv1_2"
    }
    if ssl_version_str not in ssl_map:
        fail("unsupported ssl_version: " + ssl_version_str + "; must be one of: " + str(sorted(ssl_map.keys())))

    # Check if hpilo Python module is available via shell command
    res = ctx.run(["python", "-c", "import hpilo; print('ok')"])
    if res.rc != 0:
        fail("python-hpilo module is required; run 'pip install hpilo'")

    # Build the full hpilo command as a Python script
    script = """
import sys
try:
    import hpilo
except ImportError:
    sys.exit(1)

host = '{host}'
login = '{login}'
password = '{password}'
ssl_version = getattr(hpilo.ssl, 'PROTOCOL_' + '{ssl_version}'.upper().replace('V', 'v'))

try:
    ilo = hpilo.Ilo(host, login=login, password=password, ssl_version=ssl_version)
    host_data = ilo.get_host_data()
    power_state = ilo.get_host_power_status()
    health = ilo.get_embedded_health()
    print('OK')
    print('HOST_DATA_START')
    for entry in host_data:
        print(entry)
    print('HOST_DATA_END')
    print('POWER_STATE:' + str(power_state))
    print('HEALTH_START')
    print(health)
    print('HEALTH_END')
except Exception as e:
    sys.exit(2)
""".format(host=host, login=login, password=password, ssl_version=ssl_version_str)

    res = ctx.run(["python", "-c", script])
    if res.rc == 2:
        err = res.stderr.strip() if res.stderr.strip() != "" else res.stdout.strip()
        fail("hpilo communication error: " + err)
    elif res.rc != 0:
        fail("failed to run hpilo: rc=" + str(res.rc) + ", stderr=" + res.stderr.strip())

    # Parse output — Starlark cannot evaluate Python objects, so this module cannot be fully implemented
    fail("hpilo_info cannot be translated to Starlark because it depends on the hpilo Python module, which cannot be imported or executed in the Starlark runtime. Use the original Ansible Python module instead.")

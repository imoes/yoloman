def check_single(ctx, host, params):
    port = params.get('port') or 80
    tls = params.get('tls_configuration') or 'no_tls'
    uri = params.get('uri') or '/'
    timeout_s = params.get('timeout_s') or 10
    expect_regex = params.get('expect_regex')
    query = params.get('query')
    form_name = params.get('form_name')
    use_tls = tls == 'tls_standard' or tls == 'tls_no_cert_valid'
    verify_tls = tls != 'tls_no_cert_valid'
    scheme = 'http'
    if use_tls:
        scheme = 'https'
    url = '%s://%s:%d%s' % (scheme, host, int(port), uri)
    get_probe = ctx.probe('http', {
        'url': url,
        'method': 'GET',
        'timeout_s': timeout_s,
        'verify_tls': verify_tls,
        'follow_redirects': True,
    })
    if get_probe.get('error'):
        return [False, 'connect: ' + get_probe['error']]
    status = int(get_probe.get('status_code') or 0)
    if status < 200 or status >= 300:
        return [False, 'GET HTTP %d' % status]
    page_body = get_probe.get('body') or ''
    if '<form' not in page_body.lower():
        return [False, 'no HTML form on page']
    if form_name != None and form_name != '':
        dq = chr(34)
        sq = chr(39)
        if ('name=' + dq + form_name + dq) not in page_body and ('name=' + sq + form_name + sq) not in page_body:
            return [False, 'form not found: ' + form_name]
    post_probe = ctx.probe('http', {
        'url': url,
        'method': 'POST',
        'body': query or '',
        'headers': {'Content-Type': 'application/x-www-form-urlencoded'},
        'timeout_s': timeout_s,
        'verify_tls': verify_tls,
        'follow_redirects': True,
    })
    if post_probe.get('error'):
        return [False, 'POST: ' + post_probe['error']]
    post_status = int(post_probe.get('status_code') or 0)
    if post_status < 200 or post_status >= 400:
        return [False, 'POST HTTP %d' % post_status]
    if expect_regex != None and expect_regex != '':
        resp_body = post_probe.get('body') or ''
        r = ctx.run(['python3', '-c',
            'import re,sys; sys.exit(0 if re.search(sys.argv[1], sys.argv[2]) else 1)',
            expect_regex, resp_body])
        if r.rc != 0:
            return [False, 'regex not matched: /%s/' % expect_regex]
    resp_ms = float(post_probe.get('response_ms') or 0)
    return [True, '%d ms' % int(resp_ms)]

def main(ctx, params):
    if params.get('_discover'):
        return {'changed': False, 'msg': 'active check (assign with parameters)', 'data': {'discovery': []}}
    hosts = params.get('hosts') or []
    single_host = params.get('host')
    if len(hosts) == 0 and single_host != None:
        hosts = [single_host]
    if len(hosts) == 0:
        return {'changed': False, 'msg': 'UNKNOWN', 'data': {'state': 'UNKNOWN', 'metrics': {}, 'details': 'no host configured'}}
    results = []
    for h in hosts:
        r = check_single(ctx, h, params)
        results.append([h, r[0], r[1]])
    succeeded = 0
    failed_parts = []
    for r in results:
        if r[1]:
            succeeded += 1
        else:
            failed_parts.append(r[0] + ': ' + r[2])
    total = len(hosts)
    state = 'OK'
    if total > 1:
        warn = params.get('num_succeeded_warn')
        crit = params.get('num_succeeded_crit')
        if crit != None and succeeded <= int(crit):
            state = 'CRIT'
        elif warn != None and succeeded <= int(warn):
            state = 'WARN'
        elif succeeded < total:
            state = 'WARN'
    else:
        if succeeded == 0:
            state = 'CRIT'
    if len(failed_parts) > 0:
        details = '%d/%d hosts OK | %s' % (succeeded, total, '; '.join(failed_parts))
    else:
        details = '%d/%d hosts OK' % (succeeded, total)
    return {'changed': False, 'msg': state, 'data': {'state': state, 'metrics': {'succeeded': succeeded, 'total': total}, 'details': details}}
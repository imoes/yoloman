def main(ctx, params):
    server = params.get("server", "localhost")
    port = int(params.get("port", 6667))
    nick = params.get("nick", "ansible")
    nick_to = params.get("nick_to")
    msg = params["msg"]
    color = params.get("color", "none")
    channel = params.get("channel")
    topic = params.get("topic")
    key = params.get("key")
    passwd = params.get("passwd")
    timeout = int(params.get("timeout", 30))
    use_tls = params.get("use_tls", False)
    part = params.get("part", True)
    style = params.get("style", "none")
    validate_certs = params.get("validate_certs", False)

    has_channel = channel != None and len(channel) > 0
    has_nick_to = nick_to != None and len(nick_to) > 0
    if not has_channel and not has_nick_to:
        fail("one of 'channel' or 'nick_to' is required")
    if topic != None and not has_channel:
        fail("when topic is specified, a channel is required")

    if ctx.check_mode:
        return {
            "changed": True,
            "msg": "would send message to IRC (server=%s, port=%d, channel=%s, nick_to=%s)" % (
                server, port, channel or [], nick_to or []
            )
        }

    script = """
import sys, socket, ssl, re, time

server = sys.argv[1]
port = int(sys.argv[2])
nick = sys.argv[3]
channel = sys.argv[4] if sys.argv[4] != 'None' else None
nick_to = sys.argv[5].split(',') if sys.argv[5] != 'None' else []
msg = sys.argv[6]
topic = sys.argv[7] if sys.argv[7] != 'None' else None
key = sys.argv[8] if sys.argv[8] != 'None' else None
passwd = sys.argv[9] if sys.argv[9] != 'None' else None
timeout = int(sys.argv[10])
use_tls = sys.argv[11] == 'True'
validate_certs = sys.argv[12] == 'True'
part = sys.argv[13] == 'True'
style = sys.argv[14] if sys.argv[14] != 'None' else None
color = sys.argv[15] if sys.argv[15] != 'None' else 'none'

colornumbers = {
    'white': "00", 'black': "01", 'blue': "02", 'green': "03",
    'red': "04", 'brown': "05", 'purple': "06", 'orange': "07",
    'yellow': "08", 'light_green': "09", 'teal': "10",
    'light_cyan': "11", 'light_blue': "12", 'pink': "13",
    'gray': "14", 'light_gray': "15"
}

stylechoices = {'bold': "\\x02", 'underline': "\\x1f", 'reverse': "\\x16", 'italic': "\\x1d"}

styletext = stylechoices.get(style, "")

colornumber = colornumbers.get(color, None)
colortext = "\\x03" + colornumber if colornumber else ""

message = styletext + colortext + msg

irc = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
if use_tls:
    if validate_certs:
        context = ssl.create_default_context()
    else:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
    irc = context.wrap_socket(irc)
irc.connect((server, port))

if passwd:
    irc.send(('PASS %s\\r\\n' % passwd).encode())
irc.send(('NICK %s\\r\\n' % nick).encode())
irc.send(('USER %s %s %s :ansible IRC\\r\\n' % (nick, nick, nick)).encode())

motd = ''
start = time.time()
while True:
    data = irc.recv(1024)
    if not data:
        break
    motd += data.decode('utf-8', errors='replace')
    match = re.search(r'^:\\S+ 00[1-4] (?P<nick>\\S+) :', motd, re.M)
    if match:
        nick = match.group('nick')
        break
    if time.time() - start > timeout:
        raise Exception('Timeout waiting for IRC server welcome')
    time.sleep(0.5)

if channel:
    if key:
        irc.send(('JOIN %s %s\\r\\n' % (channel, key)).encode())
    else:
        irc.send(('JOIN %s\\r\\n' % channel).encode())

    join = ''
    start = time.time()
    while True:
        data = irc.recv(1024)
        if not data:
            break
        join += data.decode('utf-8', errors='replace')
        if re.search(r'^:\\S+ 366 %s %s :' % (nick, channel), join, re.M):
            break
        if time.time() - start > timeout:
            raise Exception('Timeout waiting for IRC JOIN response')
        time.sleep(0.5)

    if topic:
        irc.send(('TOPIC %s :%s\\r\\n' % (channel, topic)).encode())
        time.sleep(1)

if nick_to:
    for target_nick in nick_to:
        irc.send(('PRIVMSG %s :%s\\r\\n' % (target_nick.strip(), message)).encode())
if channel:
    irc.send(('PRIVMSG %s :%s\\r\\n' % (channel, message)).encode())
time.sleep(1)
if part:
    if channel:
        irc.send(('PART %s\\r\\n' % channel).encode())
    irc.send(b'QUIT\\r\\n')
    time.sleep(1)
irc.close()
""" % (server, port, nick, channel or 'None', ','.join(nick_to) if nick_to else 'None',
         msg.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n'), topic or 'None',
         key or 'None', passwd or 'None', timeout, use_tls, validate_certs, part, style or 'None',
         color or 'none')

    cmd = ["python3", "-c", script]
    res = ctx.run(cmd, mutates=True)
    if res.skipped:
        return {"changed": True, "msg": "would send message to IRC"}
    if res.rc != 0:
        fail("failed to send to IRC: " + res.stderr)
    return {"changed": True, "msg": "message sent to IRC"}

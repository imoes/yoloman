using System.Net;
using System.Net.Sockets;

namespace AgenticMcp.Agent.Core;

/// <summary>
/// An <see cref="HttpClient"/> for fetching things inside the fleet, with the one proxy rule .NET gets wrong.
///
/// <para><b>Measured on bossman-wintest, 2026-09-02.</b> The host carries the corporate proxy in its
/// environment (<c>HTTP_PROXY=http://proxy.ippen.media:80</c>) and the matching bypass list
/// (<c>NO_PROXY=localhost,127.0.0.1,.ippen.media,10.32.0.0/16</c>). Fetching an installer from a fleet-internal
/// address — <c>http://10.32.28.130:8099/…</c>, inside that very CIDR — went to the proxy anyway and came back
/// <b>503 Service Unavailable</b>, so <c>package</c> could not install anything from an internal repository.
/// <c>curl.exe</c> on the same host, same environment, same URL: <b>200</b>.</para>
///
/// <para><b>Why they differ:</b> curl has understood CIDR entries in <c>NO_PROXY</c> since 7.86;
/// <see cref="WebRequest.DefaultWebProxy"/> and <c>HttpClient.DefaultProxy</c> match bypass entries as host
/// name suffixes only. A CIDR there is not "ignored as unsupported" — it is compared as a literal string
/// against the host name, never matches, and the request is proxied. The bypass list was correct; the client
/// could not read it.</para>
///
/// <para>So this honours <c>NO_PROXY</c> FAITHFULLY and adds no policy of its own: suffix entries as before,
/// plus CIDR entries applied to IP-literal hosts, plus loopback. It deliberately does NOT bypass every private
/// range on its own initiative — an operator who wants a proxy for an internal address is entitled to one, and
/// inventing a rule here would be a second, invisible bypass list.</para>
///
/// <para><b>In Core, not in .Windows</b>, although the defect was found there: parsing NO_PROXY is plain .NET
/// with nothing Windows-specific in it, and .Windows targets <c>net10.0-windows</c> which the test project
/// (<c>net10.0</c>) cannot reference. Code that cannot be referenced by the tests is code that will not be
/// tested — so the rule lives where it can be, and the platform-specific module simply calls it.</para>
/// </summary>
public static class ProxyPolicy
{
    /// <summary>The parsed bypass list, cached against the RAW variable it came from.
    ///
    /// <para>Not a <c>static readonly</c> parsed once at type load, which is what this was first written as:
    /// the value would then be frozen at whatever the environment held when the first URL happened to be
    /// fetched, and a test that sets NO_PROXY afterwards would exercise the previous case's list instead of
    /// its own. Keying the cache on the raw string keeps the parse cheap AND makes the rule observable —
    /// which is the difference between a policy with tests and a policy with hopeful comments.</para></summary>
    private static string? _cachedRaw;
    private static (string[] Suffixes, (IPAddress Network, int Bits)[] Cidrs) _cached = ([], []);

    private static (string[] Suffixes, (IPAddress Network, int Bits)[] Cidrs) Bypass
    {
        get
        {
            var raw = Environment.GetEnvironmentVariable("NO_PROXY")
                      ?? Environment.GetEnvironmentVariable("no_proxy") ?? "";
            if (raw != _cachedRaw)
            {
                _cached = ParseNoProxy(raw);
                _cachedRaw = raw;
            }

            return _cached;
        }
    }

    /// <summary>A client whose proxy decision reads NO_PROXY the way the operator wrote it.</summary>
    public static HttpClient CreateFleetHttpClient(TimeSpan timeout) =>
        new(new HttpClientHandler { Proxy = new NoProxyAwareProxy(), UseProxy = true }) { Timeout = timeout };

    /// <summary>True when NO_PROXY says this host must be reached directly.</summary>
    public static bool IsBypassed(string host)
    {
        if (string.IsNullOrWhiteSpace(host)) return false;
        if (IPAddress.TryParse(host, out var ip))
        {
            if (IPAddress.IsLoopback(ip)) return true;
            foreach (var (network, bits) in Bypass.Cidrs)
                if (Contains(network, bits, ip)) return true;
        }
        else if (host.Equals("localhost", StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        foreach (var suffix in Bypass.Suffixes)
        {
            // ".ippen.media" and "*.ippen.media" both mean "any host under it", and a bare "example.com"
            // means the host itself — the three spellings an operator actually writes.
            var s = suffix.TrimStart('*');
            if (s.StartsWith('.')
                ? host.EndsWith(s, StringComparison.OrdinalIgnoreCase)
                  || host.Equals(s[1..], StringComparison.OrdinalIgnoreCase)
                : host.Equals(s, StringComparison.OrdinalIgnoreCase))
                return true;
        }

        return false;
    }

    private static (string[], (IPAddress, int)[]) ParseNoProxy(string raw)
    {
        var suffixes = new List<string>();
        var cidrs = new List<(IPAddress, int)>();
        foreach (var entry in raw.Split([',', ';'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var slash = entry.IndexOf('/');
            if (slash > 0 && IPAddress.TryParse(entry[..slash], out var net)
                && int.TryParse(entry[(slash + 1)..], out var bits))
                cidrs.Add((net, bits));
            else
                suffixes.Add(entry);
        }

        return (suffixes.ToArray(), cidrs.ToArray());
    }

    private static bool Contains(IPAddress network, int bits, IPAddress candidate)
    {
        if (network.AddressFamily != candidate.AddressFamily) return false;
        if (network.AddressFamily != AddressFamily.InterNetwork) return false;   // IPv4 only, as measured
        var n = network.GetAddressBytes();
        var c = candidate.GetAddressBytes();
        for (var i = 0; i < 4 && bits > 0; i++, bits -= 8)
        {
            var mask = bits >= 8 ? (byte)0xFF : (byte)(0xFF << (8 - bits));
            if ((n[i] & mask) != (c[i] & mask)) return false;
        }

        return true;
    }

    /// <summary>The environment's proxy, with NO_PROXY evaluated by <see cref="IsBypassed"/>.</summary>
    private sealed class NoProxyAwareProxy : IWebProxy
    {
        private readonly IWebProxy _inner = HttpClient.DefaultProxy;

        public ICredentials? Credentials { get => _inner.Credentials; set => _inner.Credentials = value; }

        // BOTH calls are qualified. Unqualified, `IsBypassed(...)` binds to this class's own IWebProxy
        // member (which takes a Uri) rather than to the outer static (which takes a host string), and the
        // compiler says only "cannot convert string to Uri" — a name collision reading as a type error.
        public Uri? GetProxy(Uri destination) =>
            ProxyPolicy.IsBypassed(destination.Host) ? null : _inner.GetProxy(destination);

        public bool IsBypassed(Uri host) => ProxyPolicy.IsBypassed(host.Host) || _inner.IsBypassed(host);
    }
}

using System.Globalization;

namespace AgenticMcp.Agent.Core;

/// <summary>
/// The endpoint bodies, as PURE functions of the agent's state.
///
/// <para>They are separated from the HTTP wiring on purpose: this is the layer that has to agree with
/// Bossman byte for byte, so it is the layer the tests exercise directly. Routing, TLS and bearer checking
/// are ten lines in the host process and are proven by running it, not by unit tests that would mostly
/// assert that ASP.NET Core routes.</para>
/// </summary>
public static class Endpoints
{
    /// <summary>
    /// Parses the <c>from</c>/<c>to</c> query bounds exactly as the Go agent's <c>parseTimeBound</c> does:
    /// an RFC3339 timestamp, or a relative duration ("1h", "30m", "24h") meaning "that long before now".
    /// Empty means the default.
    ///
    /// <para>The relative form is why this is shared code rather than two parsers: Bossman's poller sends
    /// <c>?from=</c> with a cursor timestamp, and a hand-driven <c>curl</c> sends "1h". An agent that
    /// understood only one of them would work in exactly one of the two situations it is used in.</para>
    /// </summary>
    public static bool TryParseTimeBound(string? raw, DateTimeOffset now, TimeSpan fallback,
        out DateTimeOffset bound, out string? error)
    {
        error = null;
        if (string.IsNullOrWhiteSpace(raw))
        {
            bound = now + fallback;
            return true;
        }

        if (DateTimeOffset.TryParse(raw, CultureInfo.InvariantCulture,
                DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var absolute))
        {
            bound = absolute;
            return true;
        }

        if (TryParseDuration(raw, out var span))
        {
            bound = now - span;
            return true;
        }

        bound = default;
        error = $"not an RFC3339 timestamp or a duration like \"1h\": {raw}";
        return false;
    }

    private static bool TryParseDuration(string raw, out TimeSpan span)
    {
        span = default;
        var text = raw.Trim();
        if (text.Length < 2)
        {
            return false;
        }

        var unit = text[^1];
        if (!double.TryParse(text[..^1], NumberStyles.Float, CultureInfo.InvariantCulture, out var n))
        {
            return false;
        }

        span = unit switch
        {
            's' => TimeSpan.FromSeconds(n),
            'm' => TimeSpan.FromMinutes(n),
            'h' => TimeSpan.FromHours(n),
            'd' => TimeSpan.FromDays(n),
            _ => TimeSpan.Zero,
        };
        return span != TimeSpan.Zero;
    }

    /// <summary>Label filters arrive as <c>?label.iface=eth0</c>, the same spelling the Go agent reads.</summary>
    public static IReadOnlyDictionary<string, string> LabelFilter(IEnumerable<KeyValuePair<string, string?>> query)
    {
        var labels = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var (key, value) in query)
        {
            if (key.StartsWith("label.", StringComparison.Ordinal) && value is not null)
            {
                labels[key["label.".Length..]] = value;
            }
        }

        return labels;
    }
}

/// <summary>
/// What this host is, for GET /api/v1/hosts/overview.
///
/// <para>One host and no satellites: a Windows agent is a leaf. Proxy mode (an agent relaying others) is a
/// Go-agent feature that this implementation does not claim, and the reply says so by reporting itself as
/// the only host rather than by omitting the field.</para>
/// </summary>
public sealed record HostOverview(string Hostname, string Platform, string AgentVersion, DateTimeOffset At);

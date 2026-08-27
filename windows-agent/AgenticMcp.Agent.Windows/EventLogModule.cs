using System.Text.Json;
using AgenticMcp.Agent.Core;

namespace AgenticMcp.Agent.Windows;

/// <summary>
/// <c>windows_eventlog</c> — read the Windows event log, filtered ON THE HOST.
///
/// <para>READ-ONLY, and that is load-bearing: <c>Writes = false</c> means it is offered even when the write
/// gate is closed. Being able to ask a host what went wrong must never require permission to change it.</para>
///
/// <para><b>The filter runs in the query, not here.</b> Measured on bossman-wintest: 406 channels, 83 of them
/// with records, 38 544 records in total — and `Get-WinEvent -FilterHashtable` with two logs, three levels
/// and a seven-day window answered <b>50 events in 0.04 s</b>. Shipping a channel and filtering afterwards
/// would move megabytes to save nothing; the fullest channel on this host is a diagnostic one with 22 512
/// records that nobody asked for.</para>
///
/// <para><b>THE LEVEL VOCABULARY IS OURS, THE NUMBERS ARE WINDOWS'.</b> Two measurements forced this:
/// <c>LevelDisplayName</c> is LOCALISED — this host says "Fehler", "Warnung", "Informationen" — so a
/// dashboard filtering on "Error" would find nothing here; and it is sometimes EMPTY even for a known level
/// (4 events at level 4 with no name at all). So the API takes and returns canonical English names, filters
/// on the numeric level, and carries all three: <c>level</c> (the number, authoritative), <c>level_name</c>
/// (ours, stable across languages) and <c>level_display</c> (what this host calls it, possibly empty).</para>
///
/// <para>Level 0 is named too. It is <c>LogAlways</c> in the schema and providers use it for whatever they
/// like — on this host its 8 events are informational — so it is a selectable level rather than something
/// quietly excluded by a 1,2,3 filter.</para>
/// </summary>
public sealed class EventLogModule : IModule
{
    public string Name => "windows_eventlog";

    /// <summary>Windows' numeric levels, under names that do not change with the host's language.</summary>
    private static readonly Dictionary<string, int> Levels = new(StringComparer.OrdinalIgnoreCase)
    {
        ["log_always"] = 0,
        ["critical"] = 1,
        ["error"] = 2,
        ["warning"] = 3,
        ["information"] = 4,
        ["verbose"] = 5,
    };

    /// <summary>What an operator means by "show me the problems". Deliberately includes ERROR.</summary>
    private const string DefaultLevels = "critical,error,warning";

    public string Description =>
        "Read this Windows host's event log, filtered on the host. `logs` is a comma-separated list of "
        + "channels (default \"System,Application\"; use windows_eventlog_channels to see which ones have "
        + "records). `levels` is a comma-separated list of critical, error, warning, information, verbose, "
        + "log_always — default \"critical,error,warning\", which is what \"show me the problems\" means and "
        + "deliberately includes ERROR, the commonest of the three. `since` accepts a duration (\"24h\", "
        + "\"7d\", \"30m\") or an ISO timestamp; `max_events` caps the reply (default 200); `provider`, "
        + "`event_ids` and `contains` narrow further. Every event carries `level` (Windows' number, "
        + "authoritative), `level_name` (ours, stable across languages) and `level_display` (what this host "
        + "calls it — LOCALISED, and sometimes empty). Read-only: available even when the write gate is "
        + "closed, because asking a host what went wrong must not require permission to change it.";

    public IReadOnlyDictionary<string, object> InputSchema => new Dictionary<string, object>
    {
        ["type"] = "object",
        ["properties"] = new Dictionary<string, object>
        {
            ["logs"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["default"] = "System,Application",
                ["description"] = "Channels to read, comma-separated. 406 exist on a Server 2022; 83 have "
                                  + "records. windows_eventlog_channels lists them with counts.",
            },
            ["levels"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["enum"] = Levels.Keys.ToArray(),
                ["default"] = DefaultLevels,
                ["description"] = "Comma-separated level names. Filtering happens by NUMBER on the host, "
                                  + "because the display names are localised.",
            },
            ["since"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["default"] = "24h",
                ["description"] = "A duration (24h, 7d, 30m) or an ISO timestamp.",
            },
            ["max_events"] = new Dictionary<string, object>
            {
                ["type"] = "number",
                ["default"] = 200,
                ["description"] = "Cap on returned events. The reply says whether it was reached, so a "
                                  + "truncated answer never looks complete.",
            },
            ["provider"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["description"] = "Only events from this provider (e.g. \"SNMP\", \"Service Control Manager\").",
            },
            ["event_ids"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["description"] = "Comma-separated event IDs.",
            },
            ["contains"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["description"] = "Only events whose message contains this text (matched on the host).",
            },
        },
    };

    public bool Writes => false;

    public async Task<ModuleResult> RunAsync(IReadOnlyDictionary<string, object?> parameters, bool dryRun,
        CancellationToken ct)
    {
        var logs = Split(Str(parameters, "logs") ?? "System,Application");
        if (logs.Length == 0)
        {
            throw new ArgumentException("logs: name at least one channel");
        }

        var levelNames = Split(Str(parameters, "levels") ?? DefaultLevels);
        var unknown = levelNames.Where(l => !Levels.ContainsKey(l)).ToList();
        if (unknown.Count > 0)
        {
            throw new ArgumentException(
                $"levels: {string.Join(", ", unknown)} — must be from {string.Join(", ", Levels.Keys)}. "
                + "These are canonical names on purpose: this host's own level names are localised "
                + "(\"Fehler\", \"Warnung\"), so they cannot be the vocabulary.");
        }

        var levels = levelNames.Select(l => Levels[l]).Distinct().OrderBy(n => n).ToArray();
        var since = ParseSince(Str(parameters, "since") ?? "24h");
        var max = (int)(Num(parameters, "max_events") ?? 200);
        var provider = Str(parameters, "provider");
        var ids = Split(Str(parameters, "event_ids") ?? "")
            .Select(s => int.TryParse(s, out var n) ? n : -1).Where(n => n >= 0).ToArray();
        var contains = Str(parameters, "contains");

        // FILTERED IN THE HASHTABLE, which is what makes this cheap: Windows evaluates it inside the log
        // service instead of handing us a channel to sift. -ErrorAction SilentlyContinue because a named
        // channel that holds no matching event raises rather than returning empty, and "no matching events"
        // is an answer, not a failure.
        var filter = new List<string>
        {
            $"LogName={PsArray(logs)}",
            $"Level={string.Join(",", levels)}",
            $"StartTime=[datetime]::Parse('{since:O}')",
        };
        if (!string.IsNullOrWhiteSpace(provider))
        {
            filter.Add($"ProviderName='{provider.Replace("'", "''")}'");
        }

        if (ids.Length > 0)
        {
            filter.Add($"Id={string.Join(",", ids)}");
        }

        var setup = "$ev = Get-WinEvent -FilterHashtable @{ " + string.Join("; ", filter) + " } "
                    + $"-MaxEvents {Math.Max(max, 1)} -ErrorAction SilentlyContinue";
        if (!string.IsNullOrWhiteSpace(contains))
        {
            setup += $"; $ev = $ev | Where-Object {{ $_.Message -like '*{contains.Replace("'", "''")}*' }}";
        }

        // TimeCreated as a real ISO string: ConvertTo-Json renders a DateTime as "/Date(1787827192248)/",
        // a Microsoft-specific format every consumer would have to learn. Message collapsed to one line
        // because an event log's whitespace is not information.
        var expression = "@($ev | Select-Object "
                         + "@{n='time';e={$_.TimeCreated.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')}},"
                         + "@{n='id';e={[int]$_.Id}},"
                         + "@{n='level';e={[int]$_.Level}},"
                         + "@{n='level_display';e={[string]$_.LevelDisplayName}},"
                         + "@{n='log';e={[string]$_.LogName}},"
                         + "@{n='provider';e={[string]$_.ProviderName}},"
                         + "@{n='machine';e={[string]$_.MachineName}},"
                         + "@{n='message';e={($_.Message -replace '\\s+',' ').Trim()}})";

        var answer = await WindowsPowerShellBridge.RunJson(setup, expression, TimeSpan.FromMinutes(5), ct);
        var events = new List<Dictionary<string, object?>>();
        foreach (var e in answer.Items)
        {
            var level = e.TryGetProperty("level", out var l) && l.TryGetInt32(out var n) ? n : -1;
            events.Add(new Dictionary<string, object?>
            {
                ["time"] = Text(e, "time"),
                ["id"] = e.TryGetProperty("id", out var i) && i.TryGetInt32(out var idv) ? idv : 0,
                ["level"] = level,
                // OURS, stable across languages — the field a dashboard filter and an AI should read.
                ["level_name"] = Levels.FirstOrDefault(kv => kv.Value == level).Key ?? "unknown",
                // WHAT THIS HOST CALLS IT: localised, and measurably sometimes empty.
                ["level_display"] = Text(e, "level_display"),
                ["log"] = Text(e, "log"),
                ["provider"] = Text(e, "provider"),
                ["machine"] = Text(e, "machine"),
                ["message"] = Text(e, "message"),
            });
        }

        var byLevel = events.GroupBy(e => (string)e["level_name"]!)
            .ToDictionary(g => g.Key, g => g.Count());
        var byProvider = events.GroupBy(e => (string?)e["provider"] ?? "")
            .OrderByDescending(g => g.Count()).Take(10)
            .ToDictionary(g => g.Key, g => g.Count());

        return new ModuleResult(false,
            $"{events.Count} event(s) from {string.Join(", ", logs)} at level "
            + string.Join("/", levelNames) + $" since {since:yyyy-MM-dd HH:mm}Z"
            + (events.Count >= max ? $" — CAPPED at max_events={max}, there may be more" : ""),
            new Dictionary<string, object?>
            {
                ["events"] = events,
                ["count"] = events.Count,
                // TRUNCATION IS SAID OUT LOUD. A capped answer that looks complete is the one failure mode a
                // log reader must not have — an operator concluding "only 200 errors" from a cap is worse
                // than being told the number is a floor.
                ["capped"] = events.Count >= max,
                ["max_events"] = max,
                ["since"] = since.ToString("yyyy-MM-ddTHH:mm:ssZ"),
                ["logs"] = logs,
                ["levels"] = levelNames,
                // Two summaries, because both questions get asked: which severities, and who is producing
                // them. Counted here rather than by the caller, so an AI reading this does not have to.
                ["by_level"] = byLevel,
                ["by_provider"] = byProvider,
                ["shell"] = WindowsPowerShellBridge.ShellName,
            },
            new Dictionary<string, int> { ["attempts"] = 1, ["produced"] = events.Count });
    }

    /// <summary>A duration ("24h", "7d") or an ISO timestamp, as an absolute UTC instant.</summary>
    internal static DateTimeOffset ParseSince(string raw)
    {
        var text = raw.Trim();
        if (DateTimeOffset.TryParse(text, System.Globalization.CultureInfo.InvariantCulture,
                System.Globalization.DateTimeStyles.AdjustToUniversal
                | System.Globalization.DateTimeStyles.AssumeUniversal, out var absolute))
        {
            return absolute;
        }

        if (text.Length >= 2
            && double.TryParse(text[..^1], System.Globalization.NumberStyles.Float,
                System.Globalization.CultureInfo.InvariantCulture, out var value))
        {
            var span = char.ToLowerInvariant(text[^1]) switch
            {
                's' => TimeSpan.FromSeconds(value),
                'm' => TimeSpan.FromMinutes(value),
                'h' => TimeSpan.FromHours(value),
                'd' => TimeSpan.FromDays(value),
                'w' => TimeSpan.FromDays(value * 7),
                _ => TimeSpan.Zero,
            };
            if (span > TimeSpan.Zero)
            {
                return DateTimeOffset.UtcNow - span;
            }
        }

        throw new ArgumentException(
            $"since: \"{raw}\" is neither a duration (24h, 7d, 30m) nor an ISO timestamp");
    }

    private static string PsArray(IEnumerable<string> values) =>
        string.Join(",", values.Select(v => $"'{v.Replace("'", "''")}'"));

    private static string[] Split(string raw) =>
        raw.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

    private static string? Text(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    private static string? Str(IReadOnlyDictionary<string, object?> p, string key) =>
        p.TryGetValue(key, out var v) ? v?.ToString() : null;

    private static double? Num(IReadOnlyDictionary<string, object?> p, string key) =>
        p.TryGetValue(key, out var v) && v is not null
        && double.TryParse(v.ToString(), System.Globalization.NumberStyles.Float,
            System.Globalization.CultureInfo.InvariantCulture, out var parsed)
            ? parsed
            : null;
}

/// <summary>
/// <c>windows_eventlog_channels</c> — which channels exist, and which of them hold anything.
///
/// <para>A separate module because it answers a different question, and one module answering two would make
/// its reply's shape depend on a parameter. Measured on Server 2022: <b>406 channels, 83 with records</b>, so
/// "pick a category" is not a list a person can be handed unfiltered — the default hides the 323 empty ones
/// and sorts by what is actually in them.</para>
/// </summary>
public sealed class EventLogChannelsModule : IModule
{
    public string Name => "windows_eventlog_channels";

    public string Description =>
        "List this host's event log channels with their record counts, size and retention — the categories a "
        + "human or an AI picks from before reading anything. 406 exist on a Server 2022 and 83 have records, "
        + "so `only_with_records` defaults to true and the list is sorted by record count; pass false for the "
        + "complete inventory. Read-only.";

    public IReadOnlyDictionary<string, object> InputSchema => new Dictionary<string, object>
    {
        ["type"] = "object",
        ["properties"] = new Dictionary<string, object>
        {
            ["only_with_records"] = new Dictionary<string, object>
            {
                ["type"] = "boolean",
                ["default"] = true,
                ["description"] = "Hide the channels that hold nothing (323 of 406 on a fresh Server 2022).",
            },
            ["name_like"] = new Dictionary<string, object>
            {
                ["type"] = "string",
                ["description"] = "Only channels whose name matches this wildcard, e.g. \"*PowerShell*\".",
            },
        },
    };

    public bool Writes => false;

    public async Task<ModuleResult> RunAsync(IReadOnlyDictionary<string, object?> parameters, bool dryRun,
        CancellationToken ct)
    {
        var onlyWithRecords = !parameters.TryGetValue("only_with_records", out var raw)
                              || raw is null
                              || raw is true
                              || (raw is string s && !string.Equals(s, "false", StringComparison.OrdinalIgnoreCase));
        var pattern = parameters.TryGetValue("name_like", out var p) ? p?.ToString() : null;

        var setup = "$logs = Get-WinEvent -ListLog "
                    + (string.IsNullOrWhiteSpace(pattern) ? "*" : $"'{pattern.Replace("'", "''")}'")
                    + " -ErrorAction SilentlyContinue";
        if (onlyWithRecords)
        {
            setup += "; $logs = $logs | Where-Object RecordCount -gt 0";
        }

        setup += "; $logs = $logs | Sort-Object RecordCount -Descending";

        var expression = "@($logs | Select-Object "
                         + "@{n='name';e={[string]$_.LogName}},"
                         + "@{n='records';e={[int64]$_.RecordCount}},"
                         + "@{n='size_bytes';e={[int64]$_.FileSize}},"
                         + "@{n='max_size_bytes';e={[int64]$_.MaximumSizeInBytes}},"
                         + "@{n='enabled';e={[bool]$_.IsEnabled}},"
                         + "@{n='retention';e={[string]$_.LogMode}})";

        var answer = await WindowsPowerShellBridge.RunJson(setup, expression, TimeSpan.FromMinutes(3), ct);
        var channels = answer.Items.Select(e => new Dictionary<string, object?>
        {
            ["name"] = e.TryGetProperty("name", out var n) ? n.GetString() : null,
            ["records"] = e.TryGetProperty("records", out var r) && r.TryGetInt64(out var rv) ? rv : 0,
            ["size_bytes"] = e.TryGetProperty("size_bytes", out var sz) && sz.TryGetInt64(out var szv) ? szv : 0,
            ["max_size_bytes"] = e.TryGetProperty("max_size_bytes", out var m) && m.TryGetInt64(out var mv) ? mv : 0,
            ["enabled"] = e.TryGetProperty("enabled", out var en) && en.ValueKind == JsonValueKind.True,
            // LogMode: Circular | AutoBackup | Retain — what happens when the channel fills, which decides
            // whether "the event is not there" means "never happened" or "already rotated away".
            ["retention"] = e.TryGetProperty("retention", out var rt) ? rt.GetString() : null,
        }).ToList();

        return new ModuleResult(false,
            $"{channels.Count} channel(s)" + (onlyWithRecords ? " with records" : " (complete inventory)"),
            new Dictionary<string, object?>
            {
                ["channels"] = channels,
                ["count"] = channels.Count,
                ["only_with_records"] = onlyWithRecords,
                ["total_records"] = channels.Sum(c => (long)(c["records"] ?? 0L)),
                ["shell"] = WindowsPowerShellBridge.ShellName,
            },
            new Dictionary<string, int> { ["attempts"] = 1, ["produced"] = channels.Count });
    }
}

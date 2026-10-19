namespace AgenticMcp.Agent.Diagnosis;

/// <summary>
/// A bounded, thread-safe ring of recent <see cref="Incident"/>s (plan docs/etw-ringbuffer-plan.md). It is capped two
/// ways so it can run forever without growing without bound: at most <c>capacity</c> entries, and nothing older than
/// <c>maxAge</c>. The producer (the ETW session on Windows, the eBPF collector on Linux) calls <see cref="Add"/> from
/// its own thread; the diagnosis calls <see cref="Recent"/> — both are guarded by one lock, so there is no torn read.
///
/// <para>Only metadata is stored (see <see cref="Incident"/>): no payloads, no memory. Eviction is by age on every
/// access and by count on insert, oldest first.</para>
/// </summary>
public sealed class IncidentRing(int capacity = 1024, TimeSpan? maxAge = null)
{
    private readonly int _capacity = capacity > 0 ? capacity : throw new ArgumentOutOfRangeException(nameof(capacity));
    private readonly TimeSpan _maxAge = maxAge ?? TimeSpan.FromHours(24);
    private readonly LinkedList<Incident> _items = new();   // oldest at the front, newest at the back
    private readonly Lock _gate = new();

    /// <summary>A clock the tests can override; defaults to UTC now.</summary>
    public Func<DateTime> Now { get; init; } = () => DateTime.UtcNow;

    public int Count { get { lock (_gate) { Evict(); return _items.Count; } } }

    /// <summary>Record one incident. The newest is kept at the back; the oldest drops when over capacity.</summary>
    public void Add(Incident incident)
    {
        lock (_gate)
        {
            _items.AddLast(incident);
            Evict();
            while (_items.Count > _capacity)
                _items.RemoveFirst();
        }
    }

    /// <summary>
    /// The recent incidents, newest first, optionally only those touching <paramref name="pid"/> or
    /// <paramref name="image"/> (case-insensitive, by file name) and no older than <paramref name="within"/>.
    /// A snapshot — the returned list is the caller's own and never changes under it.
    /// </summary>
    public IReadOnlyList<Incident> Recent(int? pid = null, string? image = null, TimeSpan? within = null)
    {
        var imageName = image is null ? null : BaseName(image);
        lock (_gate)
        {
            Evict();
            var cutoff = within is null ? (DateTime?)null : Now() - within.Value;
            var result = new List<Incident>();
            for (var node = _items.Last; node is not null; node = node.Previous)   // newest first
            {
                var it = node.Value;
                if (cutoff is not null && it.At < cutoff) continue;
                if (pid is not null && it.Pid != pid) continue;
                if (imageName is not null &&
                    !string.Equals(BaseName(it.Image), imageName, StringComparison.OrdinalIgnoreCase))
                    continue;
                result.Add(it);
            }
            return result;
        }
    }

    /// <summary>All current incidents, newest first (age-evicted). A copy — safe to enumerate after the call.</summary>
    public IReadOnlyList<Incident> All() => Recent();

    /// <summary>
    /// Persist the ring so a host reboot does not erase the recent history (plan E2). Writes at most
    /// <paramref name="maxPersist"/> of the newest incidents as JSON, atomically (temp file + move), and bounded by
    /// count so the file stays small. Best-effort: an IO error is swallowed — losing the file only loses history, and
    /// must never take the agent down.
    /// </summary>
    public void SaveTo(string path, int maxPersist = 512)
    {
        try
        {
            List<Incident> items;
            lock (_gate) { Evict(); items = _items.Count <= maxPersist ? [.. _items] : [.. _items.Skip(_items.Count - maxPersist)]; }
            var tmp = path + ".tmp";
            System.IO.File.WriteAllText(tmp, System.Text.Json.JsonSerializer.Serialize(items));
            System.IO.File.Move(tmp, path, overwrite: true);
        }
        catch (Exception) { /* history is best-effort; never fail the caller */ }
    }

    /// <summary>
    /// Seed the ring from a file written by <see cref="SaveTo"/> (plan E2). Entries older than <c>maxAge</c> and
    /// anything over capacity are dropped on insert, exactly as a live Add would. A missing or unreadable file leaves
    /// the ring empty — the ring must come up either way.
    /// </summary>
    public void LoadFrom(string path)
    {
        try
        {
            if (!System.IO.File.Exists(path))
                return;
            var items = System.Text.Json.JsonSerializer.Deserialize<List<Incident>>(System.IO.File.ReadAllText(path));
            if (items is null)
                return;
            foreach (var it in items.OrderBy(i => i.At))   // oldest first so capacity keeps the newest
                Add(it);
        }
        catch (Exception) { /* a corrupt or partial file is not worth a crash; start empty */ }
    }

    // The file name after the last '/' OR '\\' — NOT System.IO.Path.GetFileName, which only honours the host's own
    // separator: a Windows image path "C:\svc\probe.exe" would not split on the Linux dev/test host, where these
    // rules are tested. An image is matched by its bare file name, case-insensitive, on either platform.
    private static string BaseName(string path)
    {
        var cut = Math.Max(path.LastIndexOf('/'), path.LastIndexOf('\\'));
        return cut < 0 ? path : path[(cut + 1)..];
    }

    // Caller holds the lock. Drop everything older than maxAge (oldest first, so we can stop at the first survivor).
    private void Evict()
    {
        var cutoff = Now() - _maxAge;
        while (_items.First is { } first && first.Value.At < cutoff)
            _items.RemoveFirst();
    }
}

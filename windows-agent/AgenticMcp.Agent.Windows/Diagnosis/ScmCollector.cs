using System.ComponentModel;
using System.Diagnostics.Eventing.Reader;
using System.Runtime.InteropServices;
using AgenticMcp.Agent.Diagnosis;

namespace AgenticMcp.Agent.Windows.Diagnosis;

/// <summary>
/// Fills a <see cref="WinServiceSnapshot"/> through DOCUMENTED interfaces only: the service control manager
/// (OpenService, QueryServiceConfig/Config2, QueryServiceStatusEx, EnumServicesStatusEx for load-order groups) and
/// the event log (EventLogReader with an XPath query, EventData read as data — never the localized message). What
/// these interfaces cannot show is left empty and named by the rules as a gap.
/// </summary>
public static class ScmCollector
{
    private const int EventWindowHours = 24;
    private const int MaxDepth = 5;

    private static readonly int[] ScmEvents = [7000, 7001, 7003, 7009, 7011, 7022, 7023, 7024, 7031, 7034, 7038, 7041];
    // Changes are read over the precedent window (7 days), failures over EventWindowHours.
    private const int ChangeWindowDays = 7;

    public static WinServiceSnapshot Collect(string name, DateTime now)
    {
        var s = new WinServiceSnapshot { Name = name, CollectedAt = now.ToUniversalTime(), EventWindowHours = EventWindowHours };
        using var scm = Native.OpenSCManager(null, null, Native.SC_MANAGER_CONNECT | Native.SC_MANAGER_ENUMERATE_SERVICE);
        if (scm.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenSCManager");
        var (cfg, status, display, err) = Query(scm, name);
        if (cfg is null)
        {
            s.Exists = false;
            s.OpenError = err;
            return s;
        }
        s.Exists = true;
        s.Config = cfg;
        s.Status = status;
        s.DisplayName = display;
        s.Image = ParseImage(cfg.BinaryPathName);
        s.Dependencies = Dependencies(scm, cfg.Dependencies, [name], 1, new(StringComparer.OrdinalIgnoreCase) { name });
        s.ChangeWindowDays = ChangeWindowDays;
        s.KeyLastWrite = KeyLastWrite(name);
        foreach (var d in s.Dependencies.Where(d => d.Exists && !d.IsGroup)) d.KeyLastWrite = KeyLastWrite(d.Name);
        if (s.Image is { Exists: true } im)
        {
            var fi = new FileInfo(im.Path);
            im.Created = fi.CreationTimeUtc;
            im.Written = fi.LastWriteTimeUtc;
            try { (im.Signature, im.Signer) = SignatureCollector.Verify(im.Path); }
            catch (Exception ex) when (ex is not OutOfMemoryException) { im.Signature = $"not checked: {ex.GetType().Name}"; }
        }
        // The account and what it may do (B6). A failure here is a named gap on the account, never a missing field.
        try
        {
            s.Account = AccountCollector.Account(cfg.ServiceStartName);
            if (s.Image is { Exists: true } img)
            {
                s.Access.Add(AccountCollector.Access(img.Path, s.Account, directory: false));
                if (Path.GetDirectoryName(img.Path) is { Length: > 0 } dir)
                    s.Access.Add(AccountCollector.Access(dir, s.Account, directory: true));
            }
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            s.Account ??= new WinAccount { Name = cfg.ServiceStartName, Kind = "unknown" };
            s.Account.Gap = $"reading the account failed: {ex.GetType().Name}: {ex.Message}";
        }
        // B14: a start or stop that is pending — what its threads wait on (no memory is read, only the wait chains)
        if (status is { CurrentState: "start_pending" or "stop_pending", ProcessId: > 0 } pending)
        {
            try { s.WaitChain = WaitChainCollector.Read(pending.ProcessId); }
            catch (Exception ex) when (ex is not OutOfMemoryException) { s.WaitChain = new WinWaitChain { ProcessId = pending.ProcessId, Gap = $"{ex.GetType().Name}: {ex.Message}" }; }
        }
        try
        {
            s.Events = ReadEvents(s.Image, s.Account?.Name ?? cfg.ServiceStartName);
            s.LogonFailureAudited = LogonFailureAudited();
            s.CrashFrame = CrashFrame(s);
            s.SystemLogOldest = OldestRecord("System");
        }
        catch (Exception ex) when (ex is EventLogException or UnauthorizedAccessException)
        {
            s.EventError = ex.Message;
        }
        return s;
    }

    private static (WinServiceConfig? cfg, WinServiceStatus? status, string? display, int err) Query(Native.ScHandle scm, string name)
    {
        using var h = Native.OpenService(scm, name, Native.SERVICE_QUERY_CONFIG | Native.SERVICE_QUERY_STATUS);
        if (h.IsInvalid) return (null, null, null, Marshal.GetLastWin32Error());
        Native.QueryServiceConfig(h, IntPtr.Zero, 0, out var need);
        var buf = Marshal.AllocHGlobal(need);
        try
        {
            if (!Native.QueryServiceConfig(h, buf, need, out _)) throw new Win32Exception(Marshal.GetLastWin32Error(), "QueryServiceConfig");
            var c = Marshal.PtrToStructure<Native.QUERY_SERVICE_CONFIG>(buf);
            var cfg = new WinServiceConfig
            {
                BinaryPathName = Marshal.PtrToStringUni(c.lpBinaryPathName) ?? "",
                StartType = c.dwStartType switch { 0 => "boot", 1 => "system", 2 => "auto", 3 => "demand", 4 => "disabled", _ => c.dwStartType.ToString() },
                ServiceStartName = Marshal.PtrToStringUni(c.lpServiceStartName) ?? "",
                LoadOrderGroup = Marshal.PtrToStringUni(c.lpLoadOrderGroup) ?? "",
                Dependencies = MultiSz(c.lpDependencies),
                ServiceType = (c.dwServiceType & 0x30) != 0 ? "win32" : "driver",
                DelayedAutoStart = DelayedAuto(h),
            };
            var display = Marshal.PtrToStringUni(c.lpDisplayName);
            return (cfg, Status(h), display, 0);
        }
        finally
        {
            Marshal.FreeHGlobal(buf);
        }
    }

    private static bool DelayedAuto(Native.ScHandle h)
    {
        var buf = Marshal.AllocHGlobal(16);
        try
        {
            return Native.QueryServiceConfig2(h, 3, buf, 16, out _) && Marshal.ReadInt32(buf) != 0;
        }
        finally
        {
            Marshal.FreeHGlobal(buf);
        }
    }

    private static WinServiceStatus Status(Native.ScHandle h)
    {
        var size = Marshal.SizeOf<Native.SERVICE_STATUS_PROCESS>();
        var buf = Marshal.AllocHGlobal(size);
        try
        {
            if (!Native.QueryServiceStatusEx(h, 0, buf, size, out _)) throw new Win32Exception(Marshal.GetLastWin32Error(), "QueryServiceStatusEx");
            var p = Marshal.PtrToStructure<Native.SERVICE_STATUS_PROCESS>(buf);
            DateTime? started = null;
            if (p.dwProcessId > 0)
            {
                try { using var proc = System.Diagnostics.Process.GetProcessById(p.dwProcessId); started = proc.StartTime.ToUniversalTime(); }
                catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or Win32Exception) { }
            }
            return new WinServiceStatus
            {
                CurrentState = StateName(p.dwCurrentState), Win32ExitCode = p.dwWin32ExitCode,
                ServiceSpecificExitCode = p.dwServiceSpecificExitCode, ProcessId = p.dwProcessId,
                CheckPoint = p.dwCheckPoint, WaitHintMs = p.dwWaitHint, ProcessStarted = started,
            };
        }
        finally
        {
            Marshal.FreeHGlobal(buf);
        }
    }

    private static string StateName(int s) => s switch
    {
        1 => "stopped", 2 => "start_pending", 3 => "stop_pending", 4 => "running",
        5 => "continue_pending", 6 => "pause_pending", 7 => "paused", _ => s.ToString(),
    };

    /// <summary>The dependency chain, recursively; a `+Group` dependency is resolved to its member services.</summary>
    private static List<WinDependency> Dependencies(Native.ScHandle scm, List<string> deps, List<string> via, int depth, HashSet<string> seen)
    {
        var output = new List<WinDependency>();
        if (depth > MaxDepth) return output;
        foreach (var dep in deps)
        {
            if (dep.StartsWith('+'))
            {
                var members = GroupMembers(scm, dep[1..]);
                if (members.Count == 0)
                    output.Add(new WinDependency { Name = dep, IsGroup = true, Via = [.. via], Depth = depth, Exists = false });
                foreach (var m in members.Where(seen.Add))
                    output.AddRange(One(scm, m, [.. via, dep], depth, seen));
                continue;
            }
            if (!seen.Add(dep)) continue;
            output.AddRange(One(scm, dep, via, depth, seen));
        }
        return output;
    }

    private static List<WinDependency> One(Native.ScHandle scm, string name, List<string> via, int depth, HashSet<string> seen)
    {
        var (cfg, st, display, _) = Query(scm, name);
        var d = new WinDependency
        {
            Name = name, Via = [.. via], Depth = depth, Exists = cfg is not null, DisplayName = display,
            StartType = cfg?.StartType, CurrentState = st?.CurrentState, Win32ExitCode = st?.Win32ExitCode ?? 0,
        };
        var output = new List<WinDependency> { d };
        if (cfg is not null) output.AddRange(Dependencies(scm, cfg.Dependencies, [.. via, name], depth + 1, seen));
        return output;
    }

    private static List<string> GroupMembers(Native.ScHandle scm, string group)
    {
        uint resume = 0;
        Native.EnumServicesStatusEx(scm, 0, 0x3F, 3, IntPtr.Zero, 0, out var need, out _, ref resume, group);
        if (need == 0) return [];
        var buf = Marshal.AllocHGlobal(need);
        try
        {
            resume = 0;
            if (!Native.EnumServicesStatusEx(scm, 0, 0x3F, 3, buf, need, out _, out var count, ref resume, group)) return [];
            var size = Marshal.SizeOf<Native.ENUM_SERVICE_STATUS_PROCESS>();
            var names = new List<string>();
            for (var i = 0; i < count; i++)
            {
                var e = Marshal.PtrToStructure<Native.ENUM_SERVICE_STATUS_PROCESS>(buf + i * size);
                if (Marshal.PtrToStringUni(e.lpServiceName) is { } n) names.Add(n);
            }
            return names;
        }
        finally
        {
            Marshal.FreeHGlobal(buf);
        }
    }

    private static List<string> MultiSz(IntPtr p)
    {
        var output = new List<string>();
        if (p == IntPtr.Zero) return output;
        while (true)
        {
            var s = Marshal.PtrToStringUni(p);
            if (string.IsNullOrEmpty(s)) break;
            output.Add(s);
            p += (s.Length + 1) * 2;
        }
        return output;
    }

    /// <summary>
    /// The executable of an ImagePath. Quoted: the quoted part. Unquoted: up to the first ".exe" — and if that part
    /// contains a space, Windows would try the shorter prefixes first (CreateProcess's documented search), which is
    /// the unquoted-path finding.
    /// </summary>
    public static WinImage? ParseImage(string binaryPath)
    {
        var raw = Environment.ExpandEnvironmentVariables(binaryPath.Trim());
        if (raw.Length == 0) return null;
        string path;
        var unquoted = false;
        if (raw.StartsWith('"'))
        {
            var end = raw.IndexOf('"', 1);
            path = end > 0 ? raw[1..end] : raw.Trim('"');
        }
        else
        {
            var exe = raw.IndexOf(".exe", StringComparison.OrdinalIgnoreCase);
            path = exe > 0 ? raw[..(exe + 4)] : raw.Split(' ')[0];
            unquoted = path.Contains(' ');
        }
        if (path.StartsWith(@"\SystemRoot\", StringComparison.OrdinalIgnoreCase))
            path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), path[12..]);
        else if (path.StartsWith(@"system32\", StringComparison.OrdinalIgnoreCase))
            path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), path);
        return new WinImage { Path = path, Exists = File.Exists(path), UnquotedWithSpace = unquoted };
    }

    /// <summary>
    /// The service account's failed service logons: Security 4625, logon type 5, by services.exe (B6 follow-up).
    /// Measured on bossman-wintest: a disabled account → Status 0xC000006E / SubStatus 0xC0000072, a missing right
    /// → 0xC000015B — Windows' own reason, by number. EventData order of 4625 (fixed by the event's schema):
    /// 5 TargetUserName, 6 TargetDomainName, 7 Status, 9 SubStatus, 10 LogonType, 18 ProcessName.
    /// </summary>
    private static IEnumerable<WinEvent> LogonFailures(string? account, long window)
    {
        if (string.IsNullOrEmpty(account) || account.Equals("LocalSystem", StringComparison.OrdinalIgnoreCase)) return [];
        var user = account.Contains('\\') ? account[(account.LastIndexOf('\\') + 1)..] : account;
        return Query("Security", $"*[System[EventID=4625 and TimeCreated[timediff(@SystemTime) <= {window}]] and EventData[Data[@Name='LogonType']='5']]")
            .Where(e => e.Data.Count > 18 && e.Data[5].Equals(user, StringComparison.OrdinalIgnoreCase)
                        && e.Data[18].EndsWith(@"\services.exe", StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>
    /// The newest application error (1000) of the service's image, resolved to a function (B14 step 2). Fields as
    /// measured on bossman-wintest: 3 module, 4 module version at the crash, 6 exception (hex, no 0x), 7 fault offset
    /// (hex, no 0x), 10 application path, 11 module path.
    /// </summary>
    private static WinCrashFrame? CrashFrame(WinServiceSnapshot s)
    {
        if (s.Image is not { } img) return null;
        var e = s.Events.Where(x => x.Provider == "Application Error" && x.EventId == 1000 && x.Data.Count > 11
                                    && x.Data[10].Equals(img.Path, StringComparison.OrdinalIgnoreCase))
            .OrderByDescending(x => x.Time).FirstOrDefault();
        if (e is null) return null;
        static ulong Hex(string v) => ulong.TryParse(v.StartsWith("0x", StringComparison.OrdinalIgnoreCase) ? v[2..] : v,
            System.Globalization.NumberStyles.HexNumber, null, out var n) ? n : 0;
        var f = new WinCrashFrame
        {
            EventRecord = e.RecordId, Module = e.Data[3], ModuleVersionAtCrash = e.Data[4], Exception = (uint)Hex(e.Data[6]),
            Offset = Hex(e.Data[7]), ModulePath = e.Data[11],
        };
        try { CrashSymbolizer.Resolve(f); }
        catch (Exception ex) when (ex is not OutOfMemoryException) { f.Gap = $"resolving the symbol failed: {ex.GetType().Name}: {ex.Message}"; }
        return f;
    }

    /// <summary>Audit policy "Logon" (subcategory {0CCE9215-…}), Failure flag — locale-independent, unlike auditpol's names.</summary>
    private static bool? LogonFailureAudited()
    {
        var guid = new Guid("0CCE9215-69AE-11D9-BED3-505054503030");
        if (!Native.AuditQuerySystemPolicy(ref guid, 1, out var info)) return null;
        try { return (Marshal.ReadInt32(info, 16) & 0x2) != 0; }      // AUDIT_POLICY_INFORMATION.AuditingInformation
        finally { Native.AuditFree(info); }
    }

    private static List<WinEvent> ReadEvents(WinImage? image, string? account)
    {
        var window = EventWindowHours * 3600L * 1000L;
        var ids = string.Join(" or ", ScmEvents.Select(i => $"EventID={i}"));
        var events = Query("System", $"*[System[Provider[@Name='Service Control Manager'] and ({ids}) and TimeCreated[timediff(@SystemTime) <= {window}]]]");
        if (image is not null)
            // By PROVIDER too: Microsoft-Windows-LoadPerf also writes 1000/1001 into Application (measured: they filled the
            // evidence of every diagnosis with performance-counter noise).
            events.AddRange(Query("Application",
                $"*[System[((Provider[@Name='Application Error'] and EventID=1000) or (Provider[@Name='Windows Error Reporting'] and EventID=1001) "
                + $"or (Provider[@Name='.NET Runtime'] and EventID=1026)) and TimeCreated[timediff(@SystemTime) <= {window}]]]"));
        // Changes (B7), over the precedent window: the service installed / its start type changed, and the host's
        // product installs (MsiInstaller) and installed updates (WindowsUpdateClient 19).
        var changes = ChangeWindowDays * 24L * 3600L * 1000L;
        events.AddRange(Query("System", $"*[System[Provider[@Name='Service Control Manager'] and (EventID=7040 or EventID=7045) and TimeCreated[timediff(@SystemTime) <= {changes}]]]"));
        events.AddRange(Query("Application", $"*[System[Provider[@Name='MsiInstaller'] and (EventID=1033 or EventID=1034 or EventID=1035 or EventID=1036) and TimeCreated[timediff(@SystemTime) <= {changes}]]]"));
        events.AddRange(Query("System", $"*[System[Provider[@Name='Microsoft-Windows-WindowsUpdateClient'] and EventID=19 and TimeCreated[timediff(@SystemTime) <= {changes}]]]"));
        try { events.AddRange(LogonFailures(account, window)); }
        catch (Exception ex) when (ex is EventLogException or UnauthorizedAccessException) { }   // the Security log may be unreadable; the audit flag still says what is missing
        // A policy may block the image from running at all: AppLocker (8003 audit, 8004 enforce) and Windows Defender
        // Application Control / Code Integrity (3076 audit, 3077 enforce). Matched to the image by name in the rules.
        if (image is not null)
        {
            foreach (var (channel, xq) in new[]
            {
                ("Microsoft-Windows-AppLocker/EXE and DLL", $"*[System[(EventID=8003 or EventID=8004) and TimeCreated[timediff(@SystemTime) <= {window}]]]"),
                ("Microsoft-Windows-CodeIntegrity/Operational", $"*[System[(EventID=3076 or EventID=3077) and TimeCreated[timediff(@SystemTime) <= {window}]]]"),
            })
            {
                try { events.AddRange(Query(channel, xq)); }
                catch (Exception ex) when (ex is EventLogException or UnauthorizedAccessException) { }   // the channel may be absent/unreadable
            }
        }
        return events;
    }

    /// <summary>LastWriteTime of the service's registry key (RegQueryInfoKey); null when it cannot be read.</summary>
    private static DateTime? KeyLastWrite(string service)
    {
        using var key = Microsoft.Win32.Registry.LocalMachine.OpenSubKey($@"SYSTEM\CurrentControlSet\Services\{service}");
        if (key is null) return null;
        var rc = Native.RegQueryInfoKey(key.Handle, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, out var ft);
        return rc == 0 ? DateTime.FromFileTimeUtc(ft) : null;
    }

    private static List<WinEvent> Query(string log, string xpath)
    {
        var output = new List<WinEvent>();
        using var reader = new EventLogReader(new EventLogQuery(log, PathType.LogName, xpath) { ReverseDirection = true });
        for (var i = 0; i < 400 && reader.ReadEvent() is { } rec; i++)
        {
            using (rec)
            {
                output.Add(new WinEvent
                {
                    Log = log, EventId = rec.Id, RecordId = rec.RecordId ?? 0, Provider = rec.ProviderName ?? "",
                    Time = (rec.TimeCreated ?? DateTime.UtcNow).ToUniversalTime(),
                    Data = rec.Properties.Select(p => Convert.ToString(p.Value, System.Globalization.CultureInfo.InvariantCulture) ?? "").ToList(),
                });
            }
        }
        return output;
    }

    private static DateTime? OldestRecord(string log)
    {
        using var reader = new EventLogReader(new EventLogQuery(log, PathType.LogName) { ReverseDirection = false });
        using var rec = reader.ReadEvent();
        return rec?.TimeCreated?.ToUniversalTime();
    }

    private static class Native
    {
        public const uint SC_MANAGER_CONNECT = 0x0001;
        public const uint SC_MANAGER_ENUMERATE_SERVICE = 0x0004;
        public const uint SERVICE_QUERY_CONFIG = 0x0001;
        public const uint SERVICE_QUERY_STATUS = 0x0004;

        public sealed class ScHandle : Microsoft.Win32.SafeHandles.SafeHandleZeroOrMinusOneIsInvalid
        {
            public ScHandle() : base(true) { }
            protected override bool ReleaseHandle() => CloseServiceHandle(handle);
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct QUERY_SERVICE_CONFIG
        {
            public int dwServiceType, dwStartType, dwErrorControl;
            public IntPtr lpBinaryPathName, lpLoadOrderGroup;
            public int dwTagId;
            public IntPtr lpDependencies, lpServiceStartName, lpDisplayName;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct SERVICE_STATUS_PROCESS
        {
            public int dwServiceType, dwCurrentState, dwControlsAccepted, dwWin32ExitCode, dwServiceSpecificExitCode,
                dwCheckPoint, dwWaitHint, dwProcessId, dwServiceFlags;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct ENUM_SERVICE_STATUS_PROCESS
        {
            public IntPtr lpServiceName, lpDisplayName;
            public SERVICE_STATUS_PROCESS ServiceStatusProcess;
        }

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.U1)]
        public static extern bool AuditQuerySystemPolicy(ref Guid subCategory, uint count, out IntPtr policy);

        [DllImport("advapi32.dll")]
        public static extern void AuditFree(IntPtr buffer);

        [DllImport("advapi32.dll", EntryPoint = "RegQueryInfoKeyW", CharSet = CharSet.Unicode)]
        public static extern int RegQueryInfoKey(Microsoft.Win32.SafeHandles.SafeRegistryHandle key, IntPtr cls, IntPtr clsLen,
            IntPtr reserved, IntPtr subKeys, IntPtr maxSubKeyLen, IntPtr maxClassLen, IntPtr values, IntPtr maxValueNameLen,
            IntPtr maxValueLen, IntPtr securityDescriptor, out long lastWriteTime);

        [DllImport("advapi32.dll", EntryPoint = "OpenSCManagerW", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern ScHandle OpenSCManager(string? machine, string? database, uint access);

        [DllImport("advapi32.dll", EntryPoint = "OpenServiceW", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern ScHandle OpenService(ScHandle scm, string name, uint access);

        [DllImport("advapi32.dll", EntryPoint = "QueryServiceConfigW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool QueryServiceConfig(ScHandle h, IntPtr buf, int size, out int needed);

        [DllImport("advapi32.dll", EntryPoint = "QueryServiceConfig2W", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool QueryServiceConfig2(ScHandle h, int level, IntPtr buf, int size, out int needed);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool QueryServiceStatusEx(ScHandle h, int level, IntPtr buf, int size, out int needed);

        [DllImport("advapi32.dll", EntryPoint = "EnumServicesStatusExW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool EnumServicesStatusEx(ScHandle scm, int level, int type, int state, IntPtr buf, int size,
            out int needed, out int returned, ref uint resume, string? group);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CloseServiceHandle(IntPtr h);
    }
}

using System.Text.Json.Serialization;

namespace AgenticMcp.Agent.Diagnosis;

// Everything the Windows rules look at, collected once (AgenticMcp.Agent.Windows/Diagnosis fills it through the
// service control manager, the event log, LSA and Authz). The rules are plain functions over this record, so they
// are tested on recorded snapshots on Linux — the same split the Go agent has (SystemdSnapshot / DiagnoseSystemd).

public sealed class WinServiceSnapshot
{
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("exists")] public bool Exists { get; set; }
    [JsonPropertyName("open_error")] public int OpenError { get; set; }
    [JsonPropertyName("display_name")] public string? DisplayName { get; set; }
    [JsonPropertyName("config")] public WinServiceConfig? Config { get; set; }
    [JsonPropertyName("status")] public WinServiceStatus? Status { get; set; }
    [JsonPropertyName("dependencies")] public List<WinDependency> Dependencies { get; set; } = [];
    [JsonPropertyName("image")] public WinImage? Image { get; set; }
    [JsonPropertyName("events")] public List<WinEvent> Events { get; set; } = [];
    [JsonPropertyName("event_window_hours")] public int EventWindowHours { get; set; } = 24;
    [JsonPropertyName("system_log_oldest")] public DateTime? SystemLogOldest { get; set; }
    [JsonPropertyName("event_error")] public string? EventError { get; set; }
    [JsonPropertyName("account")] public WinAccount? Account { get; set; }
    [JsonPropertyName("access")] public List<WinAccess> Access { get; set; } = [];
    /// <summary>LastWriteTime of HKLM\SYSTEM\CurrentControlSet\Services\&lt;name&gt; (RegQueryInfoKey) — a precedent (B7).</summary>
    [JsonPropertyName("key_last_write")] public DateTime? KeyLastWrite { get; set; }
    /// <summary>How far back 7040/7045 and the host's installs/updates were read (the precedent window).</summary>
    [JsonPropertyName("change_window_days")] public int ChangeWindowDays { get; set; } = 7;
    /// <summary>Whether this host audits failed logons (audit policy, subcategory Logon, Failure) — null: not readable.
    /// Without it Windows writes no 4625, and a failed service logon carries no reason.</summary>
    [JsonPropertyName("logon_failure_audited")] public bool? LogonFailureAudited { get; set; }
    /// <summary>What each thread of the service's process waits on (Wait Chain Traversal, B14) — read for a pending
    /// start/stop or on request; null when not read.</summary>
    [JsonPropertyName("wait_chain")] public WinWaitChain? WaitChain { get; set; }
    /// <summary>Where the service's process crashed, resolved to a function by public symbols (B14 step 2) — from the newest
    /// application error (1000) of its image; null when there is none.</summary>
    [JsonPropertyName("crash_frame")] public WinCrashFrame? CrashFrame { get; set; }
    /// <summary>Recent PAST incidents for this service's image or last pid, newest first, read from the agent's incident
    /// ring (docs/etw-ringbuffer-plan.md): an abnormal process exit, a crash, a managed exception. Each becomes
    /// evidence under svc.recent_incident (Likely — it describes a past invocation). Empty when the ring has none.</summary>
    [JsonPropertyName("recent_incidents")] public List<Incident> RecentIncidents { get; set; } = [];
    [JsonPropertyName("collected_at")] public DateTime CollectedAt { get; set; }
}

public sealed class WinServiceConfig
{
    [JsonPropertyName("binary_path_name")] public string BinaryPathName { get; set; } = "";
    /// <summary>boot, system, auto, demand, disabled — the SCM's own start types.</summary>
    [JsonPropertyName("start_type")] public string StartType { get; set; } = "";
    [JsonPropertyName("delayed_auto_start")] public bool DelayedAutoStart { get; set; }
    [JsonPropertyName("service_start_name")] public string ServiceStartName { get; set; } = "";
    /// <summary>Service names; a load-order group is written `+Group`, as the SCM does.</summary>
    [JsonPropertyName("dependencies")] public List<string> Dependencies { get; set; } = [];
    [JsonPropertyName("load_order_group")] public string LoadOrderGroup { get; set; } = "";
    [JsonPropertyName("service_type")] public string ServiceType { get; set; } = "";
}

public sealed class WinServiceStatus
{
    /// <summary>stopped, start_pending, stop_pending, running, continue_pending, pause_pending, paused.</summary>
    [JsonPropertyName("current_state")] public string CurrentState { get; set; } = "";
    [JsonPropertyName("win32_exit_code")] public int Win32ExitCode { get; set; }
    [JsonPropertyName("service_specific_exit_code")] public int ServiceSpecificExitCode { get; set; }
    [JsonPropertyName("process_id")] public int ProcessId { get; set; }
    /// <summary>The service's own progress report while pending (SERVICE_STATUS dwCheckPoint / dwWaitHint, ms).</summary>
    [JsonPropertyName("check_point")] public int CheckPoint { get; set; }
    [JsonPropertyName("wait_hint_ms")] public int WaitHintMs { get; set; }
    /// <summary>When the service's process started — how long a pending start has been pending.</summary>
    [JsonPropertyName("process_started")] public DateTime? ProcessStarted { get; set; }
}

public sealed class WinDependency
{
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("is_group")] public bool IsGroup { get; set; }
    [JsonPropertyName("via")] public List<string> Via { get; set; } = [];
    [JsonPropertyName("depth")] public int Depth { get; set; }
    [JsonPropertyName("exists")] public bool Exists { get; set; }
    [JsonPropertyName("display_name")] public string? DisplayName { get; set; }
    [JsonPropertyName("start_type")] public string? StartType { get; set; }
    [JsonPropertyName("current_state")] public string? CurrentState { get; set; }
    [JsonPropertyName("win32_exit_code")] public int Win32ExitCode { get; set; }
    [JsonPropertyName("key_last_write")] public DateTime? KeyLastWrite { get; set; }
}

public sealed class WinImage
{
    [JsonPropertyName("path")] public string Path { get; set; } = "";
    [JsonPropertyName("exists")] public bool Exists { get; set; }
    [JsonPropertyName("unquoted_with_space")] public bool UnquotedWithSpace { get; set; }
    /// <summary>Authenticode trust of the image (WinVerifyTrust): "valid", "unsigned", or "untrusted: &lt;reason&gt;".</summary>
    [JsonPropertyName("signature")] public string? Signature { get; set; }
    [JsonPropertyName("signer")] public string? Signer { get; set; }
    [JsonPropertyName("created")] public DateTime? Created { get; set; }
    [JsonPropertyName("written")] public DateTime? Written { get; set; }
    /// <summary>
    /// When the file changed ON THIS HOST: the later of creation and last write. A copied or installed file keeps the
    /// write time it had in the package, but its creation time is the copy (B7).
    /// </summary>
    [JsonIgnore] public DateTime? Changed => Created is { } c && Written is { } w ? (c > w ? c : w) : Created ?? Written;
}

public sealed class WinEvent
{
    [JsonPropertyName("log")] public string Log { get; set; } = "";
    [JsonPropertyName("event_id")] public int EventId { get; set; }
    [JsonPropertyName("record_id")] public long RecordId { get; set; }
    [JsonPropertyName("time")] public DateTime Time { get; set; }
    [JsonPropertyName("provider")] public string Provider { get; set; } = "";
    /// <summary>EventData in order — structured, never the localized message text.</summary>
    [JsonPropertyName("data")] public List<string> Data { get; set; } = [];
}

/// <summary>The service account as LSA/SAM see it (B6). Unknown parts stay null and become named gaps.</summary>
public sealed class WinAccount
{
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("sid")] public string? Sid { get; set; }
    /// <summary>local-system, local-service, network-service, virtual, managed, local, domain, unresolved.</summary>
    [JsonPropertyName("kind")] public string Kind { get; set; } = "";
    [JsonPropertyName("disabled")] public bool? Disabled { get; set; }
    [JsonPropertyName("locked_out")] public bool? LockedOut { get; set; }
    [JsonPropertyName("password_expired")] public bool? PasswordExpired { get; set; }
    [JsonPropertyName("service_logon_right")] public bool? ServiceLogonRight { get; set; }
    [JsonPropertyName("deny_service_logon_right")] public bool? DenyServiceLogonRight { get; set; }
    [JsonPropertyName("rights_via")] public List<string> RightsVia { get; set; } = [];
    [JsonPropertyName("gap")] public string? Gap { get; set; }
}

/// <summary>An access check of the service account on one path (B6).</summary>
public sealed class WinAccess
{
    [JsonPropertyName("path")] public string Path { get; set; } = "";
    [JsonPropertyName("sid")] public string Sid { get; set; } = "";
    [JsonPropertyName("desired")] public string Desired { get; set; } = "";
    [JsonPropertyName("granted")] public bool? Granted { get; set; }
    [JsonPropertyName("denying_ace")] public string? DenyingAce { get; set; }
    [JsonPropertyName("sddl")] public string? Sddl { get; set; }
    [JsonPropertyName("gap")] public string? Gap { get; set; }
}

/// <summary>The wait chains of one process (GetThreadWaitChain per thread, B14).</summary>
public sealed class WinWaitChain
{
    [JsonPropertyName("process_id")] public int ProcessId { get; set; }
    [JsonPropertyName("threads")] public List<WinThreadChain> Threads { get; set; } = [];
    /// <summary>".NET" when the process has coreclr/clr loaded — then a wait chain with no lock owner may be a managed
    /// wait (Mutex.WaitOne, Monitor), which Wait Chain Traversal cannot follow (measured).</summary>
    [JsonPropertyName("runtime")] public string? Runtime { get; set; }
    [JsonPropertyName("gap")] public string? Gap { get; set; }
}

public sealed class WinThreadChain
{
    [JsonPropertyName("thread_id")] public int ThreadId { get; set; }
    /// <summary>Windows says the chain closes on itself — a deadlock.</summary>
    [JsonPropertyName("is_cycle")] public bool IsCycle { get; set; }
    [JsonPropertyName("nodes")] public List<WinWaitNode> Nodes { get; set; } = [];
    [JsonPropertyName("error")] public int Error { get; set; }
}

/// <summary>One node of a wait chain, in Windows' words (WCT_OBJECT_TYPE / WCT_OBJECT_STATUS).</summary>
public sealed class WinWaitNode
{
    /// <summary>CriticalSection, SendMessage, Mutex, Alpc, Com, ThreadWait, ProcessWait, Thread, ComActivation, Unknown, SocketIo, SmbIo.</summary>
    [JsonPropertyName("type")] public string Type { get; set; } = "";
    /// <summary>NoAccess, Running, Blocked, PidOnly, PidOnlyRpcss, Owned, NotOwned, Abandoned, Unknown, Error.</summary>
    [JsonPropertyName("status")] public string Status { get; set; } = "";
    [JsonPropertyName("name")] public string? Name { get; set; }
    [JsonPropertyName("process_id")] public int? ProcessId { get; set; }
    [JsonPropertyName("thread_id")] public int? ThreadId { get; set; }
    [JsonPropertyName("wait_time_ms")] public long? WaitTimeMs { get; set; }
}

/// <summary>The faulting location of a crash: module + offset from event 1000, the function from the module's PDB.</summary>
public sealed class WinCrashFrame
{
    [JsonPropertyName("event_record")] public long EventRecord { get; set; }
    [JsonPropertyName("module")] public string Module { get; set; } = "";
    [JsonPropertyName("module_path")] public string ModulePath { get; set; } = "";
    [JsonPropertyName("module_version_at_crash")] public string? ModuleVersionAtCrash { get; set; }
    [JsonPropertyName("module_version_now")] public string? ModuleVersionNow { get; set; }
    [JsonPropertyName("offset")] public ulong Offset { get; set; }
    [JsonPropertyName("exception")] public uint Exception { get; set; }
    [JsonPropertyName("function")] public string? Function { get; set; }
    [JsonPropertyName("displacement")] public ulong? Displacement { get; set; }
    [JsonPropertyName("pdb")] public string? Pdb { get; set; }
    [JsonPropertyName("pdb_id")] public string? PdbId { get; set; }
    [JsonPropertyName("symbol_source")] public string? SymbolSource { get; set; }
    [JsonPropertyName("gap")] public string? Gap { get; set; }
}

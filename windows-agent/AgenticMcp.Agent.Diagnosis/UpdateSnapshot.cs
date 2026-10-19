namespace AgenticMcp.Agent.Diagnosis;

// What the update rules look at, collected once. On Windows the `update_diagnose` module fills it from the read-only
// windows_update_facts output; the rules (UpdateRules) are a pure function over this record, so they are tested on the
// Linux dev host against recorded snapshots — the same split as the service diagnosis (WinServiceSnapshot).

public sealed class UpdateSnapshot
{
    public string Host { get; set; } = "";
    public string Platform { get; set; } = "windows";
    /// <summary>The Windows Update search result in Windows' own word: Succeeded / SucceededWithErrors / Failed / …</summary>
    public string SearchResult { get; set; } = "";
    /// <summary>Whether the search finished cleanly; when false the pending list may be incomplete.</summary>
    public bool SearchComplete { get; set; }
    public string? IncompleteReason { get; set; }
    /// <summary>windows_update or wsus.</summary>
    public string Server { get; set; } = "windows_update";
    public string? WsusServer { get; set; }
    public List<PendingUpdate> Pending { get; set; } = [];
    public List<UpdateHistoryEntry> History { get; set; } = [];   // newest first
    public bool RebootRequired { get; set; }
    public List<string> RebootReasons { get; set; } = [];
    public DateTime? LastSearchSuccess { get; set; }
    public DateTime CollectedAt { get; set; }
}

public sealed class PendingUpdate
{
    public string? Kb { get; set; }
    public string Title { get; set; } = "";
    /// <summary>Critical / Important / Moderate / Low / unrated — Windows' own MSRC severity.</summary>
    public string MsrcSeverity { get; set; } = "unrated";
    public List<string> Categories { get; set; } = [];
    public bool NeedsReboot { get; set; }
}

public sealed class UpdateHistoryEntry
{
    public DateTime? Date { get; set; }
    public string Operation { get; set; } = "";   // Installation / Uninstallation
    /// <summary>Succeeded / SucceededWithErrors / Failed / Aborted … — Windows' own result code.</summary>
    public string Result { get; set; } = "";
    public string? Hresult { get; set; }           // "0x8024200D"
    public string? Kb { get; set; }
    public string Title { get; set; } = "";
}

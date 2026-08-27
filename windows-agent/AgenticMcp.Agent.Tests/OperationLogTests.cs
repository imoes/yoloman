using System.Text.Json;
using AgenticMcp.Agent.Core;

namespace AgenticMcp.Agent.Tests;

/// <summary>
/// The operation log: what it records, what it refuses to record, and what a collector can tell from a page.
///
/// These run against the process-wide log, so each one resets it first — a shared static that tests fight over
/// would be a worse bug than any it could catch.
/// </summary>
[Collection("operation-log")]
public class OperationLogTests
{
    private static readonly DateTimeOffset When = new(2026, 8, 27, 12, 0, 0, TimeSpan.Zero);

    private static OperationRecord Record(string module, string outcome,
                                          Dictionary<string, object?>? parameters = null) =>
        OperationLog.Record(module, outcome, false, parameters, "CN=bossman", When, 12.34,
            changed: outcome == "changed", message: "m", evidence: new Dictionary<string, object?> { ["exit_code"] = 0 });

    [Fact]
    public void SecretsAreRedactedButTheParameterNameSurvives()
    {
        OperationLog.ResetForTests();
        var record = Record("package", "changed", new Dictionary<string, object?>
        {
            ["name"] = "acme-widget",
            ["password"] = "hunter2",
            ["Smb_Password"] = "hunter2",
            ["api_key"] = "k",
        });

        Assert.Equal("acme-widget", record.Params["name"]);
        // The KEY is kept: "a password was passed" is part of what happened. The value never is.
        Assert.Equal("***redacted***", record.Params["password"]);
        Assert.Equal("***redacted***", record.Params["Smb_Password"]);
        Assert.Equal("***redacted***", record.Params["api_key"]);
        Assert.DoesNotContain("hunter2", JsonSerializer.Serialize(record));
    }

    [Fact]
    public void ADryRunIsPlannedRatherThanUnchanged()
    {
        OperationLog.ResetForTests();
        var record = OperationLog.Record("windows_feature", "planned", true, null, null, When, 1);
        Assert.Equal("planned", record.Outcome);
        Assert.True(record.DryRun);
        // Filing a preview as "unchanged" is how a plan gets mistaken for a no-op afterwards.
        Assert.NotEqual("unchanged", record.Outcome);
    }

    [Fact]
    public void EveryRecordCarriesEvidenceAndAStableId()
    {
        OperationLog.ResetForTests();
        var first = Record("package", "changed");
        var second = Record("package", "changed");
        Assert.NotEqual(first.Id, second.Id);
        Assert.Equal(2, second.Seq);
        Assert.NotNull(first.Evidence);
        Assert.Contains("exit_code", JsonSerializer.Serialize(first.Evidence));
    }

    [Fact]
    public void FiltersAreAndedAndTheCursorReturnsOnlyWhatIsNew()
    {
        OperationLog.ResetForTests();
        Record("package", "changed");
        Record("windows_feature", "refused");
        var third = Record("package", "unchanged");

        Assert.Equal(3, OperationLog.Page().Count);
        Assert.Single(OperationLog.Page(module: "windows_feature").Records);
        Assert.Single(OperationLog.Page(module: "package", outcome: "changed").Records);
        // A cursor page holds only what the collector has not seen.
        var page = OperationLog.Page(sinceSeq: 2);
        Assert.Single(page.Records);
        Assert.Equal(third.Seq, page.Records[0].Seq);
        Assert.Equal(0, page.Dropped);
    }

    [Fact]
    public void WhatFellOutOfTheRingIsReportedAsANumberNotAsSilence()
    {
        OperationLog.ResetForTests();
        for (var i = 0; i < OperationLog.Capacity + 5; i++)
        {
            Record("package", "unchanged");
        }

        var page = OperationLog.Page(limit: OperationLog.Capacity);
        Assert.Equal(OperationLog.Capacity, page.Records.Count);
        // NOTHING VANISHES SILENTLY: a collector that fell behind learns that it did, and by how much.
        Assert.Equal(5, page.Dropped);
        Assert.Equal(6, page.OldestSeq);
        Assert.Equal(OperationLog.Capacity + 5, page.NewestSeq);
    }

    [Fact]
    public void ThePageNamesTheProcessSoARestartIsDetectable()
    {
        OperationLog.ResetForTests();
        var page = OperationLog.Page();
        Assert.False(string.IsNullOrWhiteSpace(page.BootId));
        Assert.Equal(OperationLog.BootId, page.BootId);
        // Sequence numbers restart with the process; without the boot id a collector cannot tell a restart
        // from "nothing new", and would either skip or repeat a whole boot's worth of records.
        Assert.Equal(0, page.NewestSeq);
    }

    [Fact]
    public void TheWireNamesAreTheOnesBossmanReads()
    {
        OperationLog.ResetForTests();
        var json = JsonSerializer.Serialize(OperationLog.Page(limit: 1));
        foreach (var field in new[] { "boot_id", "oldest_seq", "newest_seq", "dropped", "capacity", "count", "records" })
        {
            Assert.Contains($"\"{field}\"", json);
        }

        Record("package", "changed");
        var recordJson = JsonSerializer.Serialize(OperationLog.Page().Records[0]);
        foreach (var field in new[] { "seq", "id", "module", "outcome", "dry_run", "params", "identity",
                                      "started_at", "duration_ms", "changed", "message", "evidence" })
        {
            Assert.Contains($"\"{field}\"", recordJson);
        }
    }
}

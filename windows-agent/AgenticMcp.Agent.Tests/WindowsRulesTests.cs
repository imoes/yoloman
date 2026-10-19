using System.Text.Json;
using AgenticMcp.Agent.Diagnosis;

namespace AgenticMcp.Agent.Tests;

/// <summary>
/// The Windows rules over snapshots. Every case is also a contract test: the document must hold
/// (<see cref="Validator"/>) and round-trip as JSON. The snapshots are written the way the SCM and the event log
/// report — EventData with <c>%%</c> insertion strings, the DISPLAY name in the first field, German-locale safe.
/// </summary>
public class WindowsRulesTests
{
    private static readonly DateTime T0 = new(2026, 10, 17, 14, 0, 0, DateTimeKind.Utc);

    private static WinServiceSnapshot Snap(Action<WinServiceSnapshot>? mod = null)
    {
        var s = new WinServiceSnapshot
        {
            Name = "yoloman-probe", Exists = true, DisplayName = "yoloman probe", CollectedAt = T0,
            Config = new WinServiceConfig
            {
                BinaryPathName = @"C:\probe\ProbeService.exe", StartType = "demand", ServiceStartName = "LocalSystem",
            },
            Status = new WinServiceStatus { CurrentState = "stopped", Win32ExitCode = 0 },
            Image = new WinImage { Path = @"C:\probe\ProbeService.exe", Exists = true },
        };
        mod?.Invoke(s);
        return s;
    }

    private static WinEvent Scm(int id, long rec, params string[] data) => new()
    {
        Log = "System", EventId = id, RecordId = rec, Time = T0.AddSeconds(-30), Provider = "Service Control Manager",
        Data = [.. data],
    };

    private static DiagnosisDocument Run(WinServiceSnapshot s)
    {
        var d = WindowsRules.Diagnose(s, "t", "bossman-wintest");
        var json = JsonSerializer.Serialize(d);
        Assert.Empty(Validator.Validate(JsonSerializer.Deserialize<DiagnosisDocument>(json)!));
        return d;
    }

    private static string Lead(DiagnosisDocument d) =>
        d.Findings.Count == 0 ? d.Status : $"{d.Findings[0].RuleId}/{d.Findings[0].Certainty}";

    private static Incident Crash(DateTime at, int pid = 1234) =>
        new(IncidentKind.ImageCrash, at, pid, @"C:\probe\ProbeService.exe", Detail: "exit status 0xC0000005");

    [Fact]
    public void RecentIncidentIsListedAfterThePresentCause()
    {
        var d = Run(Snap(s =>
        {
            s.Config!.StartType = "disabled";
            s.RecentIncidents = [Crash(T0.AddMinutes(-5))];
        }));
        // The present cause leads; the past incident is extra context, ranked after it, and never above Likely.
        Assert.Equal("svc.disabled/Proven", Lead(d));
        var inc = d.Findings.Single(f => f.RuleId == "svc.recent_incident");
        Assert.Equal(Certainty.Likely, inc.Certainty);
        Assert.Equal("etw:image-crash:1234:" + Unix(T0.AddMinutes(-5)), inc.EvidenceIds.Single());
        Assert.Contains(d.Evidence, e => e.Id == inc.EvidenceIds[0] && e.Source == "etw-incident-ring");
    }

    [Fact]
    public void ARunningServiceStillReportsAPastCrash()
    {
        var d = Run(Snap(s =>
        {
            s.Status!.CurrentState = "running";
            s.RecentIncidents = [Crash(T0.AddMinutes(-2))];
        }));
        var inc = d.Findings.Single(f => f.RuleId == "svc.recent_incident");
        Assert.Equal(Certainty.Likely, inc.Certainty);
        Assert.Null(inc.Precedent);   // a historical incident does not attach a precedent of its own
    }

    [Fact]
    public void NoIncidentNoFinding()
    {
        var d = Run(Snap(s => s.Config!.StartType = "disabled"));
        Assert.DoesNotContain(d.Findings, f => f.RuleId == "svc.recent_incident");
    }

    private static long Unix(DateTime at) =>
        new DateTimeOffset(DateTime.SpecifyKind(at, DateTimeKind.Utc)).ToUnixTimeMilliseconds();

    [Fact]
    public void NotInstalled() =>
        Assert.Equal("svc.not_installed/Proven", Lead(Run(new WinServiceSnapshot
        { Name = "nosuch", Exists = false, OpenError = 1060, CollectedAt = T0 })));

    [Fact]
    public void Disabled()
    {
        var d = Run(Snap(s => s.Config!.StartType = "disabled"));
        Assert.Equal("svc.disabled/Proven", Lead(d));
        Assert.Equal("demand", d.Findings[0].Remedy!.After!.GetValue<string>());
    }

    [Fact]
    public void ImageMissingAndItsEvent()
    {
        var d = Run(Snap(s =>
        {
            s.Image!.Exists = false;
            s.Events = [Scm(7000, 11, "yoloman probe", "%%2")];
        }));
        Assert.Equal("svc.image_missing/Proven", Lead(d));
        Assert.Contains("evt:System:7000:11", d.Findings[0].EvidenceIds);
    }

    [Fact]
    public void UnquotedPathWithASpaceIsLikely_AndTheIdCarriesNoSpace()
    {
        var d = Run(Snap(s =>
        {
            s.Image = new WinImage { Path = @"C:\Program Files\probe\ProbeService.exe", Exists = false, UnquotedWithSpace = true };
            s.Config!.BinaryPathName = @"C:\Program Files\probe\ProbeService.exe";
        }));
        Assert.Contains(d.Findings, f => f.RuleId == "svc.image_path_unquoted" && f.Certainty == Certainty.Likely);
        Assert.Contains(d.Evidence, e => e.Id == @"file:stat:C:\Program%20Files\probe\ProbeService.exe");
    }

    [Fact]
    public void LogonRightMissingIsProvenByError1385()
    {
        var d = Run(Snap(s =>
        {
            s.Config!.ServiceStartName = @".\probeuser";
            s.Status!.Win32ExitCode = 1069;
            s.Events = [Scm(7038, 12, "yoloman probe", @".\probeuser", "%%1385")];
        }));
        Assert.Equal("svc.logon_right_missing/Proven", Lead(d));
        Assert.Equal(@"SeServiceLogonRight@.\probeuser", d.Findings[0].Remedy!.Target.Id);
    }

    [Theory]
    [InlineData("%%1332", "svc.account_missing/Proven")]
    [InlineData("%%1331", "svc.logon_failed/Proven")]
    [InlineData("%%1326", "svc.logon_failed/Proven")]
    public void LogonFailuresByTheirCode(string code, string want) =>
        Assert.Equal(want, Lead(Run(Snap(s =>
        {
            s.Config!.ServiceStartName = @".\probeuser";
            s.Status!.Win32ExitCode = 1069;
            s.Events = [Scm(7038, 13, "yoloman probe", @".\probeuser", code)];
        }))));

    [Fact]
    public void DependencyPointsAtTheDeepestBrokenLinkAndRepairsIt()
    {
        var d = Run(Snap(s =>
        {
            s.Config!.Dependencies = ["probe-mid"];
            s.Dependencies =
            [
                new WinDependency { Name = "probe-mid", Via = ["yoloman-probe"], Depth = 1, Exists = true, StartType = "demand", CurrentState = "stopped", Win32ExitCode = 1068 },
                new WinDependency { Name = "probe-base", Via = ["yoloman-probe", "probe-mid"], Depth = 2, Exists = true, StartType = "disabled", CurrentState = "stopped", Win32ExitCode = 1077 },
            ];
            s.Events = [Scm(7001, 14, "yoloman probe", "probe mid", "%%1068")];
        }));
        var f = d.Findings[0];
        Assert.Equal("svc.dependency_failed", f.RuleId);
        Assert.Contains("probe-base (via probe-mid → probe-base), is disabled", f.Claim);
        Assert.Equal("probe-base", f.Remedy!.Target.Id);
    }

    [Fact]
    public void TimeoutWithoutCrash() =>
        Assert.Equal("svc.timeout/Proven", Lead(Run(Snap(s =>
        {
            s.Status!.Win32ExitCode = 1053;
            s.Events = [Scm(7009, 15, "30000", "yoloman probe"), Scm(7000, 16, "yoloman probe", "%%1053")];
        }))));

    [Fact]
    public void CrashWithAnApplicationErrorIsProven()
    {
        var d = Run(Snap(s =>
        {
            s.Status!.Win32ExitCode = 1067;
            s.Events =
            [
                Scm(7034, 17, "yoloman probe", "1"),
                new WinEvent { Log = "Application", EventId = 1000, RecordId = 900, Time = T0.AddSeconds(-31), Provider = "Application Error",
                    Data = ["ProbeService.exe", "1.0.0.0", "0", "ntdll.dll", "10.0", "0", "c0000005"] },
            ];
        }));
        Assert.Equal("svc.crash/Proven", Lead(d));
        Assert.Contains("evt:Application:1000:900", d.Findings[0].EvidenceIds);
    }

    [Fact]
    public void ACrashWithoutApplicationErrorIsLikely() =>
        Assert.Equal("svc.crash/Likely", Lead(Run(Snap(s =>
        {
            s.Status!.Win32ExitCode = 1067;
            s.Events = [Scm(7034, 18, "yoloman probe", "1")];
        }))));

    [Fact]
    public void OwnExitCode()
    {
        var d = Run(Snap(s => { s.Status!.Win32ExitCode = 1066; s.Status.ServiceSpecificExitCode = 42; }));
        Assert.Equal("svc.exits_immediately/Proven", Lead(d));
        Assert.Contains("42", d.Findings[0].Claim);
    }

    [Fact]
    public void NeverStartedSinceBootIsStoppedCleanly() =>
        Assert.Equal("svc.stopped_cleanly/Proven", Lead(Run(Snap(s => s.Status!.Win32ExitCode = 1077))));

    [Fact]
    public void AnUnexpectedEndWithoutAnyEventIsUnknownWithItsGap()
    {
        var d = Run(Snap(s => { s.Status!.Win32ExitCode = 1067; s.SystemLogOldest = T0.AddMinutes(-5); }));
        Assert.Equal("svc.unexplained/Unknown", Lead(d));
        Assert.Contains("not measurable", d.Findings[0].Gap);
        Assert.Contains(d.Evidence, e => e.Id == "evtquery:System:yoloman-probe");
    }

    [Fact]
    public void ARunningServiceHasNoFinding()
    {
        var d = Run(Snap(s => s.Status!.CurrentState = "running"));
        Assert.Equal(Status.Running, d.Status);
        Assert.Empty(d.Findings);
    }

    [Fact]
    public void EventsOfOtherServicesAreNotEvidence()
    {
        var d = Run(Snap(s =>
        {
            s.Status!.Win32ExitCode = 1077;
            s.Events = [Scm(7000, 19, "Some other service", "%%2")];
        }));
        Assert.DoesNotContain(d.Evidence, e => e.Id.StartsWith("evt:"));
        Assert.Equal("svc.stopped_cleanly/Proven", Lead(d));
    }

    // --- as measured on bossman-wintest (Server 2022): Win32ExitCode is 0 again after a failed start ---

    [Fact]
    public void ATimeoutIsReadFromEvent7000WhenTheStatusSaysZero() =>
        Assert.Equal("svc.timeout/Proven", Lead(Run(Snap(s =>
            s.Events = [Scm(7000, 57485, "yoloman-probe", "%%1053")]))));

    [Fact]
    public void Event7041IsTheMissingLogonRight()
    {
        var d = Run(Snap(s =>
        {
            s.Config!.ServiceStartName = @".\yoloman-probeuser";
            s.Events = [Scm(7041, 57488, "yoloman-probe", @".\yoloman-probeuser"), Scm(7000, 57489, "yoloman-probe", "%%1069")];
        }));
        Assert.Equal("svc.logon_right_missing/Proven", Lead(d));
        Assert.Equal(["evt:System:7041:57488", "evt:System:7000:57489"], d.Findings[0].EvidenceIds);
    }

    [Fact]
    public void A1069WithoutAReasonIsALikelyLogonFailure() =>
        Assert.Equal("svc.logon_failed/Likely", Lead(Run(Snap(s =>
            s.Events = [Scm(7000, 57490, "yoloman-probe", "%%1069")]))));

    // --- B6: the account (LookupAccountName, NetUserGetInfo, LSA) and access (AuthzAccessCheck) ---

    private static WinAccount Local(Action<WinAccount>? mod = null)
    {
        var a = new WinAccount { Name = @".\probeuser", Sid = "S-1-5-21-1-2-3-1004", Kind = "local", Disabled = false,
            LockedOut = false, PasswordExpired = false, ServiceLogonRight = true, DenyServiceLogonRight = false,
            RightsVia = [@"SeServiceLogonRight via HOST\probeuser"] };
        mod?.Invoke(a);
        return a;
    }

    [Fact]
    public void AnUnresolvableAccountIsMissing() =>
        Assert.Equal("svc.account_missing/Proven", Lead(Run(Snap(s =>
        {
            s.Config!.ServiceStartName = @".\gone";
            s.Account = new WinAccount { Name = @".\gone", Kind = "unresolved" };
        }))));

    [Fact]
    public void ADisabledAccountIsLikelyBeforeAStartAndProvenAfterAFailedLogon()
    {
        Assert.Equal("svc.logon_failed/Likely", Lead(Run(Snap(s => s.Account = Local(a => a.Disabled = true)))));
        var d = Run(Snap(s =>
        {
            s.Account = Local(a => a.Disabled = true);
            s.Events = [Scm(7000, 60, "yoloman-probe", "%%1069"), Scm(7038, 61, "yoloman-probe", @".\probeuser", "%%1331")];
        }));
        Assert.Equal("svc.logon_failed/Proven", Lead(d));
        Assert.Single(d.Findings, f => f.RuleId == "svc.logon_failed");
    }

    [Fact]
    public void LsaShowsTheMissingRightWithoutAnyStartAttempt()
    {
        var d = Run(Snap(s => s.Account = Local(a => { a.ServiceLogonRight = false; a.RightsVia = []; })));
        Assert.Equal("svc.logon_right_missing/Proven", Lead(d));
        Assert.Equal(["lsa:rights:S-1-5-21-1-2-3-1004"], d.Findings[0].EvidenceIds);
    }

    [Fact]
    public void AccessDeniedNamesTheDenyingAceAndOffersTheAclRepair()
    {
        var d = Run(Snap(s =>
        {
            s.Account = Local();
            s.Access = [new WinAccess { Path = @"C:\probe\ProbeService.exe", Sid = "S-1-5-21-1-2-3-1004", Desired = "execute+read",
                Granted = false, DenyingAce = @"Deny ReadAndExecute for HOST\probeuser", Sddl = "D:(D;;0x1200a9;;;S-1-5-21-1-2-3-1004)" }];
        }));
        var f = d.Findings[0];
        Assert.Equal("svc.access_denied/Proven", Lead(d));
        Assert.Contains("Deny ReadAndExecute", f.Claim);
        Assert.Equal("file_acl", f.Remedy!.Target.Kind);
    }

    [Fact]
    public void WhatCouldNotBeReadAboutTheAccountIsAGap()
    {
        var d = Run(Snap(s =>
        {
            s.Status!.Win32ExitCode = 1077;
            s.Account = new WinAccount { Name = @"NT SERVICE\probe", Kind = "virtual", Sid = "S-1-5-80-1",
                Gap = "a virtual service account has no SAM entry" };
        }));
        Assert.Contains(d.Gaps, g => g.What.Contains(@"NT SERVICE\probe"));
    }

    // --- B7: precedent — the newest change before the failure ---

    private static WinEvent At(WinEvent e, int secondsBeforeT0) { e.Time = T0.AddSeconds(-secondsBeforeT0); return e; }

    private static WinEvent Host(string provider, int id, long rec, int secondsBeforeT0, params string[] data) => new()
    {
        Log = provider == "MsiInstaller" ? "Application" : "System", EventId = id, RecordId = rec,
        Time = T0.AddSeconds(-secondsBeforeT0), Provider = provider, Data = [.. data],
    };

    [Fact]
    public void TheStartTypeChangeBeforeTheFailureIsThePrecedent()
    {
        var d = Run(Snap(s =>
        {
            s.Events =
            [
                At(Scm(7045, 50, "yoloman probe", @"C:\probe\ProbeService.exe", "Dienst im Benutzermodus", "Bei Bedarf starten", "LocalSystem"), 600),
                At(Scm(7040, 51, "yoloman probe", "Bei Bedarf starten", "Deaktiviert", "yoloman-probe"), 120),
                At(Scm(7000, 52, "yoloman probe", "%%1058"), 30),
            ];
            s.KeyLastWrite = T0.AddSeconds(-121);
        }));
        var p = d.Findings[0].Precedent!;
        Assert.Equal("evt:System:7040:51", p.EvidenceId);
        Assert.Equal(90, p.GapSeconds);
        Assert.Contains("Deaktiviert", p.Change);
    }

    [Fact]
    public void TheImageCopiedOverIsThePrecedentByItsCreationTimeNotItsWriteTime()
    {
        var d = Run(Snap(s =>
        {
            s.Status!.Win32ExitCode = 1067;
            s.Image!.Written = T0.AddDays(-200);      // the time inside the package
            s.Image.Created = T0.AddSeconds(-300);     // the copy onto this host
            s.KeyLastWrite = T0.AddDays(-30);
        }));
        var p = d.Findings[0].Precedent!;
        Assert.Equal(@"file:changed:C:\probe\ProbeService.exe", p.EvidenceId);
        Assert.Equal(300, p.GapSeconds);
    }

    [Fact]
    public void AHostUpdateIsThePrecedentOnlyWithoutAChangeOfTheService()
    {
        var d = Run(Snap(s =>
        {
            s.Status!.Win32ExitCode = 1067;
            s.KeyLastWrite = T0.AddDays(-30);
            s.Events =
            [
                Host("Microsoft-Windows-WindowsUpdateClient", 19, 900, 3600, "2026-10 Cumulative Update for Microsoft server operating system version 21H2 for x64-based Systems (KB5066782)"),
                Host("Microsoft-Windows-WindowsUpdateClient", 19, 901, 600, "Security Intelligence Update for Microsoft Defender Antivirus - KB2267602 (Version 1.439.1.0)"),
                Host("MsiInstaller", 1033, 902, 30 * 86400, "Old Product", "1.0", "1031", "0", "Vendor"),
            ];
        }));
        var p = d.Findings[0].Precedent!;
        Assert.Equal("evt:System:19:900", p.EvidenceId);
        Assert.Contains("KB5066782", p.Change);
        Assert.DoesNotContain(d.Evidence, e => e.Id.EndsWith(":901") || e.Id.EndsWith(":902"));
    }

    [Fact]
    public void NothingChangedInTheWindowIsNoPrecedent()
    {
        var d = Run(Snap(s =>
        {
            s.Status!.Win32ExitCode = 1067;
            s.KeyLastWrite = T0.AddDays(-30);
            s.Image!.Created = s.Image.Written = T0.AddDays(-90);
        }));
        Assert.Null(d.Findings[0].Precedent);
        Assert.Contains(d.Timeline, x => x.EvidenceId == "reg:lastwrite:yoloman-probe");
    }

    [Fact]
    public void TheFailedDependencysKeyChangeIsAPrecedentToo()
    {
        var d = Run(Snap(s =>
        {
            s.Config!.Dependencies = ["yoloman-base"];
            s.Dependencies = [new WinDependency { Name = "yoloman-base", Depth = 1, Via = ["yoloman-probe"], Exists = true,
                StartType = "disabled", CurrentState = "stopped", KeyLastWrite = T0.AddSeconds(-81) }];
            s.Events = [At(Scm(7001, 70, "yoloman probe", "yoloman base", "%%1058"), 0)];
            s.KeyLastWrite = T0.AddDays(-2);
        }));
        Assert.Equal("svc.dependency_failed", d.Findings[0].RuleId);
        Assert.Equal("reg:lastwrite:yoloman-base", d.Findings[0].Precedent!.EvidenceId);
        Assert.Equal(81, d.Findings[0].Precedent!.GapSeconds);
    }

    [Fact]
    public void ARightGrantedSinceTheFailedStartIsNoLongerTheCause()
    {
        var d = Run(Snap(s =>
        {
            s.Account = Local();   // LSA: SeServiceLogonRight held now
            s.Events = [Scm(7041, 80, "yoloman-probe", @".\probeuser"), Scm(7000, 81, "yoloman probe", "%%1069")];
        }));
        Assert.DoesNotContain(d.Findings, f => f.RuleId == "svc.logon_right_missing");
        Assert.Equal("svc.logon_failed/Likely", Lead(d));
        Assert.Contains("no longer holds", d.Findings[0].Claim);
        Assert.Contains("lsa:rights:S-1-5-21-1-2-3-1004", d.Findings[0].EvidenceIds);
    }

    [Fact]
    public void AStartPendingForMinutesWithoutProgressHangs()
    {
        var d = Run(Snap(s => s.Status = new WinServiceStatus { CurrentState = "start_pending", ProcessId = 5024, ProcessStarted = T0.AddSeconds(-240) }));
        Assert.Equal("svc.timeout/Likely", Lead(d));
        Assert.Contains("start-pending for 240 s", d.Findings[0].Claim);
        Assert.Equal("starting", d.Status);
        // a young start (or one whose wait hint still covers it) is just starting
        Assert.Empty(Run(Snap(s => s.Status = new WinServiceStatus { CurrentState = "start_pending", ProcessStarted = T0.AddSeconds(-10) })).Findings);
        Assert.Empty(Run(Snap(s => s.Status = new WinServiceStatus { CurrentState = "start_pending", ProcessStarted = T0.AddSeconds(-60), WaitHintMs = 120000, CheckPoint = 3 })).Findings);
    }

    // --- Security 4625: Windows' own reason for a failed service logon (measured on bossman-wintest) ---

    private static WinEvent Sec4625(long rec, int secsBeforeT0, string user, uint status, uint sub)
    {
        var data = Enumerable.Repeat("-", 21).ToList();
        // as EventRecord.Properties delivers them: NTSTATUS as a SIGNED number (measured: "-1073741718")
        data[5] = user; data[6] = "WIN-U0PPS5QVRP1"; data[7] = unchecked((int)status).ToString(); data[9] = unchecked((int)sub).ToString(); data[10] = "5";
        data[18] = @"C:\Windows\System32\services.exe";
        return new WinEvent { Log = "Security", EventId = 4625, RecordId = rec, Time = T0.AddSeconds(-secsBeforeT0),
            Provider = "Microsoft-Windows-Security-Auditing", Data = data };
    }

    [Fact]
    public void AWrongStoredPasswordIsProvenByTheSecurityLog()
    {
        var d = Run(Snap(s =>
        {
            s.Account = Local();
            s.Events = [At(Scm(7000, 90, "yoloman probe", "%%1069"), 30), Sec4625(91, 31, "probeuser", 0xC000006D, 0xC000006A)];
        }));
        Assert.Equal("svc.logon_failed/Proven", Lead(d));
        Assert.Contains("the password stored for the service is wrong", d.Findings[0].Claim);
        Assert.Contains("SubStatus 0xC000006A", d.Findings[0].Claim);
        Assert.Contains("evt:Security:4625:91", d.Findings[0].EvidenceIds);
    }

    [Fact]
    public void TheDisabledAccountCitesWindowsReasonToo()
    {
        var d = Run(Snap(s =>
        {
            s.Account = Local(a => a.Disabled = true);
            s.Events = [At(Scm(7000, 92, "yoloman probe", "%%1069"), 30), Sec4625(93, 30, "probeuser", 0xC000006E, 0xC0000072)];
        }));
        Assert.Equal("svc.logon_failed/Proven", Lead(d));
        Assert.Contains("SubStatus 0xC0000072 — the account is disabled", d.Findings[0].Claim);
    }

    [Fact]
    public void AnOldLogonFailureIsNotTheReasonForTheLastStart()
    {
        var d = Run(Snap(s =>
        {
            s.Account = Local();
            s.Events = [At(Scm(7000, 94, "yoloman probe", "%%1069"), 30), Sec4625(95, 3600, "probeuser", 0xC000006D, 0xC000006A)];
        }));
        Assert.Equal("svc.logon_failed/Likely", Lead(d));                  // the reason of an hour ago is not claimed
    }

    [Fact]
    public void WithoutLogonAuditingTheMissingReasonIsAGap()
    {
        var d = Run(Snap(s =>
        {
            s.Account = Local();
            s.LogonFailureAudited = false;
            s.Events = [At(Scm(7000, 96, "yoloman probe", "%%1069"), 30)];
        }));
        Assert.Contains(d.Gaps, g => g.Why.Contains("does not audit failed logons"));
    }

    // --- B14: wait chains ---

    private static WinThreadChain Thr(int tid, bool cycle, params WinWaitNode[] nodes) => new() { ThreadId = tid, IsCycle = cycle, Nodes = [.. nodes] };
    private static WinWaitNode T(int tid, string status, long wait = 0) => new() { Type = "Thread", Status = status, ProcessId = 5024, ThreadId = tid, WaitTimeMs = wait };
    private static WinWaitNode M(string name, string status) => new() { Type = "Mutex", Status = status, Name = name };

    [Fact]
    public void AClosedWaitChainIsAProvenDeadlock()
    {
        var d = Run(Snap(s =>
        {
            s.Status = new WinServiceStatus { CurrentState = "start_pending", ProcessId = 5024, ProcessStarted = T0.AddSeconds(-90) };
            s.WaitChain = new WinWaitChain { ProcessId = 5024, Threads =
            [
                Thr(100, false, T(100, "Blocked", 90000), T(200, "Blocked")),
                Thr(200, true, T(200, "Blocked", 85000), M(@"\BaseNamedObjects\yoloman-b", "Owned"), T(300, "Blocked"), M(@"\BaseNamedObjects\yoloman-a", "Owned"), T(200, "Blocked")),
                Thr(400, false, T(400, "Running")),
            ] };
        }));
        Assert.Equal("svc.deadlock/Proven", Lead(d));
        Assert.Contains("a cycle", d.Findings[0].Claim);
        Assert.Contains("wct:5024:200", d.Findings[0].EvidenceIds);
        Assert.Contains(d.Findings, f => f.RuleId == "svc.timeout" && f.EvidenceIds.Contains("wct:5024:100"));
        Assert.DoesNotContain(d.Evidence, e => e.Id == "wct:5024:400");      // a running thread is no evidence of a hang
    }

    [Fact]
    public void AManagedHangWithoutALockOwnerIsNamedAsWctsLimit()
    {
        var d = Run(Snap(s =>
        {
            s.Status = new WinServiceStatus { CurrentState = "start_pending", ProcessId = 5024, ProcessStarted = T0.AddSeconds(-90) };
            s.WaitChain = new WinWaitChain { ProcessId = 5024, Runtime = ".NET", Threads =
            [
                Thr(100, false, T(100, "Blocked", 90000)),   // blocked, but on nothing WCT can see
                Thr(200, false, T(200, "Running")),
            ] };
        }));
        Assert.Equal("svc.timeout/Likely", Lead(d));
        Assert.Contains(d.Gaps, g => g.Why.Contains("managed wait") && g.Why.Contains("Mutex.WaitOne"));
    }

    [Fact]
    public void AnUnreadableWaitChainIsAGap()
    {
        var d = Run(Snap(s =>
        {
            s.Status = new WinServiceStatus { CurrentState = "start_pending", ProcessId = 5024, ProcessStarted = T0.AddSeconds(-90) };
            s.WaitChain = new WinWaitChain { ProcessId = 5024, Gap = "OpenThreadWaitChainSession failed: access denied" };
        }));
        Assert.Equal("svc.timeout/Likely", Lead(d));
        Assert.Contains(d.Gaps, g => g.Why.Contains("access denied"));
    }

    // --- B14 step 2: where it crashed (event data in the format measured on bossman-wintest) ---

    private static WinEvent App(string provider, int id, long rec, params string[] data) => new()
    { Log = "Application", EventId = id, RecordId = rec, Time = T0.AddSeconds(-20), Provider = provider, Data = [.. data] };

    private static WinServiceSnapshot Crashed(WinCrashFrame? frame) => Snap(s =>
    {
        s.Status!.Win32ExitCode = 1067;
        s.Events =
        [
            Scm(7034, 97, "yoloman probe", "1"),
            App("Application Error", 1000, 98, "ProbeService.exe", "1.0.0.0", "6a63853d", "KERNELBASE.dll", "10.0.20348.5756", "379e5a64",
                "e0434352", "000000000003f22c", "1668", "01dd", @"C:\probe\ProbeService.exe", @"C:\Windows\System32\KERNELBASE.dll", "g", "", ""),
            App(".NET Runtime", 1026, 99, "Application: ProbeService.exe\nException Info: System.InvalidOperationException: ProbeService: crash on purpose (--mode=crash)\r\n   at ProbeService.<>c.<OnStart>b__6_0()\r\n   at System.Threading.Thread.StartCallback()\n"),
        ];
        s.CrashFrame = frame;
    });

    [Fact]
    public void TheCrashNamesItsFunctionAndManagedFrame()
    {
        var d = Run(Crashed(new WinCrashFrame { EventRecord = 98, Module = "KERNELBASE.dll", Offset = 0x3f22c, Exception = 0xE0434352,
            Function = "KERNELBASE!RaiseException", Displacement = 0x6c, Pdb = "kernelbase.pdb", PdbId = "ABC1", ModuleVersionNow = "10.0.20348.5756",
            SymbolSource = "Microsoft symbol server" }));
        var f = d.Findings[0];
        Assert.Equal("svc.crash/Proven", Lead(d));
        Assert.Contains(".NET exception (0xE0434352) in KERNELBASE!RaiseException+0x6C", f.Claim);
        Assert.Contains("unhandled System.InvalidOperationException: ProbeService: crash on purpose (--mode=crash) at ProbeService.<>c.<OnStart>b__6_0()", f.Claim);
        Assert.Contains("sym:KERNELBASE.dll:3f22c", f.EvidenceIds);
    }

    [Fact]
    public void AnUnresolvableCrashFrameIsAGap()
    {
        var d = Run(Crashed(new WinCrashFrame { Module = "KERNELBASE.dll", Offset = 0x3f22c,
            Gap = "KERNELBASE.dll was build 20348.5622 at the crash and is 20348.5756 now" }));
        Assert.Equal("svc.crash/Proven", Lead(d));
        Assert.Contains(d.Gaps, g => g.Why.Contains("at the crash and is"));
    }

    [Fact]
    public void AnotherApplicationsCrashIsNoEvidence()
    {
        var d = Run(Snap(s =>
        {
            s.Status!.Win32ExitCode = 1067;
            s.Events = [App("Application Error", 1000, 120, "dwm.exe", "10.0", "x", "ism.dll", "10.0", "y", "c0000409", "0f2d4b", "4b0", "01dd",
                @"C:\Windows\system32\dwm.exe", @"C:\Windows\SYSTEM32\ism.dll", "g", "", "")];
        }));
        Assert.DoesNotContain(d.Evidence, e => e.Id == "evt:Application:1000:120");
    }

    // --- B14: an application-control policy blocked the image ---

    private static WinEvent Block(string provider, int id, long rec, string path) => new()
    { Log = provider, EventId = id, RecordId = rec, Time = T0.AddSeconds(-20), Provider = provider,
      Data = ["Policy", "{rule}", "Rule", @"HOST\u", "1234", path, "hash", "fqbn"] };

    [Fact]
    public void AnAppLockerBlockOfTheImageIsProvenWithTheSignatureAsContext()
    {
        var d = Run(Snap(s =>
        {
            s.Image = new WinImage { Path = @"C:\probe\ProbeService.exe", Exists = true, Signature = "untrusted: the signing certificate has expired" };
            s.Events = [Block("Microsoft-Windows-AppLocker/EXE and DLL", 8004, 70, @"C:\probe\ProbeService.exe")];
        }));
        Assert.Equal("svc.blocked_by_policy/Proven", Lead(d));
        Assert.Contains("AppLocker blocked its program", d.Findings[0].Claim);
        Assert.Contains("the signing certificate has expired", d.Findings[0].Claim);
        Assert.Contains(@"sig:C:\probe\ProbeService.exe", d.Findings[0].EvidenceIds);
        Assert.Contains(d.Evidence, e => e.Id.StartsWith("evt:Microsoft-Windows-AppLocker"));
    }

    [Fact]
    public void ACodeIntegrityBlockIsProvenAndAnAuditEventIsNotAFailure()
    {
        var enforce = Run(Snap(s =>
        {
            s.Image = new WinImage { Path = @"C:\probe\ProbeService.exe", Exists = true, Signature = "valid", Signer = "CN=Me" };
            s.Events = [Block("Microsoft-Windows-CodeIntegrity/Operational", 3077, 71, @"C:\probe\ProbeService.exe")];
        }));
        Assert.Equal("svc.blocked_by_policy/Proven", Lead(enforce));
        Assert.DoesNotContain("it is", enforce.Findings[0].Claim);   // a valid signature adds no "(it is …)"

        var audit = Run(Snap(s =>
        {
            s.Status!.Win32ExitCode = 1067;
            s.Image = new WinImage { Path = @"C:\probe\ProbeService.exe", Exists = true, Signature = "unsigned" };
            s.Events = [Block("Microsoft-Windows-AppLocker/EXE and DLL", 8003, 72, @"C:\probe\ProbeService.exe")];
        }));
        Assert.DoesNotContain(audit.Findings, f => f.RuleId == "svc.blocked_by_policy");   // 8003 = would-have-blocked, it ran
    }

    [Fact]
    public void TheImageSignatureIsEvidenceEvenWithoutAPolicyBlock()
    {
        var d = Run(Snap(s => { s.Config!.StartType = "disabled"; s.Image = new WinImage { Path = @"C:\probe\ProbeService.exe", Exists = true, Signature = "valid", Signer = "CN=Microsoft" }; }));
        Assert.Contains(d.Evidence, e => e.Id == @"sig:C:\probe\ProbeService.exe" && e.Fact.Contains("signed and trusted"));
    }
}

using System.Text.Json.Nodes;

namespace AgenticMcp.Agent.Diagnosis;

/// <summary>
/// The Windows rules of "why does this service not start" (configs/diagnosis_rules.json) over a collected
/// <see cref="WinServiceSnapshot"/>. Events are matched on their id and their EventData, never on message text — the
/// host may speak German — and the SCM names a service in most events by its DISPLAY name (localized), so both names
/// are compared. Error codes arrive in EventData as <c>%%1058</c> insertion strings and are read as numbers.
/// </summary>
public static class WindowsRules
{
    /// <summary>The Win32 errors these rules name, in our words (FormatMessage would answer in the host's language).</summary>
    public static readonly IReadOnlyDictionary<int, string> Win32 = new Dictionary<int, string>
    {
        [0] = "the operation completed successfully",
        [2] = "the system cannot find the file specified",
        [3] = "the system cannot find the path specified",
        [5] = "access is denied",
        [193] = "the program is not a valid Win32 application",
        [1053] = "the service did not respond to the start or control request in a timely fashion",
        [1058] = "the service cannot be started because it is disabled",
        [1060] = "the specified service does not exist",
        [1066] = "the service has returned a service-specific error code",
        [1067] = "the process terminated unexpectedly",
        [1068] = "the dependency service or group failed to start",
        [1069] = "the service did not start due to a logon failure",
        [1075] = "the dependency service does not exist or has been marked for deletion",
        [1077] = "no attempts to start the service have been made since the last boot",
        [1326] = "the user name or password is incorrect",
        [1330] = "the password of this account has expired",
        [1331] = "this user cannot sign in because the account is disabled",
        [1332] = "no mapping between account names and security IDs was done",
        [1385] = "the user has not been granted the requested logon type (log on as a service) at this computer",
        [1909] = "the referenced account is currently locked out",
    };

    private static string Err(int code) => Win32.TryGetValue(code, out var t) ? $"{code} ({t})" : code.ToString();

    private static readonly HashSet<int> ScmFailureEvents = [7000, 7001, 7003, 7009, 7011, 7022, 7023, 7024, 7031, 7034, 7038, 7041];

    public static DiagnosisDocument Diagnose(WinServiceSnapshot s, string id, string host)
    {
        var b = new Builder(id, host, "windows", new Target { Name = s.Name, DisplayName = s.DisplayName }, s.CollectedAt);
        if (!s.Exists)
        {
            var open = b.Evidence(new Evidence
            {
                Id = $"scm:open:{Builder.Key(s.Name)}", Source = "OpenService",
                Fact = $"OpenService({s.Name}) failed with error {Err(s.OpenError)}.",
                Raw = new JsonObject { ["error"] = s.OpenError },
            });
            if (s.OpenError == 1060)
                b.Find(new Finding
                {
                    RuleId = "svc.not_installed", Certainty = Certainty.Proven, EvidenceIds = [open],
                    Claim = $"There is no service named {s.Name} on this host.",
                });
            else
                b.Unexplained([open], $"The service control manager refused to open {s.Name} (error {Err(s.OpenError)}), so its configuration and state could not be read.");
            return b.Build(s.OpenError == 1060 ? Status.NotFound : Status.Unknown);
        }

        var cfg = s.Config!;
        var st = s.Status!;
        var status = st.CurrentState switch
        {
            "running" => Status.Running,
            "start_pending" => Status.Starting,
            "stopped" => Status.Stopped,
            _ => Status.Unknown,
        };
        var configId = b.Evidence(new Evidence
        {
            Id = $"scm:config:{Builder.Key(s.Name)}", Source = "QueryServiceConfig",
            Fact = ConfigFact(s.Name, cfg),
            Raw = JsonNode.Parse(System.Text.Json.JsonSerializer.Serialize(cfg)),
        });
        var statusId = b.Evidence(new Evidence
        {
            Id = $"scm:status:{Builder.Key(s.Name)}", Source = "QueryServiceStatusEx",
            Fact = $"{s.Name} is {st.CurrentState.Replace('_', ' ')}, Win32ExitCode {Err(st.Win32ExitCode)}"
                   + (st.Win32ExitCode == 1066 ? $", service-specific exit code {st.ServiceSpecificExitCode}" : "")
                   + (st.CurrentState == "start_pending" && st.ProcessStarted is { } ps ? $", start-pending since {Builder.Second(ps):yyyy-MM-ddTHH:mm:ssZ} (checkpoint {st.CheckPoint}, wait hint {st.WaitHintMs} ms)" : "") + ".",
            Raw = JsonNode.Parse(System.Text.Json.JsonSerializer.Serialize(st)),
        });
        string? imageId = null, signatureId = null;
        if (s.Image is { } img)
        {
            imageId = b.Evidence(new Evidence
            {
                Id = $"file:stat:{Builder.Key(img.Path)}", Source = "File.Exists",
                Fact = img.Exists ? $"{img.Path} exists." : $"{img.Path} does not exist.",
                Raw = JsonNode.Parse(System.Text.Json.JsonSerializer.Serialize(img)),
            });
            if (img.Signature is { } sig)
                signatureId = b.Evidence(new Evidence
                {
                    Id = $"sig:{Builder.Key(img.Path)}", Source = "WinVerifyTrust",
                    Fact = sig.StartsWith("valid") ? $"{img.Path} is signed and trusted ({img.Signer})."
                        : sig.StartsWith("no embedded") ? $"{img.Path} has {sig}."
                        : sig == "unsigned" ? $"{img.Path} is not signed."
                        : $"{img.Path}'s signature is {sig}" + (img.Signer is { } sg ? $" ({sg})" : "") + ".",
                    Raw = new JsonObject { ["signature"] = sig, ["signer"] = img.Signer },
                });
        }
        // Events of THIS service: matched on key name or display name in the first data field.
        var mine = s.Events.Where(e => e.Provider == "Service Control Manager" && Names(s).Contains(First(e))).ToList();
        var evIds = new Dictionary<WinEvent, string>();
        foreach (var e in s.Events.OrderBy(e => e.Time))
        {
            if (e.Provider == "Service Control Manager" && !mine.Contains(e)) continue;
            if (HostChange(e)) continue; // only the one that may be the precedent is recorded (below)
            // An application's crash is evidence only for ITS service: before, every crash on the host in 24 h (dwm.exe …)
            // was recorded — 40 to 92 evidences per diagnosis on bossman-wintest, nearly all unrelated.
            if (e.Log == "Application" && !ImageNamed(e, s.Image)) continue;
            evIds[e] = b.Evidence(new Evidence
            {
                Id = $"evt:{e.Log}:{e.EventId}:{e.RecordId}", Source = $"EventLog/{e.Log}", Observed = e.Time,
                Fact = EventFact(e), Raw = JsonNode.Parse(System.Text.Json.JsonSerializer.Serialize(e)),
            });
        }
        if (s.EventError is { } ee) b.Gap("the event log", "reading it failed: " + ee);
        string? acctId = null, rightsId = null;
        var accessIds = new List<(WinAccess a, string id)>();
        if (s.Account is { } ac)
        {
            acctId = b.Evidence(new Evidence
            {
                Id = $"lsa:account:{Builder.Key(ac.Name)}", Source = "LookupAccountName/NetUserGetInfo", Fact = AccountFact(ac),
                Raw = JsonNode.Parse(System.Text.Json.JsonSerializer.Serialize(ac)),
            });
            if (ac.Sid is not null && ac.ServiceLogonRight is not null)
                rightsId = b.Evidence(new Evidence
                {
                    Id = $"lsa:rights:{ac.Sid}", Source = "LsaEnumerateAccountRights", Fact = RightsFact(ac),
                    Raw = new JsonObject { ["sid"] = ac.Sid, ["service_logon_right"] = ac.ServiceLogonRight, ["deny_service_logon_right"] = ac.DenyServiceLogonRight, ["via"] = new JsonArray(ac.RightsVia.Select(v => (JsonNode)v).ToArray()) },
                });
            if (ac.Gap is { } g) b.Gap($"the service account {ac.Name}", g);
            foreach (var a in s.Access)
            {
                if (a.Gap is { } ag) { b.Gap($"access of {ac.Name} to {a.Path}", ag); continue; }
                accessIds.Add((a, b.Evidence(new Evidence
                {
                    Id = $"authz:{a.Sid}:{Builder.Key(a.Path)}", Source = "AuthzAccessCheck",
                    Fact = a.Granted == true ? $"{ac.Name} may {a.Desired} {a.Path}." : $"{ac.Name} may NOT {a.Desired} {a.Path}: {a.DenyingAce}.",
                    Raw = JsonNode.Parse(System.Text.Json.JsonSerializer.Serialize(a)),
                })));
            }
        }
        // B7 — the changes before the failure, as evidence and precedent candidates; called before every Build that
        // carries a finding (the stopped path below, and a start that hangs).
        void PrecedeAll(DateTime failedAt)
        {
            // precedent; Builder.Precede names the newest one before the failure: a change of the service or its
            // dependencies when there is one, otherwise a change of the host.
            foreach (var e in mine.Where(e => e.EventId is 7040 or 7045)) b.Change(evIds[e], ChangeText(e), e.Time, hostWide: false);
            void KeyChange(string svc, DateTime? at)
            {
                if (at is not { } w) return;
                var key = $@"HKLM\SYSTEM\CurrentControlSet\Services\{svc}";
                var kid = b.Evidence(new Evidence
                {
                    Id = $"reg:lastwrite:{Builder.Key(svc)}", Source = "RegQueryInfoKey", Observed = w,
                    Fact = $"The service key {key} was last written at {Builder.Second(w):yyyy-MM-ddTHH:mm:ssZ}.",
                    Raw = new JsonObject { ["key"] = key, ["last_write_time"] = Builder.Second(w).ToString("yyyy-MM-ddTHH:mm:ssZ") },
                });
                b.Change(kid, $"the service key of {svc} was changed", w, hostWide: false);
            }
            KeyChange(s.Name, s.KeyLastWrite);
            foreach (var d in s.Dependencies) KeyChange(d.Name, d.KeyLastWrite);
            if (s.Image is { Changed: { } ic } im)
            {
                var fid = b.Evidence(new Evidence
                {
                    Id = $"file:changed:{Builder.Key(im.Path)}", Source = "GetFileTime", Observed = ic,
                    Fact = $"The program {im.Path} last changed on this host at {Builder.Second(ic):yyyy-MM-ddTHH:mm:ssZ} (the later of its creation and last write).",
                    Raw = new JsonObject
                    {
                        ["path"] = im.Path, ["created"] = im.Created?.ToString("yyyy-MM-ddTHH:mm:ssZ"),
                        ["written"] = im.Written?.ToString("yyyy-MM-ddTHH:mm:ssZ"),
                    },
                });
                b.Change(fid, $"the program {im.Path} changed", ic, hostWide: false);
            }
            // Host changes: only the newest before the failure is recorded — a week of updates would bury the evidence.
            // Defender's security-intelligence update (KB2267602) is left out: it installs several times a day, so it
            // would be the "newest change" before nearly every failure and say nothing.
            var hostChange = s.Events.Where(e => HostChange(e) && !e.Data.Any(x => x.Contains("KB2267602", StringComparison.OrdinalIgnoreCase))
                                           && e.Time <= failedAt && failedAt - e.Time <= Builder.PrecedentWindow)
                .OrderByDescending(e => e.Time).FirstOrDefault();
            if (hostChange is not null)
            {
                var hid = b.Evidence(new Evidence
                {
                    Id = $"evt:{hostChange.Log}:{hostChange.EventId}:{hostChange.RecordId}", Source = $"EventLog/{hostChange.Log}", Observed = hostChange.Time,
                    Fact = EventFact(hostChange), Raw = JsonNode.Parse(System.Text.Json.JsonSerializer.Serialize(hostChange)),
                });
                b.Change(hid, ChangeText(hostChange), hostChange.Time, hostWide: true);
            }
            b.Precede(failedAt);
        }
        // B14 — THE WAIT CHAINS of a pending start/stop: each thread that is blocked becomes evidence; a chain Windows marks
        // as a cycle is a deadlock, proven (GetThreadWaitChain's IsCycle), whatever the time says.
        var chainIds = new List<string>();
        if (s.WaitChain is { } wc)
        {
            if (wc.Gap is { } wg) b.Gap($"what the threads of {s.Name} wait on", wg);
            foreach (var th in wc.Threads.Where(x => x.IsCycle || x.Nodes.Any(n => n.Status == "Blocked")))
                chainIds.Add(b.Evidence(new Evidence
                {
                    Id = $"wct:{wc.ProcessId}:{th.ThreadId}", Source = "GetThreadWaitChain",
                    Fact = ChainFact(wc.ProcessId, th),
                    Raw = JsonNode.Parse(System.Text.Json.JsonSerializer.Serialize(th)),
                }));
            var cycles = wc.Threads.Where(x => x.IsCycle).ToList();
            if (cycles.Count > 0)
                b.Find(new Finding
                {
                    RuleId = "svc.deadlock", Certainty = Certainty.Proven,
                    EvidenceIds = [statusId, .. cycles.Select(c => $"wct:{wc.ProcessId}:{c.ThreadId}")],
                    Claim = $"{s.Name} hangs in a deadlock: Windows reports a closed wait chain — {ChainFact(wc.ProcessId, cycles[0])}",
                });
            // No lock owner in the chain but the threads are blocked and the process is .NET: Wait Chain Traversal does not
            // follow managed waits (Mutex.WaitOne, Monitor) — measured. Name that, so an empty chain is not read as "no wait".
            else if (wc.Runtime == ".NET" && wc.Threads.Any(x => x.Nodes.Any(n => n.Status == "Blocked")) && !wc.Threads.Any(HasLockOwner))
                b.Gap($"what {s.Name} is waiting on", "its threads are blocked but the wait chain names no lock owner, and the process "
                    + "is .NET — Wait Chain Traversal cannot follow a managed wait (Mutex.WaitOne, Monitor); a managed stack dump would be needed");
        }
        // A START THAT NEVER ENDS: OnStart hangs, the SCM leaves the service START_PENDING indefinitely and records
        // no event at all (measured on bossman-wintest with the probe service, --mode=hang: 4 minutes, checkpoint 0,
        // wait hint 0, no 7000/7009/7022). The measurement is the time: pending longer than the SCM's start timeout
        // (30 s) plus the service's own wait hint, without progress reported. Likely — hung, or merely very slow.
        if (status == Status.Starting && st.ProcessStarted is { } since)
        {
            var pending = (s.CollectedAt - since).TotalSeconds;
            if (pending > 30 + st.WaitHintMs / 1000.0)
                b.Find(new Finding
                {
                    RuleId = "svc.timeout", Certainty = Certainty.Likely, EvidenceIds = [statusId, .. chainIds],
                    Claim = $"{s.Name} hangs on starting: it has been start-pending for {(int)pending} s (since {Builder.Second(since):yyyy-MM-ddTHH:mm:ssZ}) "
                            + $"without reporting progress (checkpoint {st.CheckPoint}, wait hint {st.WaitHintMs} ms) — longer than the service control manager's 30 s start timeout.",
                });
            PrecedeAll(since);
        }
        if (status is Status.Running or Status.Starting) { AddRecentIncidents(b, s); return b.Build(status); }

        var hit = new List<string>();
        void Add(Finding f) { if (b.Find(f) is null) hit.Add(f.RuleId); }
        // 0. an application-control policy blocked the image from running at all (AppLocker 8004 / Code Integrity 3077,
        // enforcement — audit 8003/3076 means it still ran, so not a start failure). Matched to the image by name.
        var blocks = s.Events.Where(e => e.EventId is 8004 or 3077 && ImageNamed(e, s.Image)).OrderByDescending(e => e.Time).ToList();
        if (blocks.Count > 0)
        {
            var policy = blocks[0].EventId == 8004 ? "AppLocker" : "Windows Defender Application Control (Code Integrity)";
            Add(new Finding
            {
                RuleId = "svc.blocked_by_policy", Certainty = Certainty.Proven,
                EvidenceIds = [statusId, .. blocks.Select(e => evIds[e]), .. (signatureId is { } si ? new[] { si } : [])],
                Claim = $"{s.Name} does not start because {policy} blocked its program {s.Image?.Path}"
                        + (s.Image?.Signature is { } sg && sg.StartsWith("untrusted") ? $" ({sg})" : "") + ".",
            });
        }
        List<string> Ev(params int[] ids) => mine.Where(e => ids.Contains(e.EventId)).OrderByDescending(e => e.Time)
            .Select(e => evIds[e]).ToList();
        int? CodeIn(WinEvent e, int index) => index < e.Data.Count && e.Data[index].StartsWith("%%")
            && int.TryParse(e.Data[index][2..], out var c) ? c : null;
        List<WinEvent> Mine(params int[] ids) => mine.Where(e => ids.Contains(e.EventId)).OrderByDescending(e => e.Time).ToList();

        // THE LAST START ATTEMPT'S ERROR is in event 7000, not in the status: after a failed start the SCM reports
        // Win32ExitCode 0 again (measured on bossman-wintest, Server 2022: a 1053 timeout and a 1069 logon failure
        // both read "stopped, 0" a few seconds later). So the newest 7000 decides alongside Win32ExitCode.
        var e7000 = Mine(7000);
        var lastStart = e7000.FirstOrDefault();
        var startCode = lastStart is null ? null : CodeIn(lastStart, 1);
        bool Code(int c) => st.Win32ExitCode == c || startCode == c;
        List<string> StartEv(int c) => startCode == c && lastStart is not null ? [evIds[lastStart]] : [];
        // 1. disabled
        var disabledEvents = e7000.Where(e => CodeIn(e, 1) == 1058).Select(e => evIds[e]).ToList();
        if (cfg.StartType == "disabled" || disabledEvents.Count > 0)
            Add(new Finding
            {
                RuleId = "svc.disabled", Certainty = Certainty.Proven, EvidenceIds = [configId, .. disabledEvents],
                Claim = $"{s.Name} cannot start because it is disabled (start type Disabled).",
                Remedy = cfg.StartType == "disabled" ? StartTypeRemedy(s.Name, "svc.disabled") : null,
            });
        // 2. image missing / unquoted path
        var notFound = e7000.Where(e => CodeIn(e, 1) is 2 or 3).Select(e => evIds[e]).ToList();
        if (s.Image is { Exists: false } || notFound.Count > 0)
            Add(new Finding
            {
                RuleId = "svc.image_missing", Certainty = Certainty.Proven,
                EvidenceIds = [configId, .. imageId is null ? [] : new[] { imageId }, .. notFound],
                Claim = $"{s.Name} does not start because the program it runs, {s.Image?.Path ?? cfg.BinaryPathName}, does not exist.",
            });
        if (s.Image is { UnquotedWithSpace: true })
            Add(new Finding
            {
                RuleId = "svc.image_path_unquoted", Certainty = Certainty.Likely, EvidenceIds = [configId],
                Claim = $"The image path of {s.Name} contains a space and is not quoted, so Windows may try to run a shorter path first.",
            });
        // 3a. Windows' own reason for a failed service logon: Security 4625 (type 5, services.exe) — only the one that
        // belongs to the LAST start attempt (within 15 s of its 7000), so a fixed account does not keep an old reason.
        var logonFail = s.Events.Where(e => e.Log == "Security" && e.EventId == 4625)
            .Where(e => lastStart is not null && Math.Abs((e.Time - lastStart.Time).TotalSeconds) <= 15)
            .OrderByDescending(e => e.Time).FirstOrDefault();
        var ntStatus = logonFail is null ? null : NtReason(logonFail);
        var failIds = logonFail is null ? new List<string>() : [evIds[logonFail]];
        // 3. logon (7038 carries the LogonUser error in its third field; Win32ExitCode 1069 says logon failed)
        var logon = Mine(7038);
        var logonCode = logon.Select(e => CodeIn(e, 2)).FirstOrDefault(c => c is not null);
        var logonIds = logon.Select(e => evIds[e]).ToList();
        var acct = cfg.ServiceStartName;
        // 7041 IS the missing right: "unable to log on … the user has not been granted the requested logon type"
        // — Server 2022 records it instead of a 7038 with error 1385 (measured on bossman-wintest).
        var e7041 = Ev(7041);
        var lsaMissing = s.Account is { ServiceLogonRight: false } or { DenyServiceLogonRight: true };
        var rightsEv = rightsId is null ? new List<string>() : [rightsId];
        if (s.Account is { Kind: "unresolved" } && acctId is not null && logonCode != 1332)
            Add(new Finding
            {
                RuleId = "svc.account_missing", Certainty = Certainty.Proven, EvidenceIds = [acctId, configId],
                Claim = $"{s.Name} cannot start because its account {acct} does not exist (it does not resolve to a SID).",
            });
        if (s.Account is { } ast && acctId is not null && (ast.Disabled == true || ast.LockedOut == true || ast.PasswordExpired == true))
        {
            var why = ast.Disabled == true ? "is disabled" : ast.LockedOut == true ? "is locked out" : "has an expired password";
            var failedLogon = Code(1069) || logonIds.Count > 0;
            Add(new Finding
            {
                RuleId = "svc.logon_failed", Certainty = failedLogon ? Certainty.Proven : Certainty.Likely,
                EvidenceIds = [acctId, .. logonIds, .. StartEv(1069), .. failIds],
                Claim = (failedLogon ? $"{s.Name} does not start because its account {acct} {why}."
                    : $"{s.Name} will not be able to start: its account {acct} {why}.") + NtNote(ntStatus),
            });
        }
        // The CURRENT measurement beats history: when LSA reads the right as held now, a 7041 / 1385 from an earlier
        // start is a cause that no longer holds (found by the repair probe: granting the right left the rule firing
        // on the old event).
        var rightHeldNow = s.Account is { ServiceLogonRight: true, DenyServiceLogonRight: not true };
        var recordedMissing = e7041.Count > 0 || logonCode == 1385;
        // One finding for the missing right, whichever way it was measured: event 7041, a 7038 with error 1385, or LSA.
        if (lsaMissing || (recordedMissing && !rightHeldNow))
        {
            var ids = new List<string>([.. e7041, .. (logonCode == 1385 ? logonIds : []), .. rightsEv, .. StartEv(1069),
                                        .. (ntStatus?.Code == 0xC000015B ? failIds : [])]);
            if (ids.Count == 0) ids.Add(statusId);
            Add(new Finding
            {
                RuleId = "svc.logon_right_missing", Certainty = Certainty.Proven, EvidenceIds = [.. ids.Distinct()],
                Claim = $"{s.Name} does not start because its account {acct} lacks the right to log on as a service (SeServiceLogonRight).",
                Remedy = RightRemedy(acct),
            });
        }
        else if (logonCode == 1332 && !hit.Contains("svc.account_missing"))
            Add(new Finding
            {
                RuleId = "svc.account_missing", Certainty = Certainty.Proven, EvidenceIds = [configId, .. logonIds],
                Claim = $"{s.Name} does not start because its account {acct} does not exist.",
            });
        else if (recordedMissing && rightHeldNow && rightsId is not null)
            Add(new Finding
            {
                RuleId = "svc.logon_failed", Certainty = Certainty.Likely,
                EvidenceIds = [.. StartEv(1069), .. e7041, .. (logonCode == 1385 ? logonIds : []), rightsId],
                Claim = $"The last start of {s.Name} failed because {acct} could not log on as a service; that cause no longer "
                        + "holds — LSA shows the right to log on as a service granted now. A new start attempt shows whether it runs.",
            });
        else if (hit.Contains("svc.logon_failed") || hit.Contains("svc.account_missing"))
        {
            // already explained by the account itself (disabled, locked, expired, unresolvable) — one finding per cause
        }
        else if (ntStatus is { } nt && Code(1069) && nt.Code == 0xC0000064)
            Add(new Finding
            {
                RuleId = "svc.account_missing", Certainty = Certainty.Proven, EvidenceIds = [configId, .. failIds, .. StartEv(1069)],
                Claim = $"{s.Name} does not start because its account {acct} does not exist." + NtNote(nt),
            });
        else if (ntStatus is { } nt2 && Code(1069))
            Add(new Finding
            {
                // Windows' reason by number — the case nothing else could prove: a wrong stored password (0xC000006A)
                RuleId = "svc.logon_failed", Certainty = Certainty.Proven, EvidenceIds = [statusId, .. failIds, .. StartEv(1069)],
                Claim = $"{s.Name} does not start because its account {acct} could not log on: {nt2.Meaning}." + NtNote(nt2, withMeaning: false),
            });
        else if (logonCode is 1326 or 1330 or 1331 or 1909 || (Code(1069) && logonIds.Count > 0))
            Add(new Finding
            {
                RuleId = "svc.logon_failed", Certainty = Certainty.Proven, EvidenceIds = [statusId, .. logonIds, .. StartEv(1069)],
                Claim = $"{s.Name} does not start because its account {acct} could not log on: "
                        + (logonCode is { } lc ? (Win32.TryGetValue(lc, out var t) ? t : $"error {lc}") : "logon failure") + ".",
            });
        else if (Code(1069))
        {
            Add(new Finding
            {
                RuleId = "svc.logon_failed", Certainty = Certainty.Likely, EvidenceIds = [statusId, .. StartEv(1069)],
                Claim = $"{s.Name} does not start because its account {acct} could not log on (error 1069); the reason is not in the recorded events.",
            });
            if (s.LogonFailureAudited == false)
                b.Gap($"why {acct} could not log on", "this host does not audit failed logons (audit policy Logon: no Failure), so Windows wrote no 4625 with the reason");
        }
        // access: the account may not execute the image or traverse its folder (AuthzAccessCheck)
        foreach (var (a, aid) in accessIds.Where(x => x.a.Granted == false))
            Add(new Finding
            {
                RuleId = "svc.access_denied", Certainty = Certainty.Proven, EvidenceIds = [aid, .. StartEv(5)],
                Claim = $"{s.Name} cannot start because its account {acct} may not {a.Desired} {a.Path}: {a.DenyingAce}.",
                Remedy = new Remedy
                {
                    Action = "grant", Target = new RemedyTarget { Kind = "file_acl", Id = a.Path, Attribute = acct },
                    Before = new JsonObject { ["sddl"] = a.Sddl }, After = new JsonObject { ["grant"] = a.Desired, ["to"] = acct },
                    Rollback = new Rollback { Action = "set", Value = new JsonObject { ["sddl"] = a.Sddl } },
                    Verify = new Verify { RuleAbsent = "svc.access_denied", Expect = new JsonObject { ["status"] = "running" } },
                },
            });
        // 4. dependencies: 7001 (a dependency failed), 7003 (does not exist), or the deepest broken link of the chain
        var depEvents = Ev(7001, 7003);
        var broken = s.Dependencies.Where(Broken).OrderByDescending(d => d.Depth).FirstOrDefault();
        if (depEvents.Count > 0 || broken is not null)
        {
            var ids = new List<string> { configId };
            var claim = $"{s.Name} does not start because a service it depends on did not start.";
            Remedy? remedy = null;
            if (broken is not null)
            {
                var depId = b.Evidence(new Evidence
                {
                    Id = $"scm:config:{Builder.Key(broken.Name)}", Source = "QueryServiceConfig",
                    Fact = DepFact(broken), Raw = JsonNode.Parse(System.Text.Json.JsonSerializer.Serialize(broken)),
                });
                ids.Add(depId);
                var chain = broken.Via.Count > 1 ? $" (via {string.Join(" → ", broken.Via.Skip(1).Append(broken.Name))})" : "";
                claim = $"{s.Name} does not start because the service it depends on, {broken.Name}{chain}, {DepState(broken)}.";
                if (broken is { Exists: true, StartType: "disabled", IsGroup: false })
                    remedy = StartTypeRemedy(broken.Name, "svc.dependency_failed");
            }
            ids.AddRange(depEvents);
            Add(new Finding { RuleId = "svc.dependency_failed", Certainty = Certainty.Proven, EvidenceIds = ids, Claim = claim, Remedy = remedy });
        }
        // 5./6. timeout or crash
        var appCrash = s.Events.Where(e => e.Log == "Application" && e.EventId is 1000 or 1026 && ImageNamed(e, s.Image))
            .OrderByDescending(e => e.Time).Select(e => evIds[e]).ToList();
        var timeoutIds = Ev(7009, 7011);
        var crashIds = Ev(7031, 7034);
        if (crashIds.Count > 0 || (appCrash.Count > 0 && (timeoutIds.Count > 0 || Code(1067) || Code(1053))))
        {
            // B14 step 2: WHERE — the faulting function from public symbols, and for .NET the exception and first managed
            // frame of event 1026. Each is its own evidence; what could not be resolved is a named gap.
            var where = new List<string>();
            var whereIds = new List<string>();
            if (s.CrashFrame is { } cf)
            {
                if (cf.Function is { } fn)
                {
                    whereIds.Add(b.Evidence(new Evidence
                    {
                        Id = $"sym:{Builder.Key(cf.Module)}:{cf.Offset:x}", Source = "dbghelp SymFromAddr (public symbols)",
                        Fact = $"Offset 0x{cf.Offset:X} in {cf.Module} {cf.ModuleVersionNow} is {fn}+0x{cf.Displacement:X} ({cf.Pdb} {cf.PdbId}, {cf.SymbolSource}).",
                        Raw = JsonNode.Parse(System.Text.Json.JsonSerializer.Serialize(cf)),
                    }));
                    where.Add($"{ExceptionName(cf.Exception)} in {fn}+0x{cf.Displacement:X}");
                }
                else if (cf.Gap is { } cg) b.Gap($"the function in which {s.Name} crashed", cg);
            }
            var managed = s.Events.Where(e => e.Provider == ".NET Runtime" && e.EventId == 1026 && evIds.ContainsKey(e) && appCrash.Contains(evIds[e]))
                .OrderByDescending(e => e.Time).FirstOrDefault();
            if (managed is not null && ManagedFrame(managed) is { } mf) where.Add(mf);
            Add(new Finding
            {
                RuleId = "svc.crash", Certainty = appCrash.Count > 0 ? Certainty.Proven : Certainty.Likely,
                EvidenceIds = [statusId, .. crashIds, .. appCrash, .. timeoutIds, .. whereIds],
                Claim = (appCrash.Count > 0 ? $"The process of {s.Name} crashed (an application error of its image is recorded)."
                    : $"The process of {s.Name} terminated unexpectedly (the service control manager recorded it; no application error was found).")
                    + (where.Count > 0 ? " " + string.Join("; ", where) + "." : ""),
            });
        }
        else if (timeoutIds.Count > 0 || Code(1053))
            Add(new Finding
            {
                RuleId = "svc.timeout", Certainty = Certainty.Proven, EvidenceIds = [statusId, .. timeoutIds, .. StartEv(1053)],
                Claim = $"{s.Name} did not report as started in time (error 1053 / event 7009, 7011).",
            });
        // 7. own error code
        var ownIds = Ev(7023, 7024);
        if (st.Win32ExitCode == 1066 || ownIds.Count > 0)
            Add(new Finding
            {
                RuleId = "svc.exits_immediately", Certainty = Certainty.Proven, EvidenceIds = [statusId, .. ownIds],
                Claim = st.Win32ExitCode == 1066
                    ? $"{s.Name} started and stopped at once with its own error code {st.ServiceSpecificExitCode}."
                    : $"{s.Name} started and stopped at once with an error (event 7023/7024).",
            });
        // cleanly stopped
        if (hit.Count == 0 && st.Win32ExitCode is 0 or 1077 && mine.All(e => !ScmFailureEvents.Contains(e.EventId)))
            Add(new Finding
            {
                RuleId = "svc.stopped_cleanly", Certainty = Certainty.Proven, EvidenceIds = [statusId],
                Claim = st.Win32ExitCode == 1077 ? $"{s.Name} is stopped and has not been started since the last boot."
                    : $"{s.Name} is stopped and its last run ended without error.",
            });
        if (hit.Count == 0)
        {
            var read = new List<string> { statusId };
            string window;
            if (mine.Count == 0)
            {
                var q = b.Evidence(new Evidence
                {
                    Id = $"evtquery:System:{Builder.Key(s.Name)}", Source = "EventLog/System",
                    Fact = $"No Service Control Manager event in the last {s.EventWindowHours} h names {s.DisplayName ?? s.Name}"
                           + (s.SystemLogOldest is { } o ? $"; the oldest System record is from {o:yyyy-MM-ddTHH:mm:ssZ}." : "."),
                    Raw = new JsonObject { ["window_hours"] = s.EventWindowHours, ["matches"] = 0 },
                });
                read.Add(q);
                window = "and no Service Control Manager event names it";
            }
            else
            {
                read.AddRange(mine.Select(e => evIds[e]));
                window = $"and none of its {mine.Count} Service Control Manager event(s) matches a rule";
            }
            b.Unexplained(read, $"{s.Name} is {st.CurrentState.Replace('_', ' ')} with Win32ExitCode {Err(st.Win32ExitCode)} {window} — "
                                + "why it is not running is not measurable from the current state and the recent log.");
        }
        var failedAt = mine.Where(e => ScmFailureEvents.Contains(e.EventId)).Select(e => (DateTime?)e.Time).Max() ?? s.CollectedAt;
        PrecedeAll(failedAt);
        AddRecentIncidents(b, s);
        return b.Build(status);
    }

    // Recent past incidents from the agent's incident ring (docs/etw-ringbuffer-plan.md): a crash, an abnormal exit or
    // a managed exception the service hit BEFORE now. Each becomes evidence; one svc.recent_incident finding (Likely —
    // it describes a past invocation, never the present state) cites them all. Added after PrecedeAll so a historical
    // incident never attaches a precedent of its own. Called on the running path too — a service that crashed and came
    // back is exactly what this explains.
    private static void AddRecentIncidents(Builder b, WinServiceSnapshot s)
    {
        if (s.RecentIncidents.Count == 0)
            return;
        var ids = s.RecentIncidents.Select(inc =>
        {
            var ev = inc.ToEvidence();
            return b.Has(ev.Id) ? ev.Id : b.Evidence(ev);
        }).ToList();
        var newest = s.RecentIncidents[0];   // the collector hands them over newest-first
        var claim = s.RecentIncidents.Count == 1
            ? $"{s.Name} hit a recent incident before now: {newest.Fact()}"
            : $"{s.Name} hit {s.RecentIncidents.Count} recent incidents before now; the most recent: {newest.Fact()}";
        b.Find(new Finding { RuleId = "svc.recent_incident", Certainty = Certainty.Likely, EvidenceIds = ids, Claim = claim });
    }

    /// <summary>NTSTATUS of a failed logon in Windows' words (the 4625 SubStatus when set, else Status).</summary>
    private static readonly Dictionary<uint, string> NtStatus = new()
    {
        [0xC000006A] = "the password stored for the service is wrong",
        [0xC0000064] = "the account does not exist",
        [0xC0000072] = "the account is disabled",
        [0xC0000234] = "the account is locked out",
        [0xC0000071] = "the account's password has expired",
        [0xC0000193] = "the account has expired",
        [0xC000015B] = "the account has not been granted the logon type (log on as a service)",
        [0xC000006F] = "the account may not log on at this time of day",
        [0xC0000070] = "the account may not log on from this computer",
        [0xC0000133] = "the clocks of this computer and the domain controller differ too much",
        [0xC0000224] = "the account's password must be changed at next logon",
    };

    private sealed record Nt(uint Code, uint Status, uint Sub, string Meaning);

    // EventRecord.Properties hands NTSTATUS over SIGNED ("-1073741718" = 0xC000006A — measured on bossman-wintest);
    // unsigned and hex forms are read too.
    private static uint? U(WinEvent e, int i)
    {
        if (i >= e.Data.Count) return null;
        var v = e.Data[i];
        if (int.TryParse(v, out var signed)) return unchecked((uint)signed);
        if (uint.TryParse(v, out var unsigned)) return unsigned;
        return v.StartsWith("0x", StringComparison.OrdinalIgnoreCase)
               && uint.TryParse(v[2..], System.Globalization.NumberStyles.HexNumber, null, out var h) ? h : null;
    }

    private static Nt? NtReason(WinEvent e)
    {
        var status = U(e, 7) ?? 0;
        var sub = U(e, 9) ?? 0;
        var code = sub != 0 ? sub : status;
        return code == 0 ? null : new Nt(code, status, sub, NtStatus.TryGetValue(code, out var m) ? m : $"logon failure 0x{code:X8}");
    }

    private static string NtNote(Nt? nt, bool withMeaning = true) => nt is null ? ""
        : $" (Windows: Status 0x{nt.Status:X8}" + (nt.Sub != 0 ? $", SubStatus 0x{nt.Sub:X8}" : "") + (withMeaning ? $" — {nt.Meaning}" : "") + ")";

    private static string ExceptionName(uint code) => code switch
    {
        0xC0000005 => "access violation (0xC0000005)",
        0xC0000409 => "stack buffer overrun / fail-fast (0xC0000409)",
        0xC00000FD => "stack overflow (0xC00000FD)",
        0xC0000374 => "heap corruption (0xC0000374)",
        0x80000003 => "breakpoint (0x80000003)",
        0xE0434352 => ".NET exception (0xE0434352)",
        _ => $"exception 0x{code:X8}",
    };

    /// <summary>".NET Runtime" 1026: the exception line and the first managed frame.</summary>
    private static string? ManagedFrame(WinEvent e)
    {
        var text = string.Join("\n", e.Data);
        var ex = System.Text.RegularExpressions.Regex.Match(text, @"Exception Info: ([^\r\n]+)");
        if (!ex.Success) return null;
        var at = System.Text.RegularExpressions.Regex.Match(text, @"^\s+at ([^\r\n]+)", System.Text.RegularExpressions.RegexOptions.Multiline);
        return $"unhandled {ex.Groups[1].Value.Trim()}" + (at.Success ? $" at {at.Groups[1].Value.Trim()}" : "");
    }

    /// <summary>A wait chain in words: "thread 4321 (Blocked) waits on Mutex \BaseNamedObjects\a (Owned) → thread 5678 …".</summary>
    private static string ChainFact(int pid, WinThreadChain th)
    {
        if (th.Error != 0) return $"the wait chain of thread {th.ThreadId} in process {pid} could not be read (error {th.Error}).";
        var parts = th.Nodes.Select(n => n.Type == "Thread"
            ? $"thread {n.ThreadId}" + (n.ProcessId is { } np && np != pid ? $" of process {np}" : "") + $" ({n.Status}" + (n.WaitTimeMs is { } w && w > 0 ? $", waiting {w} ms" : "") + ")"
            : $"{n.Type}" + (n.Name is { } nm ? $" {nm}" : "") + $" ({n.Status})");
        return $"in process {pid}: " + string.Join(" → ", parts) + (th.IsCycle ? " — back to the first: a cycle." : ".");
    }

    // A chain names a lock owner when any node is a kernel object (not a Thread node) with an owner status.
    private static bool HasLockOwner(WinThreadChain th) =>
        th.Nodes.Any(n => n.Type != "Thread" && n.Status is "Owned" or "Abandoned");

    private static bool HostChange(WinEvent e) =>
        e.Provider is "MsiInstaller" or "Microsoft-Windows-WindowsUpdateClient";

    private static string ChangeText(WinEvent e)
    {
        string D(int i) => i < e.Data.Count ? e.Data[i] : "?";
        return (e.Provider, e.EventId) switch
        {
            ("Service Control Manager", 7045) => $"the service {D(0)} was installed (account {D(4)})",
            ("Service Control Manager", 7040) => $"the start type of {D(0)} was changed from {D(1)} to {D(2)}",
            ("MsiInstaller", 1033) => $"the product {D(0)} {D(1)} was installed",
            ("MsiInstaller", 1034) => $"the product {D(0)} {D(1)} was removed",
            ("MsiInstaller", 1035) => $"the product {D(0)} {D(1)} was reconfigured",
            ("MsiInstaller", 1036) => $"an update of the product {D(0)} {D(1)} was installed",
            ("Microsoft-Windows-WindowsUpdateClient", 19) => $"Windows Update installed {D(0)}",
            _ => $"{e.Provider} event {e.EventId}",
        };
    }

    private static HashSet<string> Names(WinServiceSnapshot s) =>
        new(new[] { s.Name, s.DisplayName ?? "" }.Where(n => n != ""), StringComparer.OrdinalIgnoreCase);

    private static string First(WinEvent e) => e.Data.Count > 0 ? e.Data[0] : "";

    private static bool Broken(WinDependency d) =>
        !d.Exists || d.StartType == "disabled" || (d.CurrentState == "stopped" && d.Win32ExitCode is not (0 or 1077));

    private static string DepState(WinDependency d) =>
        !d.Exists ? (d.IsGroup ? "is a group with no member service" : "does not exist")
        : d.StartType == "disabled" ? "is disabled"
        : $"failed with error {Err(d.Win32ExitCode)}";

    private static string DepFact(WinDependency d) =>
        !d.Exists ? $"{d.Name} does not exist."
        : $"{d.Name} has start type {d.StartType} and is {d.CurrentState?.Replace('_', ' ')}, Win32ExitCode {Err(d.Win32ExitCode)}.";

    private static bool ImageNamed(WinEvent e, WinImage? img)
    {
        if (img is null || e.Data.Count == 0) return false;
        var file = System.IO.Path.GetFileName(img.Path.Replace('\\', '/'));
        return e.Data.Any(d => d.Contains(file, StringComparison.OrdinalIgnoreCase));
    }

    private static string ConfigFact(string name, WinServiceConfig c)
    {
        var f = $"{name} runs {c.BinaryPathName} as {(c.ServiceStartName == "" ? "LocalSystem" : c.ServiceStartName)}, start type {c.StartType}"
                + (c.DelayedAutoStart ? " (delayed)" : "");
        if (c.Dependencies.Count > 0) f += ", depends on " + string.Join(", ", c.Dependencies);
        return f + ".";
    }

    private static string EventFact(WinEvent e)
    {
        string D(int i) => i < e.Data.Count ? e.Data[i] : "?";
        string C(int i) => i < e.Data.Count && e.Data[i].StartsWith("%%") && int.TryParse(e.Data[i][2..], out var c) ? Err(c) : D(i);
        var what = (e.Provider, e.EventId) switch
        {
            ("Service Control Manager", 7000) => $"{D(0)} failed to start, error {C(1)}",
            ("Service Control Manager", 7001) => $"{D(0)} depends on {D(1)}, which failed to start, error {C(2)}",
            ("Service Control Manager", 7003) => $"{D(0)} depends on {D(1)}, which does not exist",
            ("Service Control Manager", 7009) => $"a timeout ({D(0)} ms) was reached waiting for {D(1)} to connect",
            ("Service Control Manager", 7011) => $"a timeout ({D(0)} ms) was reached waiting for a transaction response from {D(1)}",
            ("Service Control Manager", 7022) => $"{D(0)} hung on starting",
            ("Service Control Manager", 7023) => $"{D(0)} terminated with error {C(1)}",
            ("Service Control Manager", 7024) => $"{D(0)} terminated with service-specific error {D(1)}",
            ("Service Control Manager", 7031) => $"{D(0)} terminated unexpectedly ({D(1)} time(s))",
            ("Service Control Manager", 7034) => $"{D(0)} terminated unexpectedly ({D(1)} time(s))",
            ("Service Control Manager", 7038) => $"{D(0)} could not log on as {D(1)}, error {C(2)}",
            ("Service Control Manager", 7040) => $"the start type of {D(0)} was changed from {D(1)} to {D(2)}",
            ("Service Control Manager", 7045) => $"service {D(0)} was installed ({D(1)}, account {D(4)})",
            (_, 8004) => $"AppLocker prevented a program from running: {string.Join(" ", e.Data.Where(x => x.Contains('\\')).Take(1))}",
            (_, 8003) => $"AppLocker would have prevented a program (audit): {string.Join(" ", e.Data.Where(x => x.Contains('\\')).Take(1))}",
            (_, 3077) => $"Code Integrity blocked a file from loading: {string.Join(" ", e.Data.Where(x => x.Contains('\\')).Take(1))}",
            (_, 3076) => $"Code Integrity would have blocked a file (audit): {string.Join(" ", e.Data.Where(x => x.Contains('\\')).Take(1))}",
            ("MsiInstaller", 1033 or 1034 or 1035 or 1036) => $"Windows Installer: {ChangeText(e)} (status {D(3)})",
            (_, 4625) => $"the service logon (type 5, by {D(18)}) of {D(6)}\\{D(5)} failed{NtNote(NtReason(e))}",
            ("Microsoft-Windows-WindowsUpdateClient", 19) => $"Windows Update installed {D(0)}",
            (_, 1000) => $"application error: {D(0)} faulted (module {D(3)}, exception {D(6)})",
            (_, 1026) => $".NET runtime error: {string.Join(" ", e.Data).Split('\n')[0]}",
            _ => string.Join(", ", e.Data.Take(4)),
        };
        return $"{e.Provider} event {e.EventId}: {what}.";
    }

    private static string AccountFact(WinAccount a)
    {
        if (a.Kind == "unresolved") return $"The account {a.Name} does not resolve to a SID (LookupAccountName).";
        var f = $"{a.Name} is a {a.Kind} account" + (a.Sid is null ? "" : $" ({a.Sid})");
        var states = new List<string>();
        if (a.Disabled == true) states.Add("disabled");
        if (a.LockedOut == true) states.Add("locked out");
        if (a.PasswordExpired == true) states.Add("its password has expired");
        return f + (states.Count > 0 ? ": " + string.Join(", ", states) : "") + ".";
    }

    private static string RightsFact(WinAccount a) =>
        a.DenyServiceLogonRight == true ? $"{a.Name} is denied the right to log on as a service ({string.Join("; ", a.RightsVia)})."
        : a.ServiceLogonRight == true ? $"{a.Name} holds the right to log on as a service ({string.Join("; ", a.RightsVia)})."
        : $"Neither {a.Name} nor its groups hold SeServiceLogonRight.";

    private static Remedy StartTypeRemedy(string service, string rule) => new()
    {
        Action = "set", Target = new RemedyTarget { Kind = "service_start_type", Id = service, Attribute = "start_type" },
        Before = "disabled", After = "demand", Rollback = new Rollback { Action = "set", Value = "disabled" },
        Verify = new Verify { RuleAbsent = rule, Expect = new JsonObject { ["status"] = "running" } },
    };

    private static Remedy RightRemedy(string account) => new()
    {
        Action = "grant", Target = new RemedyTarget { Kind = "user_right", Id = $"SeServiceLogonRight@{account}" },
        Before = new JsonObject { ["holds"] = false }, After = new JsonObject { ["holds"] = true },
        Rollback = new Rollback { Action = "revoke", Value = $"SeServiceLogonRight@{account}" },
        Verify = new Verify { RuleAbsent = "svc.logon_right_missing", Expect = new JsonObject { ["status"] = "running" } },
    };
}

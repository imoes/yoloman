using System.Diagnostics;

namespace AgenticMcp.Agent.Windows;

/// <summary>
/// The listener's inbound firewall rule, created by the agent itself.
///
/// <para>WHY THE AGENT AND NOT THE INSTALLER: a Windows Server blocks inbound traffic by default, so an
/// agent that starts, enrols, and reports itself reachable at a port nothing can reach is a host that looks
/// managed and is not. That state is invisible from the host — the agent is running, the log says
/// "listening" — and visible only as a poll error on the server, which reads as a network problem. The rule
/// belongs wherever the port is decided, and the port is decided here.</para>
///
/// <para>IDEMPOTENT BY RULE NAME, and it says what it did. A rule that already exists is reported as found,
/// not re-created; a failure is reported with the reason and does NOT stop the agent, because a listener
/// without a rule is still useful on a host whose firewall an operator manages centrally (group policy).
/// What must never happen is silence: "no rule, and nobody said so" is the only outcome with no way back.</para>
///
/// <para>Via <c>netsh advfirewall</c> rather than the COM API (<c>HNetCfg.FwPolicy2</c>): one process, no
/// interop, and the exact command is printable — which matters for an operator who wants to know what was
/// changed on their server, and for undoing it (<c>netsh advfirewall firewall delete rule name=…</c>).</para>
/// </summary>
public static class WindowsFirewall
{
    /// <summary>What happened, for the caller to log. <c>Changed</c> is false when the rule was already there.</summary>
    public sealed record Outcome(bool Ok, bool Changed, string Detail);

    public static string RuleName(int port) => $"yoloman-agent (TCP {port})";

    /// <summary>
    /// Ensures an inbound allow rule for <paramref name="port"/> exists. Never throws: every failure comes
    /// back as <c>Ok: false</c> with the reason, since not being able to open a port is not a reason to stop
    /// serving on it.
    /// </summary>
    public static Outcome EnsurePortOpen(int port)
    {
        if (!OperatingSystem.IsWindows())
        {
            return new Outcome(true, false, "not Windows; nothing to do");
        }

        var name = RuleName(port);
        try
        {
            var existing = Netsh($"advfirewall firewall show rule name=\"{name}\"");
            // netsh exits 1 and prints "No rules match the specified criteria" when it finds nothing. The
            // exit code alone is the check; the text is only for the message.
            if (existing.ExitCode == 0)
            {
                return new Outcome(true, false, $"rule already present: {name}");
            }

            var added = Netsh($"advfirewall firewall add rule name=\"{name}\" dir=in action=allow "
                              + $"protocol=TCP localport={port} profile=any "
                              + "description=\"Inbound REST/MCP listener of the yoloman agent\"");
            if (added.ExitCode != 0)
            {
                return new Outcome(false, false,
                    $"could not add the rule (netsh exit {added.ExitCode}): {Trim(added.Output)}. "
                    + "The agent is listening anyway; open the port by hand or by policy.");
            }

            return new Outcome(true, true, $"created inbound TCP allow rule: {name}");
        }
        catch (Exception ex)
        {
            return new Outcome(false, false,
                $"could not run netsh ({ex.GetType().Name}: {ex.Message}). The agent is listening anyway.");
        }
    }

    private static (int ExitCode, string Output) Netsh(string arguments)
    {
        var psi = new ProcessStartInfo("netsh", arguments)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        using var process = Process.Start(psi)
                            ?? throw new InvalidOperationException("netsh did not start");
        var output = process.StandardOutput.ReadToEnd() + process.StandardError.ReadToEnd();
        // A firewall call that hangs must not hold up the listener; 30 s is far beyond netsh's normal
        // sub-second answer, so hitting it means something is wrong rather than slow.
        if (!process.WaitForExit(30_000))
        {
            try
            {
                process.Kill(entireProcessTree: true);
            }
            catch (InvalidOperationException)
            {
                // Already gone between the timeout and the kill — nothing to do.
            }

            return (-1, "netsh did not finish within 30s");
        }

        return (process.ExitCode, output);
    }

    private static string Trim(string text)
    {
        var line = text.Replace("\r", " ").Replace("\n", " ").Trim();
        return line.Length > 200 ? line[..200] : line;
    }
}

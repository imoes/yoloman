using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace AgenticMcp.Agent.Windows;

/// <summary>
/// Runs a script in <b>Windows PowerShell 5.1</b>, for the in-box management modules that PowerShell 7
/// cannot load in-process.
///
/// <para>WHY THIS EXISTS, measured on Server 2022 and not anticipated by the design: the agent hosts
/// PowerShell 7.5.4, and <c>Get-WindowsFeature</c> fails there with</para>
/// <code>
/// The 'Get-WindowsFeature' command was found in the module 'ServerManager', but the module could not be
/// loaded.
/// </code>
/// <para>ServerManager is a .NET Framework module and PowerShell 7 will not load it in-process. Two bridges
/// were tried against the real host:</para>
/// <list type="bullet">
///   <item><c>Import-Module ServerManager -UseWindowsPowerShell</c> (Microsoft's WinCompat proxy) — returned
///   nothing and reported no error inside the hosted SDK runspace. A bridge that fails silently is worse
///   than no bridge.</item>
///   <item><c>powershell.exe -NoProfile -NonInteractive -Command …</c> with a JSON projection —
///   <b>worked on the first try</b>: <c>{"Name":"Web-Server","InstallState":0,"FeatureType":"Role"}</c>.</item>
/// </list>
/// <para>So the bridge is a child process, and it is EXPLICIT: every reply says which shell produced it, so
/// nobody debugging a feature install has to discover this indirection from a stack trace.</para>
///
/// <para>EVERY ENUM IS CAST TO STRING BY THE CALLER, and that is not a style preference. Measured:
/// <c>InstallState</c> is Available=0, Installed=1, <b>Removed=5</b> — not the 0/1/2 anyone would guess. JSON
/// carries the number, so reading it as an index would have mapped Removed onto nothing and been wrong
/// silently. `[string]$_.InstallState` in the projection is the whole fix, and the reason is here rather
/// than in a commit message.</para>
/// </summary>
public static class WindowsPowerShellBridge
{
    /// <summary>Which shell answered — carried into every module result that uses this bridge.</summary>
    public const string ShellName = "windows-powershell-5.1";

    /// <summary>
    /// Printed by the script immediately before its JSON, so the split is unambiguous.
    ///
    /// <para>THE ALTERNATIVE WAS MEASURED AND IT FAILED. First attempt: take everything from the first `{`
    /// or `[`. But a `-WhatIf` run prints its plan as prose — <c>What if: Performing installation for
    /// "[Webserver (IIS)] HTTP-Protokollierung"</c> — and that bracket IS the first `[`, so the parse started
    /// inside a sentence. A guard that is "deliberately dumb" has to be dumb about the right thing: a marker
    /// nobody else writes, rather than a token the data itself contains.</para>
    /// </summary>
    private const string JsonMarker = "@@AGENTIC-JSON@@";

    private static string Executable =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
            "WindowsPowerShell", "v1.0", "powershell.exe");

    /// <summary>
    /// Runs <paramref name="script"/> in Windows PowerShell and returns its standard output.
    /// Throws <see cref="InvalidOperationException"/> with the error stream when the shell fails, because a
    /// feature install that quietly returns nothing is the failure mode this class was written to end.
    /// </summary>
    public static async Task<string> Run(string script, TimeSpan timeout, CancellationToken ct)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "the Windows PowerShell bridge exists only on Windows");
        }

        var psi = new ProcessStartInfo(Executable)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        psi.ArgumentList.Add("-NoProfile");
        psi.ArgumentList.Add("-NonInteractive");
        // -ExecutionPolicy Bypass: the script is not a FILE, it comes from this process — an execution policy
        // that blocked it would be protecting the host from itself.
        psi.ArgumentList.Add("-ExecutionPolicy");
        psi.ArgumentList.Add("Bypass");
        psi.ArgumentList.Add("-Command");
        // UTF-8 FROM THE CHILD, set inside the script. Windows PowerShell 5.1 writes in the console code page
        // (850/1252 on a German host), and reading that as UTF-8 turned a real error message into
        // "Fehler bei der ?berpr?fung von Voraussetzungen" — the diagnosis mangled exactly when it matters.
        // StandardErrorEncoding on our side cannot fix what the child encoded; the child has to be told.
        // …and the NON-DATA STREAMS SILENCED. Measured: Get-WindowsFeature prepends a warning line to
        // stdout on this host, so the JSON parse failed with "'W' is an invalid start of a value" — the
        // module's whole answer lost to a message about nothing. Suppressed at the source; JsonFrom() below
        // also survives it, because two independent guards against a shell prepending text is the right
        // number when the alternative is an opaque 500.
        psi.ArgumentList.Add("[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; "
                             + "$OutputEncoding = [System.Text.Encoding]::UTF8; "
                             + "$ProgressPreference = 'SilentlyContinue'; "
                             + "$WarningPreference = 'SilentlyContinue'; "
                             + "$InformationPreference = 'SilentlyContinue'; "
                             // The marker goes out on its own line right before the script's JSON.
                             + script.Replace("|| ConvertTo-Json", "|| ConvertTo-Json"));

        using var process = Process.Start(psi)
                            ?? throw new InvalidOperationException($"could not start {Executable}");
        var stdout = process.StandardOutput.ReadToEndAsync(ct);
        var stderr = process.StandardError.ReadToEndAsync(ct);

        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(timeout);
        try
        {
            await process.WaitForExitAsync(deadline.Token);
        }
        catch (OperationCanceledException)
        {
            try
            {
                process.Kill(entireProcessTree: true);
            }
            catch (InvalidOperationException)
            {
                // Finished between the timeout and the kill.
            }

            throw new TimeoutException(
                $"Windows PowerShell did not finish within {timeout.TotalSeconds:0}s");
        }

        var output = await stdout;
        var error = await stderr;
        if (process.ExitCode != 0 || (output.Length == 0 && error.Length > 0))
        {
            throw new InvalidOperationException(
                $"Windows PowerShell failed (exit {process.ExitCode}): {Shorten(error)}");
        }

        return output;
    }

    /// <summary>
    /// Runs a script whose last statement is a <c>ConvertTo-Json</c> and returns the parsed document.
    /// A single object and a single-element array are both normalised to a list, because PowerShell emits the
    /// former when a pipeline happens to yield one item — a shape difference that has nothing to do with the
    /// data and would otherwise need handling at every call site.
    /// </summary>
    /// <summary>
    /// Runs <paramref name="setup"/> (statements, may print anything), then emits the marker, then
    /// <paramref name="jsonExpression"/> piped through ConvertTo-Json.
    ///
    /// <para>TWO ARGUMENTS, NOT ONE, and the reason is a bug this signature makes impossible: with a single
    /// script the marker could only be emitted BEFORE it, so a `-WhatIf` run put its prose between the marker
    /// and the JSON and the parse failed on 'W' — twice, because the first fix moved the guard instead of the
    /// marker. Splitting the call in two puts the marker where it belongs BY CONSTRUCTION: after everything
    /// the cmdlets print, immediately before the data.</para>
    /// </summary>
    public static async Task<Answer> RunJson(string setup, string jsonExpression, TimeSpan timeout,
        CancellationToken ct)
    {
        var script = string.IsNullOrWhiteSpace(setup)
            ? $"Write-Output '{JsonMarker}'; {jsonExpression} | ConvertTo-Json -Depth 6 -Compress"
            : $"{setup}; Write-Output '{JsonMarker}'; {jsonExpression} | ConvertTo-Json -Depth 6 -Compress";
        var raw = await Run(script, timeout, ct);
        var items = new List<JsonElement>();
        var cut = raw.LastIndexOf(JsonMarker, StringComparison.Ordinal);
        var preamble = cut < 0 ? "" : raw[..cut].Trim();
        var text = cut < 0 ? raw.Trim() : raw[(cut + JsonMarker.Length)..].Trim();
        if (text.Length == 0)
        {
            return new Answer(items, preamble);
        }

        using var document = JsonDocument.Parse(text);
        if (document.RootElement.ValueKind == JsonValueKind.Array)
        {
            items.AddRange(document.RootElement.EnumerateArray().Select(e => e.Clone()));
        }
        else
        {
            items.Add(document.RootElement.Clone());
        }

        return new Answer(items, preamble);
    }

    /// <summary>
    /// What a bridged call produced: the parsed JSON, and whatever the shell printed BEFORE it.
    /// The preamble is not noise to be dropped — for a `-WhatIf` it is the plan as Windows narrates it.
    /// </summary>
    public sealed record Answer(List<JsonElement> Items, string Preamble);

    private static string Shorten(string text)
    {
        var line = text.Replace("\r", " ").Replace("\n", " ").Trim();
        return line.Length > 300 ? line[..300] : line;
    }
}

using AgenticMcp.Agent.Core;
using AgenticMcp.Agent.Modules;

namespace AgenticMcp.Agent.Tests;

/// <summary>
/// The `powershell` module, RUN — not mocked.
///
/// Microsoft.PowerShell.SDK is cross-platform, so the action plane is provable on the Linux dev host: these
/// tests start a real runspace and execute real script. What they cannot cover is Windows-only cmdlets, and
/// nothing here pretends otherwise.
/// </summary>
public class PowerShellModuleTests
{
    private static readonly PowerShellModule Module = new();

    private static async Task<ModuleResult> Run(string script, bool dryRun = false,
        Dictionary<string, object?>? extra = null)
    {
        var parameters = new Dictionary<string, object?> { ["script"] = script };
        foreach (var (k, v) in extra ?? [])
        {
            parameters[k] = v;
        }

        return await Module.RunAsync(parameters, dryRun, CancellationToken.None);
    }

    private static Dictionary<string, object?> Data(ModuleResult result) =>
        (Dictionary<string, object?>)result.Data!;

    private static List<T> List<T>(ModuleResult result, string key) => (List<T>)Data(result)[key]!;

    [Fact]
    public async Task ItRunsAScriptAndReturnsTheOutputObjects()
    {
        var result = await Run("1 + 1");
        var output = List<Dictionary<string, object?>>(result, "output");

        Assert.Single(output);
        Assert.Equal("2", output[0]["value"]);
        // THE TYPE NAME is what makes this different from capturing stdout.
        Assert.Equal("System.Int32", output[0]["type"]);
    }

    [Fact]
    public async Task TheTypeSurvivesForObjectsThatRenderLikeStrings()
    {
        var result = await Run("Get-Date -Date '2026-08-26T10:00:00Z'");
        Assert.Equal("System.DateTime", List<Dictionary<string, object?>>(result, "output")[0]["type"]);
    }

    [Fact]
    public async Task WarningsAreTheirOwnStreamAndNotMixedIntoTheOutput()
    {
        var result = await Run("Write-Warning 'careful'; 'the value'");

        Assert.Equal(["careful"], List<string>(result, "warnings"));
        Assert.Single(List<Dictionary<string, object?>>(result, "output"));
        Assert.False((bool)Data(result)["had_errors"]!);
    }

    [Fact]
    public async Task ANonTerminatingErrorIsReportedAsOneAndTheOutputStillArrives()
    {
        var result = await Run("Write-Error 'that failed'; 'but this ran'");

        Assert.True((bool)Data(result)["had_errors"]!);
        Assert.Contains("that failed", string.Join(" ", List<string>(result, "errors")));
        Assert.Contains("ran with errors", result.Msg);
        // The point of separate streams: an error does not cost the caller the output.
        Assert.Single(List<Dictionary<string, object?>>(result, "output"));
    }

    [Fact]
    public async Task ADryRunWithoutWhatifDoesNotRunTheScriptAndSaysWhy()
    {
        var marker = Path.Combine(Path.GetTempPath(), "ps-dryrun-" + Guid.NewGuid().ToString("N"));
        var result = await Run($"New-Item -ItemType File -Path '{marker}'", dryRun: true);

        Assert.False(File.Exists(marker));
        Assert.False(result.Changed);
        // Naming the parameter that would change the answer is the difference between a refusal and a shrug.
        Assert.Contains("whatif=true", result.Msg);
        Assert.False((bool)Data(result)["previewable"]!);
    }

    [Fact]
    public async Task ADryRunWithWhatifPreviewsForRealAndChangesNothing()
    {
        var marker = Path.Combine(Path.GetTempPath(), "ps-whatif-" + Guid.NewGuid().ToString("N"));
        var result = await Run($"New-Item -ItemType File -Path '{marker}'", dryRun: true,
            new Dictionary<string, object?> { ["whatif"] = true });

        Assert.False(File.Exists(marker));
        Assert.False(result.Changed);
        Assert.True((bool)Data(result)["what_if"]!);
        Assert.Equal("previewed under $WhatIfPreference", result.Msg);
    }

    [Fact]
    public async Task OutsideADryRunTheSameScriptActuallyRuns()
    {
        // The control case for the two above: if this did not create the file, the dry-run tests would pass
        // for the wrong reason.
        var marker = Path.Combine(Path.GetTempPath(), "ps-real-" + Guid.NewGuid().ToString("N"));
        try
        {
            var result = await Run($"New-Item -ItemType File -Path '{marker}' | Out-Null");
            Assert.True(File.Exists(marker));
            Assert.True(result.Changed);
            Assert.Equal("executed", result.Msg);
        }
        finally
        {
            if (File.Exists(marker))
            {
                File.Delete(marker);
            }
        }
    }

    [Fact]
    public async Task AScriptThatHangsIsStoppedAndSaysSo()
    {
        var result = await Run("'before the wait'; Start-Sleep -Seconds 30",
            extra: new Dictionary<string, object?> { ["timeout_seconds"] = 2 });

        Assert.True((bool)Data(result)["timed_out"]!);
        Assert.Contains("did not finish", result.Msg);
        // Stop, not Abort: what the script produced before hanging is still reported.
        Assert.Single(List<Dictionary<string, object?>>(result, "output"));
    }

    [Fact]
    public async Task AnEmptyScriptIsRejectedRatherThanRunAsANoOp()
    {
        await Assert.ThrowsAsync<ArgumentException>(() => Run("   "));
    }

    [Fact]
    public async Task AMissingWorkingDirectoryIsAnErrorNotASilentFallback()
    {
        // Running the right script in the wrong directory is the failure this parameter exists to prevent.
        await Assert.ThrowsAsync<DirectoryNotFoundException>(() => Run("'x'",
            extra: new Dictionary<string, object?> { ["working_directory"] = "/nowhere-at-all-42" }));
    }

    [Fact]
    public async Task TheWorkingDirectoryIsWhereTheScriptRuns()
    {
        var dir = Directory.CreateTempSubdirectory("ps-cwd-").FullName;
        try
        {
            var result = await Run("(Get-Location).Path",
                extra: new Dictionary<string, object?> { ["working_directory"] = dir });
            Assert.Equal(dir, List<Dictionary<string, object?>>(result, "output")[0]["value"]);
        }
        finally
        {
            Directory.Delete(dir, true);
        }
    }

    [Fact]
    public void ItWritesSoAClosedGateTurnsItIntoANamedRefusal()
    {
        Assert.True(Module.Writes);
        var refused = new ModuleRegistry(writeEnabled: false).Add(Module).Describe()
            .Tools.Single(t => t.Name == "powershell");
        Assert.False(refused.Supported);
        Assert.Contains("write gate is closed", refused.UnsupportedReason);
    }
}

/// <summary>
/// The runspace's MODULE TREE — the thing the unit tests above were passing without.
///
/// A hosted runspace does not find PowerShell's own modules by itself. The tests were green because the test
/// assembly's output directory happens to contain the SDK's `runtimes/*/lib/*/Modules` folder; the agent's did
/// not, so `Get-Date` came back as "The term 'Get-Date' is not recognized" on the first real end-to-end call
/// through Bossman. These assert the thing that was actually load-bearing.
/// </summary>
public class PowerShellModulePathTests
{
    [Fact]
    public void TheModuleTreeIsFound()
    {
        Assert.NotNull(PowerShellModule.ModuleDirectory);
        Assert.True(Directory.Exists(PowerShellModule.ModuleDirectory));
    }

    [Fact]
    public void ItIsTheTreeForTHISPlatform()
    {
        // The other platform's tree ships too, and it is the wrong one: the win tree carries CIM/WSMan
        // cmdlets that cannot load on Linux.
        var expected = OperatingSystem.IsWindows() ? "/win/" : "/unix/";
        Assert.Contains(expected, PowerShellModule.ModuleDirectory!.Replace('\\', '/'));
    }

    [Fact]
    public void TheCoreModulesAreActuallyThere()
    {
        foreach (var module in new[] { "Microsoft.PowerShell.Utility", "Microsoft.PowerShell.Management" })
        {
            Assert.True(Directory.Exists(Path.Combine(PowerShellModule.ModuleDirectory!, module)),
                $"{module} is missing — a runspace without it can evaluate expressions and manage nothing");
        }
    }

    [Fact]
    public async Task ACmdletFromAnAutoLoadedModuleResolves()
    {
        // Get-Date lives in Microsoft.PowerShell.Utility, which is exactly what was missing. Asserted through
        // the module rather than by checking the path, because PSModulePath being set is not the same claim
        // as auto-loading working.
        var result = await new PowerShellModule().RunAsync(
            new Dictionary<string, object?> { ["script"] = "Get-Date -Format yyyy" }, false,
            CancellationToken.None);

        var data = (Dictionary<string, object?>)result.Data!;
        Assert.False((bool)data["had_errors"]!);
        Assert.Single((List<Dictionary<string, object?>>)data["output"]!);
    }

    [Fact]
    public async Task EveryResultReportsWhichModuleTreeItUsed()
    {
        // "Get-Date is not recognized" is unreadable without this, and null here is the difference between a
        // broken script and a runspace with no cmdlets.
        var result = await new PowerShellModule().RunAsync(
            new Dictionary<string, object?> { ["script"] = "1" }, false, CancellationToken.None);

        Assert.Equal(PowerShellModule.ModuleDirectory,
            ((Dictionary<string, object?>)result.Data!)["module_path"]);
    }
}

using AgenticMcp.Agent.Core;
using AgenticMcp.Agent.Modules;

namespace AgenticMcp.Agent.Tests;

/// <summary>
/// `file` and `copy`, against a real temporary directory — the two modules whose implementation is native
/// .NET IO and therefore the same code on Windows and here.
/// </summary>
public class FileModuleTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("agentic-file-").FullName;
    private readonly FileModule _module = new();

    public void Dispose()
    {
        if (Directory.Exists(_dir))
        {
            Directory.Delete(_dir, true);
        }
    }

    private string P(string name) => Path.Combine(_dir, name);

    private Task<ModuleResult> Run(string path, string? state = null, bool dryRun = false,
        Dictionary<string, object?>? extra = null)
    {
        var parameters = new Dictionary<string, object?> { ["path"] = path };
        if (state is not null)
        {
            parameters["state"] = state;
        }

        foreach (var (k, v) in extra ?? [])
        {
            parameters[k] = v;
        }

        return _module.RunAsync(parameters, dryRun, CancellationToken.None);
    }

    [Fact]
    public async Task ItCreatesADirectoryAndThenReportsNoChange()
    {
        var path = P("a/b/c");
        Assert.True((await Run(path, "directory")).Changed);
        Assert.True(Directory.Exists(path));

        // The second run is the one that matters: a module that reported "changed" every time would drown
        // real drift in noise.
        var again = await Run(path, "directory");
        Assert.False(again.Changed);
        Assert.Equal("already a directory", again.Msg);
    }

    [Fact]
    public async Task ItCreatesAnEmptyFileAndThenReportsNoChange()
    {
        var path = P("empty.txt");
        Assert.True((await Run(path)).Changed);
        Assert.Equal(0, new FileInfo(path).Length);
        Assert.False((await Run(path)).Changed);
    }

    [Fact]
    public async Task AbsentRemovesADirectoryTreeAndIsIdempotent()
    {
        var path = P("tree");
        Directory.CreateDirectory(Path.Combine(path, "inner"));
        await File.WriteAllTextAsync(Path.Combine(path, "inner", "f.txt"), "x");

        Assert.True((await Run(path, "absent")).Changed);
        Assert.False(Directory.Exists(path));

        var again = await Run(path, "absent");
        Assert.False(again.Changed);
        Assert.Equal("already absent", again.Msg);
    }

    [Fact]
    public async Task TouchAlwaysReportsAChangeBecauseThatIsWhatItDoes()
    {
        var path = P("stamp");
        await File.WriteAllTextAsync(path, "x");
        File.SetLastWriteTimeUtc(path, new DateTime(2020, 1, 1, 0, 0, 0, DateTimeKind.Utc));

        var result = await Run(path, "touch");
        Assert.True(result.Changed);
        Assert.True(File.GetLastWriteTimeUtc(path).Year > 2020);
    }

    [Fact]
    public async Task ADryRunReportsWhatWouldHappenAndDoesNothing()
    {
        var path = P("preview");
        var result = await Run(path, "file", dryRun: true);

        Assert.True(result.Changed);
        Assert.StartsWith("would change:", result.Msg);
        Assert.False(File.Exists(path));
    }

    [Fact]
    public async Task ItRefusesToReplaceAFileWithADirectory()
    {
        // Deleting a file to put a directory in its place is data loss the caller did not ask for.
        var path = P("in-the-way");
        await File.WriteAllTextAsync(path, "important");

        await Assert.ThrowsAsync<IOException>(() => Run(path, "directory"));
        Assert.Equal("important", await File.ReadAllTextAsync(path));
    }

    [Fact]
    public async Task ItRefusesToReplaceADirectoryWithAFile()
    {
        var path = P("adir");
        Directory.CreateDirectory(path);
        await Assert.ThrowsAsync<IOException>(() => Run(path));
        Assert.True(Directory.Exists(path));
    }

    [Theory]
    [InlineData("mode")]
    [InlineData("owner")]
    [InlineData("group")]
    public async Task PosixOnlyParametersAreRefusedRatherThanIgnored(string parameter)
    {
        // Silently dropping mode: "0600" would report success for a file readable by everyone — the worst
        // kind of wrong answer, because it looks like the right one.
        var ex = await Assert.ThrowsAsync<ArgumentException>(() =>
            Run(P("x"), "file", extra: new Dictionary<string, object?> { [parameter] = "0600" }));
        Assert.Contains("POSIX-only", ex.Message);
        Assert.Contains("ACL is not a mode bit", ex.Message);
    }

    [Fact]
    public async Task AnUnknownStateIsRejectedWithTheListOfRealOnes()
    {
        var ex = await Assert.ThrowsAsync<ArgumentException>(() => Run(P("x"), "hardlink"));
        Assert.Contains("must be one of file, directory, absent, touch", ex.Message);
    }
}

public class CopyModuleTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("agentic-copy-").FullName;
    private readonly CopyModule _module = new();

    public void Dispose()
    {
        if (Directory.Exists(_dir))
        {
            Directory.Delete(_dir, true);
        }
    }

    private string P(string name) => Path.Combine(_dir, name);

    private Task<ModuleResult> Run(Dictionary<string, object?> parameters, bool dryRun = false) =>
        _module.RunAsync(parameters, dryRun, CancellationToken.None);

    private static Dictionary<string, object?> Data(ModuleResult r) => (Dictionary<string, object?>)r.Data!;

    [Fact]
    public async Task ItWritesInlineContentAndReportsTheChecksum()
    {
        var dest = P("out.conf");
        var result = await Run(new Dictionary<string, object?> { ["dest"] = dest, ["content"] = "listen = 8080\n" });

        Assert.True(result.Changed);
        Assert.Equal("listen = 8080\n", await File.ReadAllTextAsync(dest));
        // "changed: true" without saying to WHAT is a claim nobody can check.
        Assert.Equal(64, ((string)Data(result)["checksum"]!).Length);
        Assert.Null(Data(result)["checksum_before"]);
    }

    [Fact]
    public async Task TheSameContentTwiceIsNotAChange()
    {
        var dest = P("same.conf");
        var parameters = new Dictionary<string, object?> { ["dest"] = dest, ["content"] = "a=1\n" };
        await Run(parameters);

        var again = await Run(parameters);
        Assert.False(again.Changed);
        Assert.Equal("already has this content", again.Msg);
    }

    [Fact]
    public async Task IdempotenceIsByContentNotByTimestamp()
    {
        // A file edited and then back-dated must still count as changed. A mtime comparison would call this
        // unchanged, which is the dangerous direction of that mistake.
        var dest = P("backdated.conf");
        await Run(new Dictionary<string, object?> { ["dest"] = dest, ["content"] = "a=1\n" });
        await File.WriteAllTextAsync(dest, "a=2\n");
        File.SetLastWriteTimeUtc(dest, new DateTime(2000, 1, 1, 0, 0, 0, DateTimeKind.Utc));

        var result = await Run(new Dictionary<string, object?> { ["dest"] = dest, ["content"] = "a=1\n" });
        Assert.True(result.Changed);
        Assert.Equal("content replaced", result.Msg);
        Assert.NotNull(Data(result)["checksum_before"]);
    }

    [Fact]
    public async Task ADryRunKnowsBothChecksumsAndWritesNothing()
    {
        var dest = P("preview.conf");
        await File.WriteAllTextAsync(dest, "old\n");

        var result = await Run(new Dictionary<string, object?> { ["dest"] = dest, ["content"] = "new\n" },
            dryRun: true);

        Assert.True(result.Changed);
        Assert.Equal("would replace the content", result.Msg);
        Assert.NotEqual(Data(result)["checksum_before"], Data(result)["checksum"]);
        Assert.Equal("old\n", await File.ReadAllTextAsync(dest));
    }

    [Fact]
    public async Task ABackupKeepsThePreviousContentAndSaysWhere()
    {
        var dest = P("with-backup.conf");
        await File.WriteAllTextAsync(dest, "before\n");

        var result = await Run(new Dictionary<string, object?>
        {
            ["dest"] = dest, ["content"] = "after\n", ["backup"] = true,
        });

        var backup = (string)Data(result)["backup"]!;
        Assert.Equal("before\n", await File.ReadAllTextAsync(backup));
        Assert.Equal("after\n", await File.ReadAllTextAsync(dest));
        Assert.EndsWith(".bak", backup);
    }

    [Fact]
    public async Task ItCopiesFromALocalFile()
    {
        var src = P("src.txt");
        var dest = P("nested/dest.txt");
        await File.WriteAllTextAsync(src, "payload");

        Assert.True((await Run(new Dictionary<string, object?> { ["dest"] = dest, ["src"] = src })).Changed);
        Assert.Equal("payload", await File.ReadAllTextAsync(dest));
    }

    [Fact]
    public async Task SrcAndContentTogetherIsAnErrorNotAPreference()
    {
        // Two different beliefs about what should land there; guessing would make one of them silent.
        var ex = await Assert.ThrowsAsync<ArgumentException>(() => Run(new Dictionary<string, object?>
        {
            ["dest"] = P("x"), ["src"] = P("y"), ["content"] = "z",
        }));
        Assert.Contains("mutually exclusive", ex.Message);
    }

    [Fact]
    public async Task AMissingSrcIsNamed()
    {
        await Assert.ThrowsAsync<FileNotFoundException>(() => Run(new Dictionary<string, object?>
        {
            ["dest"] = P("x"), ["src"] = P("not-there"),
        }));
    }

    [Fact]
    public async Task NeitherSrcNorContentIsRejected()
    {
        await Assert.ThrowsAsync<ArgumentException>(() =>
            Run(new Dictionary<string, object?> { ["dest"] = P("x") }));
    }

    [Fact]
    public async Task NoTemporaryFileIsLeftBehind()
    {
        // The write goes through a temporary beside the destination so a reader never sees a half-written
        // config. If one survives, the next run's hash would compare against the wrong thing.
        var dest = P("atomic.conf");
        await Run(new Dictionary<string, object?> { ["dest"] = dest, ["content"] = "x" });
        Assert.Empty(Directory.GetFiles(_dir, "*.agentic-tmp"));
    }
}

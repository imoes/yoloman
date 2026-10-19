using System.Reflection.PortableExecutable;
using System.Runtime.InteropServices;
using AgenticMcp.Agent.Diagnosis;

namespace AgenticMcp.Agent.Windows.Diagnosis;

/// <summary>
/// Turns "faulting module X, offset 0x…" (Application event 1000) into a function name — with the module's public
/// symbols, not its source and not a memory dump (plan B14 step 2).
///
/// <para>The PDB a module was built with is named in its own PE debug directory (CodeView: PDB name, GUID, age). Microsoft
/// publishes those PDBs on its symbol server under exactly that key; the agent fetches the one PDB into a local cache
/// and asks Windows' own dbghelp.dll for the symbol at the offset. Nothing of the crashed process leaves the host — only
/// the request for a public file. dbghelp in System32 has no symsrv.dll (measured on bossman-wintest), so the download
/// is done here and dbghelp is pointed at the folder.</para>
/// </summary>
public static class CrashSymbolizer
{
    private const string SymbolServer = "https://msdl.microsoft.com/download/symbols";
    private static readonly string Cache = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "agentic-mcp", "symbols");
    private static readonly object DbgHelpLock = new();   // dbghelp is single-threaded by contract

    public static void Resolve(WinCrashFrame f)
    {
        if (!File.Exists(f.ModulePath)) { f.Gap = $"{f.ModulePath} is no longer on disk"; return; }
        // Build and revision from the NUMERIC version: the FileVersion string of a Windows binary is not kept current
        // (measured: KERNELBASE.dll's string read 10.0.20348.5622, its numeric version 6.2.20348.5756 — the one the
        // crash event reports as 10.0.20348.5756). Major/minor differ by design (6.2 compatibility), so they are not compared.
        var vi = System.Diagnostics.FileVersionInfo.GetVersionInfo(f.ModulePath);
        f.ModuleVersionNow = $"{vi.FileBuildPart}.{vi.FilePrivatePart}";
        if (f.ModuleVersionAtCrash is { } atCrash)
        {
            var parts = atCrash.Split(' ')[0].Split('.');
            var crashBuild = parts.Length >= 2 ? $"{parts[^2]}.{parts[^1]}" : atCrash;
            if (crashBuild != f.ModuleVersionNow)
            {
                f.Gap = $"{f.Module} was build {crashBuild} at the crash and is {f.ModuleVersionNow} now — its symbols would name a different code";
                return;
            }
        }
        ulong imageBase; uint imageSize; string pdbName; string pdbId;
        using (var pe = new PEReader(File.OpenRead(f.ModulePath)))
        {
            imageBase = pe.PEHeaders.PEHeader!.ImageBase;
            imageSize = (uint)pe.PEHeaders.PEHeader.SizeOfImage;
            var cv = pe.ReadDebugDirectory().FirstOrDefault(d => d.Type == DebugDirectoryEntryType.CodeView);
            if (cv.DataSize == 0) { f.Gap = $"{f.Module} names no PDB (no CodeView debug record)"; return; }
            var data = pe.ReadCodeViewDebugDirectoryData(cv);
            pdbName = Path.GetFileName(data.Path);
            pdbId = data.Guid.ToString("N").ToUpperInvariant() + data.Age.ToString("X");
        }
        f.Pdb = pdbName; f.PdbId = pdbId;
        var folder = Path.Combine(Cache, pdbName, pdbId);
        var pdbPath = Path.Combine(folder, pdbName);
        if (!File.Exists(pdbPath))
        {
            try
            {
                Directory.CreateDirectory(folder);
                using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
                var bytes = http.GetByteArrayAsync($"{SymbolServer}/{pdbName}/{pdbId}/{pdbName}").GetAwaiter().GetResult();
                File.WriteAllBytes(pdbPath, bytes);
                f.SymbolSource = "Microsoft symbol server";
            }
            catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or IOException or UnauthorizedAccessException)
            {
                f.Gap = $"the public symbols for {f.Module} ({pdbName} {pdbId}) could not be fetched: {ex.GetType().Name}: {ex.Message}";
                return;
            }
        }
        else f.SymbolSource = "local symbol cache (from the Microsoft symbol server)";

        lock (DbgHelpLock)
        {
            var h = new IntPtr(0x5A_6D_4E_01);                       // any unique value: no live process is attached
            Native.SymSetOptions(Native.SYMOPT_UNDNAME | Native.SYMOPT_FAIL_CRITICAL_ERRORS | Native.SYMOPT_EXACT_SYMBOLS);
            if (!Native.SymInitializeW(h, folder, false)) { f.Gap = $"SymInitialize failed ({Marshal.GetLastWin32Error()})"; return; }
            try
            {
                var loaded = Native.SymLoadModuleExW(h, IntPtr.Zero, f.ModulePath, null, imageBase, imageSize, IntPtr.Zero, 0);
                if (loaded == 0) { f.Gap = $"dbghelp could not load {f.Module}'s symbols ({Marshal.GetLastWin32Error()})"; return; }
                const int maxName = 512;
                var buf = Marshal.AllocHGlobal(Native.SymbolInfoSize + maxName * 2);
                try
                {
                    for (var i = 0; i < Native.SymbolInfoSize + maxName * 2; i++) Marshal.WriteByte(buf, i, 0);
                    Marshal.WriteInt32(buf, 0, Native.SymbolInfoSize);   // SizeOfStruct (fixed part)
                    Marshal.WriteInt32(buf, 80, maxName);                 // MaxNameLen
                    if (!Native.SymFromAddrW(h, imageBase + f.Offset, out var disp, buf))
                    {
                        f.Gap = $"no symbol in {pdbName} covers offset 0x{f.Offset:X} ({Marshal.GetLastWin32Error()})";
                        return;
                    }
                    var nameLen = Marshal.ReadInt32(buf, 76);               // NameLen
                    f.Function = $"{Path.GetFileNameWithoutExtension(f.Module)}!{Marshal.PtrToStringUni(buf + 84, nameLen)}";
                    f.Displacement = disp;
                }
                finally { Marshal.FreeHGlobal(buf); }
            }
            finally { Native.SymCleanup(h); }
        }
    }

    private static class Native
    {
        public const uint SYMOPT_UNDNAME = 0x2, SYMOPT_FAIL_CRITICAL_ERRORS = 0x200, SYMOPT_EXACT_SYMBOLS = 0x400;
        // SYMBOL_INFOW: SizeOfStruct(0) TypeIndex(4) Reserved[2](8) Index(24) Size(28) ModBase(32) Flags(40) Value(48)
        // Address(56) Register(64) Scope(68) Tag(72) NameLen(76) MaxNameLen(80) Name(84) — 88 with the first WCHAR.
        public const int SymbolInfoSize = 88;

        [DllImport("dbghelp.dll")] public static extern uint SymSetOptions(uint options);
        [DllImport("dbghelp.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)] public static extern bool SymInitializeW(IntPtr process, string searchPath, [MarshalAs(UnmanagedType.Bool)] bool invade);
        [DllImport("dbghelp.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern ulong SymLoadModuleExW(IntPtr process, IntPtr file, string imageName, string? moduleName, ulong baseOfDll, uint dllSize, IntPtr data, uint flags);
        [DllImport("dbghelp.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)] public static extern bool SymFromAddrW(IntPtr process, ulong address, out ulong displacement, IntPtr symbol);
        [DllImport("dbghelp.dll")]
        [return: MarshalAs(UnmanagedType.Bool)] public static extern bool SymCleanup(IntPtr process);
    }
}

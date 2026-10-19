using System.ComponentModel;
using System.Runtime.InteropServices;
using AgenticMcp.Agent.Diagnosis;

namespace AgenticMcp.Agent.Windows.Diagnosis;

/// <summary>
/// What every thread of a process waits on — Wait Chain Traversal (advapi32 OpenThreadWaitChainSession /
/// GetThreadWaitChain), the documented interface behind Resource Monitor's "Analyze wait chain" (plan B14 step 1).
///
/// <para>NO MEMORY DUMP: only the chain is read — lock/thread/process ids, object types, wait times, object names — so
/// nothing of the process's memory leaves it. Windows itself marks a chain that closes on itself (IsCycle): a deadlock,
/// measured, not inferred.</para>
/// </summary>
public static class WaitChainCollector
{
    private static readonly string[] Types = ["", "CriticalSection", "SendMessage", "Mutex", "Alpc", "Com", "ThreadWait",
        "ProcessWait", "Thread", "ComActivation", "Unknown", "SocketIo", "SmbIo"];
    private static readonly string[] Statuses = ["", "NoAccess", "Running", "Blocked", "PidOnly", "PidOnlyRpcss", "Owned",
        "NotOwned", "Abandoned", "Unknown", "Error"];

    public static WinWaitChain Read(int pid)
    {
        var chain = new WinWaitChain { ProcessId = pid };
        var session = Native.OpenThreadWaitChainSession(0, IntPtr.Zero);
        if (session == IntPtr.Zero)
        {
            chain.Gap = $"OpenThreadWaitChainSession failed: {new Win32Exception(Marshal.GetLastWin32Error()).Message}";
            return chain;
        }
        try
        {
            int[] threads;
            try { using var p = System.Diagnostics.Process.GetProcessById(pid); threads = p.Threads.Cast<System.Diagnostics.ProcessThread>().Select(t => t.Id).ToArray(); }
            catch (ArgumentException) { chain.Gap = $"process {pid} is gone"; return chain; }
            // Read from an unmanaged buffer: the node is a union of a WCHAR[128] name and thread ids, and a managed string
            // overlapping int fields is a type .NET refuses to load.
            var buf = Marshal.AllocHGlobal(Native.NodeSize * Native.WCT_MAX_NODE_COUNT);
            try
            {
                foreach (var tid in threads)
                {
                    var count = Native.WCT_MAX_NODE_COUNT;
                    var tc = new WinThreadChain { ThreadId = tid };
                    if (!Native.GetThreadWaitChain(session, IntPtr.Zero, Native.WCT_OUT_OF_PROC_FLAG | Native.WCT_OUT_OF_PROC_COM_FLAG | Native.WCT_OUT_OF_PROC_CS_FLAG,
                            (uint)tid, ref count, buf, out var cycle))
                    {
                        tc.Error = Marshal.GetLastWin32Error();
                        chain.Threads.Add(tc);
                        continue;
                    }
                    tc.IsCycle = cycle;
                    for (var i = 0; i < count && i < Native.WCT_MAX_NODE_COUNT; i++)
                    {
                        var at = buf + i * Native.NodeSize;
                        int type = Marshal.ReadInt32(at, 0), status = Marshal.ReadInt32(at, 4);
                        var node = new WinWaitNode
                        {
                            Type = type >= 0 && type < Types.Length ? Types[type] : $"type {type}",
                            Status = status >= 0 && status < Statuses.Length ? Statuses[status] : $"status {status}",
                        };
                        if (type == 8) // WctThreadType: the union holds the thread object
                        {
                            node.ProcessId = Marshal.ReadInt32(at, 8); node.ThreadId = Marshal.ReadInt32(at, 12); node.WaitTimeMs = (uint)Marshal.ReadInt32(at, 16);
                        }
                        else
                        {
                            var name = Marshal.PtrToStringUni(at + 8, 128).Split('\0')[0];
                            node.Name = name.Length == 0 ? null : name;
                        }
                        tc.Nodes.Add(node);
                    }
                    chain.Threads.Add(tc);
                }
            }
            finally
            {
                Marshal.FreeHGlobal(buf);
            }
        }
        finally
        {
            Native.CloseThreadWaitChainSession(session);
        }
        chain.Runtime = DetectRuntime(pid);
        return chain;
    }

    /// <summary>
    /// ".NET" when the process owns a dotnet-diagnostic named pipe — every .NET Core process creates
    /// \\.\pipe\dotnet-diagnostic-&lt;pid&gt; (measured: a single-file self-contained app loads coreclr from memory, so
    /// it does NOT show up in the module list, but the pipe is always there).
    /// </summary>
    private static string? DetectRuntime(int pid)
    {
        try
        {
            foreach (var pipe in Directory.GetFiles(@"\\.\pipe\"))
                if (pipe.Contains($"dotnet-diagnostic-{pid}", StringComparison.Ordinal))
                    return ".NET";
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
        return null;
    }

    private static class Native
    {

        public const int WCT_MAX_NODE_COUNT = 16;
        public const uint WCT_OUT_OF_PROC_FLAG = 0x1, WCT_OUT_OF_PROC_COM_FLAG = 0x2, WCT_OUT_OF_PROC_CS_FLAG = 0x4;

        // WAITCHAIN_NODE_INFO: two enums, then a union of LockObject {WCHAR ObjectName[128]; LARGE_INTEGER Timeout; BOOL
        // Alertable} and ThreadObject {DWORD ProcessId, ThreadId, WaitTime, ContextSwitches} — 280 bytes on x64.
        public const int NodeSize = 280;

        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern IntPtr OpenThreadWaitChainSession(uint flags, IntPtr callback);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetThreadWaitChain(IntPtr session, IntPtr context, uint flags, uint threadId, ref int nodeCount,
            IntPtr nodes, [MarshalAs(UnmanagedType.Bool)] out bool isCycle);

        [DllImport("advapi32.dll")]
        public static extern void CloseThreadWaitChainSession(IntPtr session);
    }
}

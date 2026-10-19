using System.Runtime.InteropServices;
using System.ServiceProcess;

// ProbeService.exe --mode=<mode>, registered with sc.exe as a service:
//   exit-specific:<n>  OnStart reports SERVICE_STOPPED with Win32ExitCode 1066 (ERROR_SERVICE_SPECIFIC_ERROR) and
//                      the service-specific exit code <n> — what a real service does when its own config is wrong
//   crash              the process dies with an unhandled exception a few seconds after it reported RUNNING
//                      (SCM event 7034, Application error 1000/1026)
//   hang               OnStart never returns (the SCM leaves it START_PENDING without any event — measured)
//   deadlock           OnStart waits for two threads that each hold one kernel mutex and wait for the other's —
//                      a real deadlock Wait Chain Traversal can see (kernel mutexes, not .NET Monitor locks, which WCT
//                      does not track)
//   run                runs until stopped (the control case)
var mode = args.FirstOrDefault(a => a.StartsWith("--mode=", StringComparison.Ordinal))?["--mode=".Length..] ?? "run";
ServiceBase.Run(new ProbeService(mode));

internal sealed class ProbeService(string mode) : ServiceBase
{
    [StructLayout(LayoutKind.Sequential)]
    private struct SERVICE_STATUS
    {
        public int dwServiceType, dwCurrentState, dwControlsAccepted, dwWin32ExitCode, dwServiceSpecificExitCode,
            dwCheckPoint, dwWaitHint;
    }

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool SetServiceStatus(IntPtr handle, ref SERVICE_STATUS status);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateMutexW(IntPtr attributes, bool initialOwner, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    protected override void OnStart(string[] _)
    {
        if (mode.StartsWith("exit-specific:", StringComparison.Ordinal) && int.TryParse(mode["exit-specific:".Length..], out var code))
        {
            // ServiceBase can only set Win32ExitCode; the service-specific code needs SetServiceStatus itself.
            var st = new SERVICE_STATUS { dwServiceType = 0x10, dwCurrentState = 1 /* STOPPED */, dwWin32ExitCode = 1066, dwServiceSpecificExitCode = code };
            SetServiceStatus(ServiceHandle, ref st);
            Environment.Exit(0);
        }
        else if (mode == "crash")
        {
            new Thread(() => { Thread.Sleep(3000); throw new InvalidOperationException("ProbeService: crash on purpose (--mode=crash)"); }) { IsBackground = false }.Start();
        }
        else if (mode == "hang")
        {
            Thread.Sleep(Timeout.Infinite);
        }
        else if (mode == "deadlock")
        {
            // NATIVE mutexes and WaitForSingleObject: Wait Chain Traversal follows those. .NET's Mutex.WaitOne waits a way
            // WCT does not see — measured: every thread "Blocked" with no object in its chain.
            var a = CreateMutexW(IntPtr.Zero, false, "Global\\yoloman-probe-a");
            var b = CreateMutexW(IntPtr.Zero, false, "Global\\yoloman-probe-b");
            WaitForSingleObject(a, uint.MaxValue);                    // OnStart's thread holds a …
            var ready = new ManualResetEventSlim();
            new Thread(() => { WaitForSingleObject(b, uint.MaxValue); ready.Set(); WaitForSingleObject(a, uint.MaxValue); }) { IsBackground = false }.Start();
            ready.Wait();
            WaitForSingleObject(b, uint.MaxValue);                    // … and waits for b, which the other thread holds while it waits for a
        }
    }
}

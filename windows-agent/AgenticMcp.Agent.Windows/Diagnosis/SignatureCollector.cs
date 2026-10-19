using System.Runtime.InteropServices;
using System.Security.Cryptography.X509Certificates;

namespace AgenticMcp.Agent.Windows.Diagnosis;

/// <summary>
/// The Authenticode trust of a file — the TrustCollector the plan named (B6), native (WinVerifyTrust), so it is
/// synchronous and needs no PowerShell. Read-only context for every diagnosis, and the usual reason a service image
/// is blocked by AppLocker or Code Integrity (svc.blocked_by_policy).
///
/// <para>Windows system binaries carry NO embedded signature — they are signed through a security CATALOG (measured:
/// cmd.exe is "unsigned" to an embedded-only check but trusted via its catalog). So the catalog is tried first (SHA256,
/// then SHA1 for older catalogs); only a file in neither is really unsigned.</para>
/// </summary>
public static class SignatureCollector
{
    private static readonly Guid WINTRUST_ACTION_GENERIC_VERIFY_V2 = new("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");

    public static (string Status, string? Signer) Verify(string path)
    {
        if (!File.Exists(path)) return ("not a file", null);
        foreach (var algo in new[] { "SHA256", "SHA1" })
            if (VerifyByCatalog(path, algo) is { } cat)
                return cat;
        var (status, signer) = VerifyEmbedded(path);
        // No embedded signature AND no catalog match found here — report it honestly rather than as a flat "not signed":
        // a catalog lookup can fail for reasons other than the file being untrusted, so this does not claim more than
        // was verified (a genuinely unsigned third-party exe reads the same, which is correct).
        if (status == "unsigned") return ("no embedded signature (not confirmed against the security catalog)", null);
        return (status, signer);
    }

    private static (string Status, string? Signer)? VerifyByCatalog(string path, string algo)
    {
        var hFile = Native.CreateFileW(path, 0x80000000, 0x1, IntPtr.Zero, 3, 0x80, IntPtr.Zero);
        if (hFile == new IntPtr(-1)) return null;
        IntPtr hCatAdmin = IntPtr.Zero;
        try
        {
            if (!Native.CryptCATAdminAcquireContext2(out hCatAdmin, IntPtr.Zero, algo, IntPtr.Zero, 0) || hCatAdmin == IntPtr.Zero)
                return null;
            uint cb = algo == "SHA256" ? 32u : 20u;   // the hash size is fixed per algorithm; no size-query (its semantics vary)
            var pHash = Marshal.AllocHGlobal((int)cb);
            try
            {
                if (!Native.CryptCATAdminCalcHashFromFileHandle2(hCatAdmin, hFile, ref cb, pHash, 0)) return null;
                var hCat = Native.CryptCATAdminEnumCatalogFromHash(hCatAdmin, pHash, cb, 0, IntPtr.Zero);
                if (hCat == IntPtr.Zero) return null;   // no catalog covers this file under this algorithm
                try
                {
                    var info = new Native.CATALOG_INFO { cbStruct = (uint)Marshal.SizeOf<Native.CATALOG_INFO>() };
                    if (!Native.CryptCATCatalogInfoFromContext(hCat, ref info, 0)) return null;
                    var bytes = new byte[cb];
                    Marshal.Copy(pHash, bytes, 0, (int)cb);
                    var status = VerifyCatalogTrust(info.wszCatalogFile, path, Convert.ToHexString(bytes), pHash, cb);
                    // Only a genuine "valid" from the catalog is reported. Any other result here is treated as inconclusive
                    // (fall through to the honest "not confirmed" message) rather than reported as untrusted: a non-valid
                    // result can be my own member-matching, not the file's trust, and the diagnosis must not claim more.
                    if (status != "valid") return null;
                    string? signer = null;
                    try { signer = SignerSubject(info.wszCatalogFile); } catch { }
                    return ("valid (catalog)", signer);
                }
                finally { Native.CryptCATAdminReleaseCatalogContext(hCatAdmin, hCat, 0); }
            }
            finally { Marshal.FreeHGlobal(pHash); }
        }
        finally
        {
            if (hCatAdmin != IntPtr.Zero) Native.CryptCATAdminReleaseContext(hCatAdmin, 0);
            Native.CloseHandle(hFile);
        }
    }

    private static string VerifyCatalogTrust(string catalogFile, string memberFile, string memberTag, IntPtr pHash, uint cbHash)
    {
        var cat = new Native.WINTRUST_CATALOG_INFO
        {
            cbStruct = (uint)Marshal.SizeOf<Native.WINTRUST_CATALOG_INFO>(),
            pcwszCatalogFilePath = catalogFile, pcwszMemberTag = memberTag, pcwszMemberFilePath = memberFile,
            pbCalculatedFileHash = pHash, cbCalculatedFileHash = cbHash,
        };
        var pCat = Marshal.AllocHGlobal((int)cat.cbStruct);
        try
        {
            Marshal.StructureToPtr(cat, pCat, false);
            var data = new Native.WINTRUST_DATA
            {
                cbStruct = (uint)Marshal.SizeOf<Native.WINTRUST_DATA>(), dwUIChoice = 2, fdwRevocationChecks = 0,
                dwUnionChoice = 2 /*WTD_CHOICE_CATALOG*/, pFile = pCat, dwStateAction = 1, dwProvFlags = 0x10,
            };
            var action = WINTRUST_ACTION_GENERIC_VERIFY_V2;
            var rc = Native.WinVerifyTrust(IntPtr.Zero, ref action, ref data);
            data.dwStateAction = 2;
            Native.WinVerifyTrust(IntPtr.Zero, ref action, ref data);
            return StatusOf(rc);
        }
        finally { Marshal.FreeHGlobal(pCat); }
    }

    private static (string Status, string? Signer) VerifyEmbedded(string path)
    {
        var file = new Native.WINTRUST_FILE_INFO { cbStruct = (uint)Marshal.SizeOf<Native.WINTRUST_FILE_INFO>(), pcwszFilePath = path };
        var pFile = Marshal.AllocHGlobal((int)file.cbStruct);
        try
        {
            Marshal.StructureToPtr(file, pFile, false);
            var data = new Native.WINTRUST_DATA
            {
                cbStruct = (uint)Marshal.SizeOf<Native.WINTRUST_DATA>(), dwUIChoice = 2, fdwRevocationChecks = 0,
                dwUnionChoice = 1 /*WTD_CHOICE_FILE*/, pFile = pFile, dwStateAction = 1, dwProvFlags = 0x10,
            };
            var action = WINTRUST_ACTION_GENERIC_VERIFY_V2;
            var rc = Native.WinVerifyTrust(IntPtr.Zero, ref action, ref data);
            data.dwStateAction = 2;
            Native.WinVerifyTrust(IntPtr.Zero, ref action, ref data);
            string? signer = null;
            if (rc == 0) { try { signer = SignerSubject(path); } catch { } }
            return (StatusOf(rc), signer);
        }
        finally { Marshal.FreeHGlobal(pFile); }
    }

    private static string StatusOf(int rc) => unchecked((uint)rc) switch
    {
        0 => "valid",
        0x800B0100 => "unsigned",
        0x800B0101 => "untrusted: the signing certificate has expired",
        0x800B010C => "untrusted: the signature was explicitly distrusted",
        0x800B010A or 0x800B0109 => "untrusted: the certificate chain does not end in a trusted root",
        0x80096010 => "untrusted: the file has been changed since it was signed (bad digest)",
        _ => $"untrusted: 0x{unchecked((uint)rc):X8}",
    };

    private static string? SignerSubject(string path)
    {
#pragma warning disable SYSLIB0057
        using var cert = new X509Certificate2(X509Certificate.CreateFromSignedFile(path));
#pragma warning restore SYSLIB0057
        return cert.Subject;
    }

    private static class Native
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct WINTRUST_FILE_INFO
        {
            public uint cbStruct;
            [MarshalAs(UnmanagedType.LPWStr)] public string pcwszFilePath;
            public IntPtr hFile;
            public IntPtr pgKnownSubject;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct WINTRUST_DATA
        {
            public uint cbStruct;
            public IntPtr pPolicyCallbackData;
            public IntPtr pSIPClientData;
            public uint dwUIChoice;
            public uint fdwRevocationChecks;
            public uint dwUnionChoice;
            public IntPtr pFile;
            public uint dwStateAction;
            public IntPtr hWVTStateData;
            public IntPtr pwszURLReference;
            public uint dwProvFlags;
            public uint dwUIContext;
            public IntPtr pSignatureSettings;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct WINTRUST_CATALOG_INFO
        {
            public uint cbStruct;
            public uint dwCatalogVersion;
            [MarshalAs(UnmanagedType.LPWStr)] public string pcwszCatalogFilePath;
            [MarshalAs(UnmanagedType.LPWStr)] public string pcwszMemberTag;
            [MarshalAs(UnmanagedType.LPWStr)] public string pcwszMemberFilePath;
            public IntPtr hMemberFile;
            public IntPtr pbCalculatedFileHash;
            public uint cbCalculatedFileHash;
            public IntPtr pcCatalogContext;
            public IntPtr hCatAdmin;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct CATALOG_INFO
        {
            public uint cbStruct;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string wszCatalogFile;
        }

        [DllImport("wintrust.dll", SetLastError = true)]
        public static extern int WinVerifyTrust(IntPtr hwnd, ref Guid action, ref WINTRUST_DATA data);

        [DllImport("wintrust.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CryptCATAdminAcquireContext2(out IntPtr hCatAdmin, IntPtr pgSubsystem, [MarshalAs(UnmanagedType.LPWStr)] string hashAlgorithm, IntPtr strongHashPolicy, uint flags);

        [DllImport("wintrust.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CryptCATAdminCalcHashFromFileHandle2(IntPtr hCatAdmin, IntPtr hFile, ref uint cbHash, IntPtr pbHash, uint flags);

        [DllImport("wintrust.dll", SetLastError = true)]
        public static extern IntPtr CryptCATAdminEnumCatalogFromHash(IntPtr hCatAdmin, IntPtr pbHash, uint cbHash, uint flags, IntPtr prevCatInfo);

        [DllImport("wintrust.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CryptCATCatalogInfoFromContext(IntPtr hCatInfo, ref CATALOG_INFO psCatInfo, uint flags);

        [DllImport("wintrust.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CryptCATAdminReleaseCatalogContext(IntPtr hCatAdmin, IntPtr hCatInfo, uint flags);

        [DllImport("wintrust.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CryptCATAdminReleaseContext(IntPtr hCatAdmin, uint flags);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern IntPtr CreateFileW(string path, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CloseHandle(IntPtr h);
    }
}

using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using AgenticMcp.Agent.Diagnosis;

namespace AgenticMcp.Agent.Windows.Diagnosis;

/// <summary>
/// The service account and what it may do — LookupAccountName (does it exist, which kind), NetUserGetInfo for a
/// LOCAL account (disabled, locked out, password expired), LsaEnumerateAccountRights for the account and its local
/// groups (SeServiceLogonRight, SeDenyServiceLogonRight), and AuthzAccessCheck of its SID on the image and its folder.
/// Documented interfaces only; what they cannot answer (a domain account's groups without the domain controller,
/// a managed service account's rights) is left null with the reason in <c>gap</c> — never guessed.
/// </summary>
public static class AccountCollector
{
    private const uint FILE_EXECUTE = 0x20;
    private const uint FILE_READ_DATA = 0x1;
    private const uint FILE_TRAVERSE = 0x20;
    private const uint FILE_LIST_DIRECTORY = 0x1;

    public static WinAccount Account(string serviceStartName)
    {
        var name = string.IsNullOrEmpty(serviceStartName) ? "LocalSystem" : serviceStartName;
        var acct = new WinAccount { Name = name };
        var builtin = name.ToUpperInvariant() switch
        {
            "LOCALSYSTEM" or @"NT AUTHORITY\SYSTEM" or ".\\LOCALSYSTEM" => ("local-system", "S-1-5-18"),
            @"NT AUTHORITY\LOCALSERVICE" or @"NT AUTHORITY\LOCAL SERVICE" => ("local-service", "S-1-5-19"),
            @"NT AUTHORITY\NETWORKSERVICE" or @"NT AUTHORITY\NETWORK SERVICE" => ("network-service", "S-1-5-20"),
            _ => ((string, string)?)null,
        };
        if (builtin is { } b)
        {
            // The three built-in service accounts hold the service logon right by construction and have no password.
            acct.Kind = b.Item1;
            acct.Sid = b.Item2;
            acct.ServiceLogonRight = true;
            acct.DenyServiceLogonRight = false;
            return acct;
        }
        SecurityIdentifier sid;
        try
        {
            var lookup = name.StartsWith(@".\") ? Environment.MachineName + name[1..] : name;
            sid = (SecurityIdentifier)new NTAccount(lookup).Translate(typeof(SecurityIdentifier));
        }
        catch (IdentityNotMappedException)
        {
            acct.Kind = "unresolved";
            return acct;
        }
        acct.Sid = sid.Value;
        var domain = name.Contains('\\') ? name[..name.IndexOf('\\')] : ".";
        var user = name.Contains('\\') ? name[(name.IndexOf('\\') + 1)..] : name;
        if (domain.Equals("NT SERVICE", StringComparison.OrdinalIgnoreCase))
        {
            acct.Kind = "virtual";
            acct.Gap = "a virtual service account (NT SERVICE\\…) has no SAM entry and its rights come from the service itself";
            return acct;
        }
        if (user.EndsWith('$'))
        {
            acct.Kind = "managed";
            acct.Gap = "a (group) managed service account's state lives in Active Directory, not readable without the domain controller";
            return acct;
        }
        var isLocal = domain == "." || domain.Equals(Environment.MachineName, StringComparison.OrdinalIgnoreCase);
        acct.Kind = isLocal ? "local" : "domain";
        if (isLocal)
            LocalState(user, acct);
        else
            acct.Gap = "a domain account's state and group rights need the domain controller; only its directly granted rights were read";
        Rights(sid, isLocal ? LocalGroups(user) : [], acct);
        return acct;
    }

    private static void LocalState(string user, WinAccount acct)
    {
        if (Native.NetUserGetInfo(null, user, 4, out var buf) != 0)
        {
            acct.Gap = "NetUserGetInfo refused to read the account";
            return;
        }
        try
        {
            var flags = Marshal.ReadInt32(buf, Marshal.OffsetOf<Native.USER_INFO_4>(nameof(Native.USER_INFO_4.usri4_flags)).ToInt32());
            var expired = Marshal.ReadInt32(buf, Marshal.OffsetOf<Native.USER_INFO_4>(nameof(Native.USER_INFO_4.usri4_password_expired)).ToInt32());
            acct.Disabled = (flags & 0x0002) != 0;      // UF_ACCOUNTDISABLE
            acct.LockedOut = (flags & 0x0010) != 0;     // UF_LOCKOUT
            acct.PasswordExpired = expired != 0;
        }
        finally
        {
            Native.NetApiBufferFree(buf);
        }
    }

    private static List<SecurityIdentifier> LocalGroups(string user)
    {
        var groups = new List<SecurityIdentifier>();
        if (Native.NetUserGetLocalGroups(null, user, 0, 0, out var buf, -1, out var read, out _) != 0) return groups;
        try
        {
            for (var i = 0; i < read; i++)
            {
                var name = Marshal.PtrToStringUni(Marshal.ReadIntPtr(buf, i * IntPtr.Size));
                if (name is null) continue;
                try { groups.Add((SecurityIdentifier)new NTAccount(name).Translate(typeof(SecurityIdentifier))); }
                catch (IdentityNotMappedException) { }
            }
        }
        finally
        {
            Native.NetApiBufferFree(buf);
        }
        // Every account is also in Everyone and Authenticated Users; rights granted to those count too.
        groups.Add(new SecurityIdentifier(WellKnownSidType.WorldSid, null));
        groups.Add(new SecurityIdentifier(WellKnownSidType.AuthenticatedUserSid, null));
        return groups;
    }

    private static void Rights(SecurityIdentifier sid, List<SecurityIdentifier> groups, WinAccount acct)
    {
        var attrs = new Native.LSA_OBJECT_ATTRIBUTES { Length = Marshal.SizeOf<Native.LSA_OBJECT_ATTRIBUTES>() };
        if (Native.LsaOpenPolicy(IntPtr.Zero, ref attrs, 0x00000800 /* POLICY_LOOKUP_NAMES */, out var policy) != 0)
        {
            acct.Gap = (acct.Gap is null ? "" : acct.Gap + "; ") + "LsaOpenPolicy was refused";
            return;
        }
        try
        {
            bool? logon = false, deny = false;
            foreach (var who in new[] { sid }.Concat(groups))
            {
                var rights = AccountRights(policy, who);
                if (rights.Contains("SeServiceLogonRight")) { logon = true; acct.RightsVia.Add($"SeServiceLogonRight via {Name(who)}"); }
                if (rights.Contains("SeDenyServiceLogonRight")) { deny = true; acct.RightsVia.Add($"SeDenyServiceLogonRight via {Name(who)}"); }
            }
            acct.ServiceLogonRight = logon;
            acct.DenyServiceLogonRight = deny;
        }
        finally
        {
            Native.LsaClose(policy);
        }
    }

    private static HashSet<string> AccountRights(IntPtr policy, SecurityIdentifier who)
    {
        var bytes = new byte[who.BinaryLength];
        who.GetBinaryForm(bytes, 0);
        var set = new HashSet<string>();
        if (Native.LsaEnumerateAccountRights(policy, bytes, out var buf, out var count) != 0) return set;   // no rights = NOT_FOUND
        try
        {
            var size = Marshal.SizeOf<Native.LSA_UNICODE_STRING>();
            for (var i = 0; i < count; i++)
            {
                var s = Marshal.PtrToStructure<Native.LSA_UNICODE_STRING>(buf + i * size);
                set.Add(Marshal.PtrToStringUni(s.Buffer, s.Length / 2));
            }
        }
        finally
        {
            Native.LsaFreeMemory(buf);
        }
        return set;
    }

    private static string Name(SecurityIdentifier sid)
    {
        try { return sid.Translate(typeof(NTAccount)).Value; } catch (IdentityNotMappedException) { return sid.Value; }
    }

    /// <summary>
    /// AuthzAccessCheck of the account's SID on a path for the rights the service needs. A denied check names the
    /// ACE that denies (an explicit Deny for the SID or one of its groups) or says that no ACE grants it.
    /// </summary>
    public static WinAccess Access(string path, WinAccount acct, bool directory)
    {
        var desired = directory ? FILE_TRAVERSE | FILE_LIST_DIRECTORY : FILE_EXECUTE | FILE_READ_DATA;
        var a = new WinAccess { Path = path, Sid = acct.Sid ?? "", Desired = directory ? "traverse+list" : "execute+read" };
        if (acct.Sid is null) { a.Gap = "the account has no resolvable SID"; return a; }
        if (acct.Kind is "local-system") { a.Granted = true; return a; }
        if (!File.Exists(path) && !Directory.Exists(path)) { a.Gap = "the path does not exist"; return a; }
        FileSystemSecurity sec = directory ? new DirectoryInfo(path).GetAccessControl() : new FileInfo(path).GetAccessControl();
        a.Sddl = sec.GetSecurityDescriptorSddlForm(AccessControlSections.Access);
        var sd = sec.GetSecurityDescriptorBinaryForm();
        var sidBytes = new byte[new SecurityIdentifier(acct.Sid).BinaryLength];
        new SecurityIdentifier(acct.Sid).GetBinaryForm(sidBytes, 0);
        if (!Native.AuthzInitializeResourceManager(1 /* NO_AUDIT */, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, null, out var rm))
        {
            a.Gap = "AuthzInitializeResourceManager failed";
            return a;
        }
        try
        {
            if (!Native.AuthzInitializeContextFromSid(0, sidBytes, rm, IntPtr.Zero, default, IntPtr.Zero, out var ctx))
            {
                // A domain SID whose groups cannot be expanded without the domain controller lands here.
                a.Gap = $"AuthzInitializeContextFromSid failed (error {Marshal.GetLastWin32Error()}) — the account's groups could not be resolved";
                return a;
            }
            try
            {
                var req = new Native.AUTHZ_ACCESS_REQUEST { DesiredAccess = desired };
                var granted = new uint[1];
                var error = new uint[1];
                var reply = new Native.AUTHZ_ACCESS_REPLY
                {
                    ResultListLength = 1,
                    GrantedAccessMask = Marshal.UnsafeAddrOfPinnedArrayElement(granted, 0),
                    Error = Marshal.UnsafeAddrOfPinnedArrayElement(error, 0),
                };
                var gh1 = GCHandle.Alloc(granted, GCHandleType.Pinned);
                var gh2 = GCHandle.Alloc(error, GCHandleType.Pinned);
                try
                {
                    if (!Native.AuthzAccessCheck(0, ctx, ref req, IntPtr.Zero, sd, null, 0, ref reply, IntPtr.Zero))
                    {
                        a.Gap = $"AuthzAccessCheck failed (error {Marshal.GetLastWin32Error()})";
                        return a;
                    }
                }
                finally
                {
                    gh1.Free();
                    gh2.Free();
                }
                a.Granted = error[0] == 0 && (granted[0] & desired) == desired;
                if (a.Granted == false)
                    a.DenyingAce = DenyingAce(sec, acct) ?? "no ACE grants it (no Allow entry for the account or its groups covers these rights)";
            }
            finally
            {
                Native.AuthzFreeContext(ctx);
            }
        }
        finally
        {
            Native.AuthzFreeResourceManager(rm);
        }
        return a;
    }

    private static string? DenyingAce(FileSystemSecurity sec, WinAccount acct)
    {
        var sid = new SecurityIdentifier(acct.Sid!);
        foreach (FileSystemAccessRule r in sec.GetAccessRules(true, true, typeof(SecurityIdentifier)))
        {
            if (r.AccessControlType != AccessControlType.Deny) continue;
            var who = (SecurityIdentifier)r.IdentityReference;
            if (who == sid || who.IsWellKnown(WellKnownSidType.WorldSid) || who.IsWellKnown(WellKnownSidType.AuthenticatedUserSid)
                || who.IsWellKnown(WellKnownSidType.BuiltinUsersSid))
                return $"Deny {r.FileSystemRights} for {Name(who)}{(r.IsInherited ? " (inherited)" : "")}";
        }
        return null;
    }

    private static class Native
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct USER_INFO_4
        {
            public IntPtr usri4_name, usri4_password;
            public int usri4_password_age, usri4_priv;
            public IntPtr usri4_home_dir, usri4_comment;
            public int usri4_flags;
            public IntPtr usri4_script_path;
            public int usri4_auth_flags;
            public IntPtr usri4_full_name, usri4_usr_comment, usri4_parms, usri4_workstations;
            public int usri4_last_logon, usri4_last_logoff, usri4_acct_expires, usri4_max_storage, usri4_units_per_week;
            public IntPtr usri4_logon_hours;
            public int usri4_bad_pw_count, usri4_num_logons;
            public IntPtr usri4_logon_server;
            public int usri4_country_code, usri4_code_page;
            public IntPtr usri4_user_sid;
            public int usri4_primary_group_id;
            public IntPtr usri4_profile, usri4_home_dir_drive;
            public int usri4_password_expired;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct LSA_OBJECT_ATTRIBUTES
        {
            public int Length;
            public IntPtr RootDirectory, ObjectName;
            public int Attributes;
            public IntPtr SecurityDescriptor, SecurityQualityOfService;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct LSA_UNICODE_STRING
        {
            public ushort Length, MaximumLength;
            public IntPtr Buffer;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct AUTHZ_ACCESS_REQUEST
        {
            public uint DesiredAccess;
            public IntPtr PrincipalSelfSid, ObjectTypeList;
            public uint ObjectTypeListLength;
            public IntPtr OptionalArguments;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct AUTHZ_ACCESS_REPLY
        {
            public uint ResultListLength;
            public IntPtr GrantedAccessMask, SaclEvaluationResults, Error;
        }

        [DllImport("netapi32.dll", CharSet = CharSet.Unicode)]
        public static extern int NetUserGetInfo(string? server, string user, int level, out IntPtr buf);

        [DllImport("netapi32.dll", CharSet = CharSet.Unicode)]
        public static extern int NetUserGetLocalGroups(string? server, string user, int level, int flags, out IntPtr buf,
            int prefmaxlen, out int entriesRead, out int totalEntries);

        [DllImport("netapi32.dll")]
        public static extern int NetApiBufferFree(IntPtr buf);

        [DllImport("advapi32.dll")]
        public static extern uint LsaOpenPolicy(IntPtr system, ref LSA_OBJECT_ATTRIBUTES attrs, int access, out IntPtr policy);

        [DllImport("advapi32.dll")]
        public static extern uint LsaEnumerateAccountRights(IntPtr policy, byte[] sid, out IntPtr rights, out int count);

        [DllImport("advapi32.dll")]
        public static extern uint LsaFreeMemory(IntPtr buf);

        [DllImport("advapi32.dll")]
        public static extern uint LsaClose(IntPtr policy);

        [DllImport("authz.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool AuthzInitializeResourceManager(int flags, IntPtr access, IntPtr compute, IntPtr free,
            string? name, out IntPtr rm);

        [DllImport("authz.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool AuthzInitializeContextFromSid(int flags, byte[] sid, IntPtr rm, IntPtr expiration,
            long identifier, IntPtr dynamicGroupArgs, out IntPtr context);

        [DllImport("authz.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool AuthzAccessCheck(int flags, IntPtr context, ref AUTHZ_ACCESS_REQUEST request,
            IntPtr auditEvent, byte[] securityDescriptor, IntPtr[]? optionalSds, int optionalCount,
            ref AUTHZ_ACCESS_REPLY reply, IntPtr accessCheckResults);

        [DllImport("authz.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool AuthzFreeContext(IntPtr context);

        [DllImport("authz.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool AuthzFreeResourceManager(IntPtr rm);
    }
}

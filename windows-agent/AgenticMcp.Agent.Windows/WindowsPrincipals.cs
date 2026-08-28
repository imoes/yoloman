using System.Security.Principal;

namespace AgenticMcp.Agent.Windows;

/// <summary>
/// Turning the name of a well-known principal into the one THIS host accepts.
///
/// <para>MEASURED, and it stopped a share dead: `New-SmbShare -ReadAccess "Everyone"` on a German Windows
/// answers <c>"Zuordnungen von Kontennamen und Sicherheitskennungen wurden nicht durchgeführt"</c> — no mapping
/// between account names and security IDs — because the account is called <b>Jeder</b> there. Same for
/// Administrators (<b>Administratoren</b>), Users (<b>Benutzer</b>), Authenticated Users
/// (<b>Authentifizierte Benutzer</b>). A fleet cannot be managed with names that change per installation
/// language, and asking the operator to write the German name would make the policy unusable on the next host.</para>
///
/// <para>THE SID IS THE IDENTITY, the name is a rendering of it. Every well-known principal has a fixed SID —
/// Everyone is S-1-1-0 on every Windows ever shipped — so a declaration is translated through the SID into
/// whatever this host calls it. Windows does the translation itself (SecurityIdentifier → NTAccount), so the
/// answer is the host's own spelling and not a table of ours that would rot.</para>
///
/// <para>WHAT IS NOT TOUCHED: anything that is not a well-known principal. A domain account, a local user, a
/// group somebody created — those names are already what they are, and rewriting them would be this class
/// guessing. Unknown input passes through unchanged, and the module's own error carries the host's words if it
/// turns out to be wrong.</para>
/// </summary>
internal static class WindowsPrincipals
{
    /// <summary>The well-known principals a fleet actually names, by the English name and by SID string.
    /// Kept to the ones that appear in real declarations rather than the full 60-odd enum: each entry here is
    /// a promise that this translation is correct, and a wrong entry would be worse than an absent one.</summary>
    private static readonly Dictionary<string, WellKnownSidType> WellKnown =
        new(StringComparer.OrdinalIgnoreCase)
        {
            ["Everyone"] = WellKnownSidType.WorldSid,
            ["Administrators"] = WellKnownSidType.BuiltinAdministratorsSid,
            ["Users"] = WellKnownSidType.BuiltinUsersSid,
            ["Guests"] = WellKnownSidType.BuiltinGuestsSid,
            ["Power Users"] = WellKnownSidType.BuiltinPowerUsersSid,
            ["Remote Desktop Users"] = WellKnownSidType.BuiltinRemoteDesktopUsersSid,
            ["Authenticated Users"] = WellKnownSidType.AuthenticatedUserSid,
            ["SYSTEM"] = WellKnownSidType.LocalSystemSid,
            ["LocalSystem"] = WellKnownSidType.LocalSystemSid,
            ["Local Service"] = WellKnownSidType.LocalServiceSid,
            ["Network Service"] = WellKnownSidType.NetworkServiceSid,
            ["Creator Owner"] = WellKnownSidType.CreatorOwnerSid,
            ["Interactive"] = WellKnownSidType.InteractiveSid,
        };

    /// <summary>
    /// The name this host accepts for <paramref name="principal"/>, or the input unchanged when it is not a
    /// well-known principal (or when Windows cannot translate it, which is a fact about the host and not
    /// something to hide behind a substitute).
    /// </summary>
    internal static string Resolve(string principal)
    {
        var name = (principal ?? "").Trim();
        if (name.Length == 0)
        {
            return name;
        }

        try
        {
            // A SID written out (S-1-5-32-544) is accepted too: it is the most precise thing a caller can say,
            // and refusing it would push them back to names.
            if (name.StartsWith("S-1-", StringComparison.OrdinalIgnoreCase))
            {
                return ((NTAccount)new SecurityIdentifier(name).Translate(typeof(NTAccount))).Value;
            }
            if (WellKnown.TryGetValue(name, out var wellKnown))
            {
                var sid = new SecurityIdentifier(wellKnown, null);
                return ((NTAccount)sid.Translate(typeof(NTAccount))).Value;
            }
        }
        catch (Exception)
        {
            // IdentityNotMappedException on a host that genuinely has no such principal, and any of the
            // platform's own failures. Passed through unchanged rather than swallowed: the module that uses
            // this will hand the name to Windows and report Windows' own refusal, which says more than a
            // guess made here.
        }

        return name;
    }

    /// <summary>Resolve a list, keeping order and dropping nothing.</summary>
    internal static List<string> Resolve(IEnumerable<string> principals) =>
        principals.Select(Resolve).ToList();

    /// <summary>Do two principal spellings name the same account? True when equal, when equal after the last
    /// backslash, or when both resolve to the same host-local name — so "Everyone", "Jeder" and
    /// "S-1-1-0" compare equal on a German host, which is what makes an idempotence check work there.</summary>
    internal static bool Same(string one, string other)
    {
        static string Leaf(string value)
        {
            var cut = value.LastIndexOf('\\');
            return cut >= 0 ? value[(cut + 1)..] : value;
        }
        if (string.Equals(one, other, StringComparison.OrdinalIgnoreCase)
            || string.Equals(Leaf(one), Leaf(other), StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }
        var resolvedOne = Resolve(one);
        var resolvedTwo = Resolve(other);
        return string.Equals(resolvedOne, resolvedTwo, StringComparison.OrdinalIgnoreCase)
               || string.Equals(Leaf(resolvedOne), Leaf(resolvedTwo), StringComparison.OrdinalIgnoreCase);
    }
}

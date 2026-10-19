using AgenticMcp.Agent.Core;
using Xunit;

namespace AgenticMcp.Agent.Tests;

/// <summary>
/// The bypass rule .NET cannot read. Measured on bossman-wintest: NO_PROXY held
/// `localhost,127.0.0.1,.example.internal,192.0.2.0/24`, an installer at 192.0.2.130 was proxied anyway and the
/// proxy answered 503, while curl.exe with the same environment got 200 because it understands the CIDR.
///
/// These tests set NO_PROXY in the process environment and exercise the parse, because the interesting half
/// is the MATCHING and it needs no network at all.
/// </summary>
public class ProxyPolicyTests
{
    private static bool Bypassed(string noProxy, string host)
    {
        // Safe to set per case: the policy re-parses whenever the raw variable changes (it was a
        // static-readonly parsed once, and these tests would then all have run against the first case's list).
        Environment.SetEnvironmentVariable("NO_PROXY", noProxy);
        return ProxyPolicy.IsBypassed(host);
    }

    [Fact]
    public void Loopback_is_always_direct()
    {
        Assert.True(ProxyPolicy.IsBypassed("127.0.0.1"));
        Assert.True(ProxyPolicy.IsBypassed("localhost"));
    }

    [Fact]
    public void An_ip_inside_a_cidr_entry_is_direct()
    {
        // THE measured case: 192.0.2.130 inside 192.0.2.0/24.
        Assert.True(Bypassed("localhost,127.0.0.1,.example.internal,192.0.2.0/24", "192.0.2.130"));
    }

    [Fact]
    public void An_ip_outside_every_cidr_entry_is_proxied()
    {
        Assert.False(Bypassed("192.0.2.0/24", "10.99.1.1"));
        Assert.False(Bypassed("192.0.2.0/24", "93.184.216.34"));
    }

    [Fact]
    public void Suffix_entries_keep_working_in_all_three_spellings()
    {
        Assert.True(Bypassed(".example.internal", "repo.example.internal"));
        Assert.True(Bypassed(".example.internal", "example.internal"));
        Assert.True(Bypassed("*.example.internal", "repo.example.internal"));
        Assert.True(Bypassed("example.com", "example.com"));
        Assert.False(Bypassed("example.com", "notexample.com"));
    }

    [Fact]
    public void A_cidr_does_not_match_a_host_name_by_accident()
    {
        // The old behaviour compared the CIDR as a literal string against the host name. Nothing must match
        // that way, in either direction.
        Assert.False(Bypassed("192.0.2.0/24", "192.0.2.0/24"));
        Assert.False(Bypassed("192.0.2.0/24", "repo.example.internal"));
    }
}

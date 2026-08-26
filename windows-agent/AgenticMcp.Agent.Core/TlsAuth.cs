using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace AgenticMcp.Agent.Core;

/// <summary>
/// Client-certificate authorisation: the authorized_keys model over TLS, ported from the Go agent's
/// <c>internal/tlsauth</c>.
///
/// <para>The pin is the DER-encoded PKIX <c>SubjectPublicKeyInfo</c> of the presented certificate's public
/// key, compared byte for byte against the key Bossman handed over at enrolment. Not the certificate, not
/// the subject, not a fingerprint of the whole cert: Bossman may re-issue its certificate around the same
/// key, and pinning the cert would break a rotation that changed nothing about the identity.</para>
///
/// <para>The agent's own server certificate is self-signed on purpose. Bossman polls with
/// <c>verify=False</c> (see <c>services/agent_client.py</c>) because it authorises the agent by the bearer
/// token and its own client certificate, not by a CA chain — so a CA here would be ceremony that nothing
/// checks.</para>
/// </summary>
public static class TlsAuth
{
    /// <summary>A public key this agent will accept a client certificate for, with a name for the audit log.</summary>
    public sealed record TrustedKey(string Name, byte[] SubjectPublicKeyInfo);

    /// <summary>
    /// Reads a PEM-encoded PKIX public key — exactly what <c>POST /api/v1/enroll</c> returns as
    /// <c>bossman_public_key</c>. A PEM "PUBLIC KEY" body IS the SPKI DER, so this is a decode and not a
    /// re-encode: nothing about the key is reinterpreted on the way in.
    /// </summary>
    public static TrustedKey LoadTrustedKeyPem(string name, string pem)
    {
        var der = ExtractPemBody(pem, "PUBLIC KEY")
                  ?? throw new FormatException($"public key {name}: no PEM PUBLIC KEY block");
        // Parsed once to fail loudly here rather than on the first connection: a malformed pin must be a
        // startup error, not a permanent, silent 403.
        try
        {
            EnsureParsable(der);
        }
        catch (CryptographicException ex)
        {
            throw new FormatException($"public key {name}: not a PKIX SubjectPublicKeyInfo", ex);
        }

        return new TrustedKey(name, der);
    }

    private static void EnsureParsable(byte[] der)
    {
        // Algorithm-agnostic: try each family the fleet's keys can be, and accept the one that parses. The
        // comparison later is over raw SPKI bytes, so which family it was does not matter afterwards.
        foreach (var factory in new Func<AsymmetricAlgorithm>[] { ECDsa.Create, RSA.Create })
        {
            using var alg = factory();
            try
            {
                alg.ImportSubjectPublicKeyInfo(der, out _);
                return;
            }
            catch (CryptographicException)
            {
                // try the next family
            }
        }

        throw new CryptographicException("neither an EC nor an RSA SubjectPublicKeyInfo");
    }

    /// <summary>Whether this certificate's public key is one of the pins.</summary>
    public static bool MatchesAny(X509Certificate2 presented, IReadOnlyList<TrustedKey> pins, out TrustedKey? matched)
    {
        var spki = presented.PublicKey.ExportSubjectPublicKeyInfo();
        foreach (var pin in pins)
        {
            // Fixed-time comparison. These are public keys, so there is no secret to leak — but a
            // short-circuiting compare in an authorisation path is the kind of detail that gets copied into
            // one where there is.
            if (CryptographicOperations.FixedTimeEquals(spki, pin.SubjectPublicKeyInfo))
            {
                matched = pin;
                return true;
            }
        }

        matched = null;
        return false;
    }

    /// <summary>
    /// Returns the agent's TLS server certificate, creating a self-signed ECDSA P-256 one at
    /// <paramref name="pfxPath"/> if it is missing. Ten-year validity, matching the Go agent's
    /// <c>EnsureSelfSigned</c>: an expiry nobody renews is an outage scheduled for a date nobody remembers.
    /// </summary>
    public static X509Certificate2 EnsureServerCertificate(string pfxPath, string commonName)
    {
        if (File.Exists(pfxPath))
        {
            return X509CertificateLoader.LoadPkcs12FromFile(pfxPath, null,
                X509KeyStorageFlags.EphemeralKeySet);
        }

        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var request = new CertificateRequest($"CN={commonName}", key, HashAlgorithmName.SHA256);
        request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
        request.CertificateExtensions.Add(new X509KeyUsageExtension(
            X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment, true));
        request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(
            [new Oid("1.3.6.1.5.5.7.3.1")], false)); // serverAuth

        using var created = request.CreateSelfSigned(
            DateTimeOffset.UtcNow.AddHours(-1), DateTimeOffset.UtcNow.AddYears(10));

        var directory = Path.GetDirectoryName(pfxPath);
        if (!string.IsNullOrEmpty(directory))
        {
            Directory.CreateDirectory(directory);
        }

        File.WriteAllBytes(pfxPath, created.Export(X509ContentType.Pkcs12));
        return X509CertificateLoader.LoadPkcs12FromFile(pfxPath, null, X509KeyStorageFlags.EphemeralKeySet);
    }

    internal static byte[]? ExtractPemBody(string pem, string label)
    {
        var begin = $"-----BEGIN {label}-----";
        var end = $"-----END {label}-----";
        var start = pem.IndexOf(begin, StringComparison.Ordinal);
        if (start < 0)
        {
            return null;
        }

        start += begin.Length;
        var stop = pem.IndexOf(end, start, StringComparison.Ordinal);
        if (stop < 0)
        {
            return null;
        }

        return Convert.FromBase64String(pem[start..stop].Replace("\r", "").Replace("\n", "").Trim());
    }
}

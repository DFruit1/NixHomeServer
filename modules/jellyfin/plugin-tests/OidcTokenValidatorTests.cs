using System;
using System.Collections.Generic;
using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Threading.Tasks;
using Jellyfin.Plugin.OIDC.Services;
using Microsoft.IdentityModel.Tokens;
using Xunit;

namespace Jellyfin.Plugin.OIDC.Tests;

public sealed class OidcTokenValidatorTests : IDisposable
{
    private const string Issuer = "https://id.example.test/oauth2/openid/jellyfin-web";
    private const string Audience = "jellyfin-web";
    private const string Nonce = "expected-nonce";
    private readonly RSA _rsa = RSA.Create(2048);
    private readonly RsaSecurityKey _key;

    public OidcTokenValidatorTests()
    {
        _key = new RsaSecurityKey(_rsa) { KeyId = "test-key" };
    }

    [Fact]
    public void AcceptsValidSignedTokenAndPreservesClaimNames()
    {
        var token = CreateToken();

        var principal = OidcTokenValidator.Validate(token, Issuer, Audience, new[] { _key }, Nonce);

        Assert.Equal("alice", principal.FindFirst("preferred_username")?.Value);
        Assert.Equal(Nonce, principal.FindFirst("nonce")?.Value);
    }

    [Fact]
    public void RejectsUnsignedToken()
    {
        var token = CreateToken(unsigned: true);

        Assert.ThrowsAny<SecurityTokenException>(
            () => OidcTokenValidator.Validate(token, Issuer, Audience, new[] { _key }, Nonce));
    }

    [Theory]
    [InlineData("https://wrong.example.test", Audience, Nonce)]
    [InlineData(Issuer, "wrong-audience", Nonce)]
    [InlineData(Issuer, Audience, "wrong-nonce")]
    public void RejectsWrongIssuerAudienceOrNonce(string issuer, string audience, string nonce)
    {
        var token = CreateToken(issuer: issuer, audience: audience, nonce: nonce);

        Assert.ThrowsAny<SecurityTokenException>(
            () => OidcTokenValidator.Validate(token, Issuer, Audience, new[] { _key }, Nonce));
    }

    [Fact]
    public void RejectsExpiredTokenOutsideClockSkew()
    {
        var token = CreateToken(
            notBefore: DateTime.UtcNow.AddMinutes(-10),
            expires: DateTime.UtcNow.AddMinutes(-3));

        Assert.Throws<SecurityTokenExpiredException>(
            () => OidcTokenValidator.Validate(token, Issuer, Audience, new[] { _key }, Nonce));
    }

    [Fact]
    public void RejectsNotYetValidTokenOutsideClockSkew()
    {
        var token = CreateToken(
            notBefore: DateTime.UtcNow.AddMinutes(3),
            expires: DateTime.UtcNow.AddMinutes(10));

        Assert.Throws<SecurityTokenNotYetValidException>(
            () => OidcTokenValidator.Validate(token, Issuer, Audience, new[] { _key }, Nonce));
    }

    [Fact]
    public void RejectsTokenSignedByUnknownKey()
    {
        using var otherRsa = RSA.Create(2048);
        var otherKey = new RsaSecurityKey(otherRsa) { KeyId = "other-key" };
        var token = CreateToken(signingCredentials: new SigningCredentials(otherKey, SecurityAlgorithms.RsaSha256));

        Assert.ThrowsAny<SecurityTokenInvalidSignatureException>(
            () => OidcTokenValidator.Validate(token, Issuer, Audience, new[] { _key }, Nonce));
    }

    [Fact]
    public async Task RefreshesSigningKeysOnceWhenTheTokenUsesANewKey()
    {
        using var rotatedRsa = RSA.Create(2048);
        var rotatedKey = new RsaSecurityKey(rotatedRsa) { KeyId = "rotated-key" };
        var token = CreateToken(signingCredentials: new SigningCredentials(rotatedKey, SecurityAlgorithms.RsaSha256));
        var refreshCount = 0;

        var principal = await OidcTokenValidator.ValidateWithKeyRefreshAsync(
            token,
            Issuer,
            Audience,
            new[] { _key },
            Nonce,
            _ =>
            {
                refreshCount++;
                return Task.FromResult<IEnumerable<SecurityKey>>(new[] { rotatedKey });
            },
            default);

        Assert.Equal("alice", principal.FindFirst("preferred_username")?.Value);
        Assert.Equal(1, refreshCount);
    }

    [Fact]
    public async Task DoesNotRefreshSigningKeysMoreThanOnce()
    {
        using var rotatedRsa = RSA.Create(2048);
        var rotatedKey = new RsaSecurityKey(rotatedRsa) { KeyId = "rotated-key" };
        var token = CreateToken(signingCredentials: new SigningCredentials(rotatedKey, SecurityAlgorithms.RsaSha256));
        var refreshCount = 0;

        await Assert.ThrowsAsync<SecurityTokenSignatureKeyNotFoundException>(
            () => OidcTokenValidator.ValidateWithKeyRefreshAsync(
                token,
                Issuer,
                Audience,
                new[] { _key },
                Nonce,
                _ =>
                {
                    refreshCount++;
                    return Task.FromResult<IEnumerable<SecurityKey>>(new[] { _key });
                },
                default));

        Assert.Equal(1, refreshCount);
    }

    public void Dispose()
    {
        _rsa.Dispose();
    }

    private string CreateToken(
        string issuer = Issuer,
        string audience = Audience,
        string nonce = Nonce,
        DateTime? notBefore = null,
        DateTime? expires = null,
        SigningCredentials? signingCredentials = null,
        bool unsigned = false)
    {
        signingCredentials = unsigned
            ? null
            : signingCredentials ?? new SigningCredentials(_key, SecurityAlgorithms.RsaSha256);
        var token = new JwtSecurityToken(
            issuer,
            audience,
            new[]
            {
                new Claim("sub", "alice-id"),
                new Claim("preferred_username", "alice"),
                new Claim("nonce", nonce)
            },
            notBefore ?? DateTime.UtcNow.AddMinutes(-1),
            expires ?? DateTime.UtcNow.AddMinutes(5),
            signingCredentials);
        return new JwtSecurityTokenHandler().WriteToken(token);
    }
}

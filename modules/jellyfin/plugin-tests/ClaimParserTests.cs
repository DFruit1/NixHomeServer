using System.Security.Claims;
using Jellyfin.Plugin.OIDC.Services;
using Xunit;

namespace Jellyfin.Plugin.OIDC.Tests;

public sealed class ClaimParserTests
{
    [Fact]
    public void ReadsFlatClaimsFromValidatedPrincipal()
    {
        var principal = Principal(
            new Claim("preferred_username", "alice"),
            new Claim("groups", "media"),
            new Claim("groups", "admin"));

        Assert.Equal("alice", ClaimParser.ExtractClaim(principal, "preferred_username"));
        Assert.Equal(new[] { "media", "admin" }, ClaimParser.ExtractRoles(principal, "groups"));
    }

    [Fact]
    public void ReadsJsonArrayAndNestedRolesFromValidatedPrincipal()
    {
        var flat = Principal(new Claim("groups", "[\"media\",\"admin\"]"));
        var nested = Principal(new Claim("realm_access", "{\"roles\":[\"media\",\"admin\"]}"));

        Assert.Equal(new[] { "media", "admin" }, ClaimParser.ExtractRoles(flat, "groups"));
        Assert.Equal(new[] { "media", "admin" }, ClaimParser.ExtractRoles(nested, "realm_access.roles"));
    }

    private static ClaimsPrincipal Principal(params Claim[] claims)
    {
        return new ClaimsPrincipal(new ClaimsIdentity(claims, "test"));
    }
}

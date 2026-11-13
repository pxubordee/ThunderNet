# Security policy

ThunderNet For Roblox (full name: ThunderNetworking) is a networking framework,
not an anti-cheat system. The server is trusted; every client is untrusted. See
[docs/SECURITY.md](docs/SECURITY.md) for the full trust model, inbound check
order, limits, and the guarantees the framework does and does not provide.

## Supported versions

| Version | Supported |
| --- | --- |
| Latest GitHub release (0.3.x) | Yes |
| Older releases | Best effort; upgrade before reporting if possible |

Only the `.rbxm` from [GitHub Releases](https://github.com/pxubordee/ThunderNet/releases)
is a supported distribution. Builds from arbitrary forks or reposts are not
covered by this policy.

## Reporting a vulnerability

**Do not open a public issue with exploit details.**

Use GitHub's private vulnerability reporting:

1. Open the repository's **Security** tab.
2. Choose **Report a vulnerability**.
3. Include the affected version, a minimal reproduction, the security impact,
   and any relevant configuration (rate limits, serializer/compression,
   middleware, permissions).

If private reporting is unavailable, contact the maintainer through GitHub
([@pxubordee](https://github.com/pxubordee)) to arrange a private channel. Do not
post the details publicly while a fix is being prepared.

## Scope

In scope:

- the protocol, dispatcher, batching, RPC, middleware, serializer,
  compression, validator, rate limiter and permission helpers
- the packaged `.rbxm` and release workflow
- bypasses of the documented server-authoritative checks

Out of scope:

- game logic built with ThunderNet (damage, currency, inventory, prices,
  ownership, cooldowns)
- Roblox platform or transport vulnerabilities
- exploits that require a modified server, leaked server credentials, or
  arbitrary code execution on the server
- missing features that are explicitly documented as not provided

## What to expect

This is a community project maintained on a best-effort basis. There is no bug
bounty and no paid support. Reports are acknowledged when possible, triaged
privately, and fixed in a release when confirmed. Credit is given in the
release notes unless you ask to remain anonymous.

## Audit disclaimer

ThunderNet has not undergone an independent third-party security audit. The
repository includes tests, strict static analysis and a documented threat
model, but those are not a guarantee. Evaluate it against your own risk model
before shipping a production experience.

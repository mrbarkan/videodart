# Security Policy

## Supported versions

Only the latest release gets security fixes. Older builds are not patched —
grab the current DMG from [Releases](https://github.com/mrbarkan/videodart/releases),
or let the app update itself.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting: **Security** tab →
[Report a vulnerability](https://github.com/mrbarkan/videodart/security/advisories/new).

Please don't open a public issue for an exploitable bug — a private report
gives me a chance to ship a fix first.

VideoDart is a solo-maintained app, so expect a human-speed reply (days,
not hours). Include the version, macOS version, and steps to reproduce.

## Scope

VideoDart downloads and executes three third-party binaries at runtime (yt-dlp,
FFmpeg and Deno) into `~/Library/Application Support/VideoDart/bin`. Issues in
those tools belong upstream; issues in **how VideoDart fetches, verifies or
invokes them** belong here. The same goes for the Sparkle update path — the feed
URL and the EdDSA public key are pinned in `Info.plist`, and a report that either
can be subverted is very much in scope.

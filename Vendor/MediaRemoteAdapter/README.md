# MediaRemote Adapter (vendored)

Vendored copy of [ungive/mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)
binaries and the Perl bridge script. Required because on macOS 15.4+ Apple
entitlement-locked the private `MediaRemote.framework` to processes whose
bundle identifier starts with `com.apple.`. `/usr/bin/perl` qualifies; our
app does not. The adapter framework is loaded by the Perl script at runtime
and emits JSON-line now-playing updates we consume.

## Files

- `mediaremote-adapter.pl` — Perl bridge (upstream `bin/`)
- `MediaRemoteAdapter.framework/` — universal (arm64 + x86_64), code-signed
- `MediaRemoteAdapterTestClient` — universal helper for the `test` command
- `MediaRemoteAdapter-LICENSE.txt` — BSD 3-Clause license notice

## License & attribution

BSD 3-Clause. Copyright (c) 2025 Jonas van den Berg and contributors. Full
text in `MediaRemoteAdapter-LICENSE.txt`; bundled with the app as required
by clause 2 of the license.

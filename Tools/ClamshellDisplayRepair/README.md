# Clamshell Display Repair

A small macOS utility for a stale display topology left behind when Screen
Sharing disconnects from a MacBook in closed-lid mode. In the broken state,
the hardware lid state is closed but WindowServer still treats the built-in
panel as an active desktop and may place the Dock there.

The repair briefly disables only the active built-in display in a short-lived
child process. The application-scoped override automatically ends when that
child exits; only then does the parent verify that macOS clamshell policy kept
the correct topology. It refuses to run unless:

- the hardware lid state is closed;
- at least one external display is active; and
- the built-in display is incorrectly active.

It does not require administrator privileges, restart WindowServer, log out,
put the Mac to sleep, or leave a session-scoped display override behind.

## Build and run

```sh
Tools/ClamshellDisplayRepair/build-app.sh
open '.build/Clamshell Display Repair.app'
```

The build is ad-hoc signed for local use. The command-line helper bundled in
the app also supports:

```sh
'.build/Clamshell Display Repair.app/Contents/Helpers/ClamshellDisplayRepair' --status
'.build/Clamshell Display Repair.app/Contents/Helpers/ClamshellDisplayRepair' --repair
```

## Compatibility note

Display discovery, lid-state validation, and display transactions use public
CoreGraphics and IOKit APIs. Actually enabling or disabling one display uses
the exported but undocumented `CGSConfigureDisplayEnabled` CoreGraphics SPI,
because the public display-configuration API has no equivalent operation.
Apple can change or remove that SPI in a future macOS release, so the helper
checks every return code. The SPI is used only with CoreGraphics's
application-scoped configuration option, and final verification happens after
that temporary configuration has automatically ended.

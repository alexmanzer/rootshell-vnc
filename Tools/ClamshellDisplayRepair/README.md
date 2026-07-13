# Clamshell Display Repair

A small macOS utility for a stale display topology left behind when Screen
Sharing disconnects from a MacBook in closed-lid mode. In the broken state,
the hardware lid state is closed but WindowServer still treats the built-in
panel as an active desktop and may place the Dock there.

The repair disables only the active built-in display for the current login
session. It refuses to run unless:

- the hardware lid state is closed;
- at least one external display is active; and
- the built-in display is incorrectly active.

It does not require administrator privileges, restart WindowServer, log out,
or put the Mac to sleep. The app includes a recovery control that re-enables
the built-in display.

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
'.build/Clamshell Display Repair.app/Contents/Helpers/ClamshellDisplayRepair' --enable-built-in
```

## Compatibility note

Display discovery, lid-state validation, and display transactions use public
CoreGraphics and IOKit APIs. Actually enabling or disabling one display uses
the exported but undocumented `CGSConfigureDisplayEnabled` CoreGraphics SPI,
because the public display-configuration API has no equivalent operation.
Apple can change or remove that SPI in a future macOS release, so the helper
checks every return code and verifies the topology after applying a repair.

# Architecture

Ferry does what Jimpactor does (sign IPAs, install them over USB/Wi-Fi,
manage devices) and is laid out to avoid the structural problems Jimpactor
built up. This file lists those problems and the rule that replaces each one.

## Jimpactor's problems, and what replaces them

1. The GUI process is the backend.
   Device discovery, workers and installs live inside the iced app. Other
   tools (idl, `jimpactor-cli tray`) can only reach that state over an IPC
   channel added to the relaunch listener: TCP on 127.0.0.1, a port file, a
   token file. If the window isn't running, `idl install` fails with "could
   not reach Jimpactor".

   Ferry: `ferryd` owns devices and jobs. The GUI and CLI are equal
   clients on a Unix socket in `$XDG_RUNTIME_DIR`, which is mode 0700, so
   ordinary file permissions do the access control and no token is needed.
   Both clients start the daemon on demand. The CLI also works with no daemon
   at all: it runs the same service in-process (`--local`, or automatically
   when nothing is listening).

2. The protocol is written down twice.
   The Rust IPC types, a hand-written `ipc.schema.json` (with a test that
   checks the two agree), and a separate client in idl all describe the same
   protocol.

   Ferry: each method's parameter and result type is declared once, in
   `lib/protocol`. The daemon, the in-process path and every client
   encode/decode through those types, and `ferry schema` generates the JSON
   Schema from them at comptime. `protocol` has no dependencies, so any Zig
   tool, idl included, can import it directly.

3. A grab-bag utility crate.
   `plume_utils` holds device access, signing, sources, JIT, Tailscale, IPC,
   refresh, tweaks and app data, and pulls in idevice, mdns-sd, xkit, reqwest,
   tailscale, goblin, image and zip. Anything that only needed device access
   (ios-webusb) had to take all of it or reimplement it.

   Ferry: one module per concern, and each module names its imports in
   `build.zig`. `device` (libimobiledevice) can't see `signing`; `ipa` can't
   see `device`; only `core` sees everything. Using `device` elsewhere costs
   `diag` + `plist` + libimobiledevice and nothing more.

4. Profile selection is spread across layers.
   The plume signer and the xkit bridge are two signing paths, and the
   "single profile" fallback has to be repeated in `select_profile`
   (signer.rs) and again in `Device::install_app` (device.rs).

   Ferry: providers only answer one question: "which certificate +
   profile + final bundle id?" (`provision.choose`, unit-tested). Signers only
   sign. The install pipeline asks the provider once and passes the answer
   on. Nothing after that step second-guesses it.

5. Business logic lives in the UI.
   `screen/mod.rs` (~1.9k lines) and `settings.rs` (~1.7k lines) mix flow
   control with widgets, and `jimpactor-cli` has its own copies of the same
   flows.

   Ferry: flows live in `core/pipeline.zig` as ordered steps that report
   progress (inspect → provision → sign → upload → install). The GUI and CLI
   only render `job.updated` events, so both show the same step and the same
   error text.

6. Feature-gated core.
   `plume_core` doesn't compile without `--features tweaks`.

   Ferry: every module builds and tests on its own (`zig build test` runs
   each module's tests as a separate binary). The GUI is optional
   (`-Dgui=false`).

7. Long-lived device workers with fragile handles.
   A missed AFC `close()` tripped a debug assertion and killed the Wi-Fi
   worker.

   Ferry: each device call opens its own idevice/lockdown/service handles
   and releases them with `defer` on every path. No per-device worker exists
   that could get wedged.

## Module graph

```
diag ─┬─ plist ─┬─ ipa         libzip
      │         ├─ device      libimobiledevice (usbmuxd: USB + Wi-Fi)
      │         └─ provision   identities: files | exec plugin
      └─ signing               zsign (vendored C++, C ABI shim)
protocol                       wire types + schema, no deps
migrate = plist + provision + signing + device + ipa   (importers, e.g. Jimpactor)
core   = ipa + device + provision + signing + migrate + protocol
client = protocol

ferryd = core + protocol
ferry       = core + client + protocol + clap
ferry-gui = client + protocol + dvui (SDL3)
```

## Identities (where certificates come from)

`<data>/identities/<name>/` is one of:

- files: `*.p12` plus an optional `password` file and one or more
  `*.mobileprovision`. Covers paid teams and certificates exported from
  Xcode, Jimpactor (`account export-p12`) or AltServer.
- exec: `provider.json` = `{"exec": ["cmd", ...]}`. The command gets the
  request `{"bundle_id", "udid", "ipa"}` as its last argument and prints
  `{"p12", "password", "profile", "bundle_id"}`. Identities imported from
  Jimpactor use this with `ferry provider jimpactor`, which caches profiles
  and asks `jimpactor-cli` for new ones (`lib/migrate`). This is the seam for
  free-account Apple ID provisioning: a helper built on the existing Rust
  xkit + omnisette crates can plug in here as a separate process, without
  linking an HTTP/SRP/anisette stack into the daemon.

Profile choice, in order: an exact profile for the bundle id; then
`<id>.<TEAMID>` (the AltStore/SideStore/Jimpactor free-account convention,
which re-identifies the app); then a wildcard. Expired profiles and profiles
that don't include the target device are skipped, and the error message lists
why each one was rejected.

## Translations

`lib/i18n` has no dependencies. It reads gettext .mo catalogs embedded at
build time, and the front ends plus `core` translate through it.

Step names and job states travel over the protocol as English keys
(`inspect`, `sign`, `failed`). Each client translates them for display, so
clients in different languages can share one daemon.

Job titles and result messages are written by the daemon, in the language
of whoever started it.

Low-level library diagnostics (`device`, `provision`, `signing`) stay in
English. Those libraries don't depend on `i18n`.

## Not built yet

- Apple ID login / free-account provisioning: an exec provider that wraps xkit.
- iOS 17+ RemotePairing / Tailscale / JIT. libimobiledevice covers lockdown
  over usbmuxd only.
- Auto-refresh scheduling (the daemon is the natural home: a timer that
  queues `install` jobs).
- Sources, tweak injection UI (`signing.Options.inject` already passes
  dylibs to zsign), app data backup.

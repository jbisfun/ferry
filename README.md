# Ferry

iOS sideloading for Linux, written in Zig: sign IPAs and install them over USB
or Wi-Fi. There is a daemon that owns devices and jobs, a CLI (`ferry`) and a
GUI (`ferry-gui`, dvui/SDL3).

The successor layout to Jimpactor. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
for what changed and why.

## Build

Needs Zig 0.17.1 and the libimobiledevice, libplist, libzip, OpenSSL and
FreeType development packages, plus a running `usbmuxd`.

```sh
zig build                 # zig-out/bin/{ferry,ferryd,ferry-gui}
zig build -Dgui=false     # CLI + daemon only
zig build test            # every module's tests, each module on its own
```

Some dependencies (translate-c) live on codeberg.org. If your DNS can't
resolve it, `tools/fetch-codeberg.sh <owner/repo> <commit> <hash>` downloads
through 1.1.1.1 and seeds the package cache.

`tools/install-desktop.sh` adds a launcher entry and icon for `ferry-gui`.
`FERRY_GUI_SCREENSHOT=out.png ferry-gui` renders one frame to a PNG and quits.

## Coming from Jimpactor

```sh
ferry import jimpactor        # or the "Import from Jimpactor" button
```

This copies Jimpactor's pairing records (handed to usbmuxd when the device
appears) and turns each `xkit/data/<TEAM>` certificate + key into an identity
`jimpactor-<TEAM>`. Jimpactor doesn't keep provisioning profiles, so that
identity asks `jimpactor-cli` (found via `$JIMPACTOR_CLI`, `PATH` or
`~/projs/jimpactor/target`) for a profile the first time each app is signed and
caches it in `identities/jimpactor-<TEAM>/profiles/`. Wi-Fi device lists,
Tailscale keys and anisette data aren't used.

## Use

```sh
ferry import jimpactor
ferry identity add team --p12 cert.p12 --password ... --profile app.mobileprovision
ferry devices
ferry install MyApp.ipa                  # one device connected
ferry install "JP's iPhone" MyApp.ipa -b com.me.myapp
ferry sign MyApp.ipa -o signed.ipa
ferry apps / info / uninstall <bundle>
ferry watch                              # live device + job events
ferry daemon start|stop|status
ferry schema                             # protocol JSON Schema
```

`ferry` uses the daemon if one is running, so its jobs also show up in the
GUI. Otherwise it runs everything in-process. The GUI starts the daemon
itself. Data lives in `$FERRY_HOME`, or else `~/.config/ferry`. The
socket is `$XDG_RUNTIME_DIR/ferry.sock`.

## Languages

English and Traditional Chinese (zh_TW). The language follows `LANG` /
`LC_MESSAGES` / `LANGUAGE` (zh_TW, zh_HK and zh_Hant all select 繁體中文), or
`FERRY_LANG=zh_TW` to force it. The GUI also has a language picker in the
header. The GUI uses the desktop's interface font (GNOME `font-name`, through
fontconfig) and, for Chinese, the system's Noto Sans CJK TC.

Translations are GNU gettext catalogs in `po/`. They're compiled with
`msgfmt --check` at build time and embedded in the binaries, so they work
even when the `zh_TW` locale isn't generated on the system. To add strings:
wrap them in `tr("...")` (or `trf`/`trl`/`failT`/`say` with `{0}`
placeholders), run `zig build pot`, then
`msgmerge -U po/zh_TW.po po/ferry.pot`, and translate the new entries.

`tests/make-test-identity.sh DIR` creates a throwaway certificate and profile
so you can try signing without an Apple account. Devices won't accept apps
signed with it.

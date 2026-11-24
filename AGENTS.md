# Italian radios

Omarchy bar-widget plugin (`impero365.radio-italia`). The panel is `Panel.qml`. Station logic that can be tested without the shell lives in `Model.js`. Playback is `radio-player` (short-lived client) talking to the long-lived `radio-playerd`. `radio-session` starts `radio-proxy`, then runs mpv under `radio-sandbox` (`bwrap --unshare-net`) so streams go through that proxy. `radio-icon` fetches station logos. Strings are in `i18n/en.json`.

## Boundaries

- This tree is the user-owned plugin. Do not edit `/usr/share/omarchy/` or other packaged shell files.
- Python is the standard library only. JavaScript tests use Node's built-in runner. UI uses Qt Quick, Quickshell, and `qs.Ui` / `qs.Commons`. Do not add dependencies.
- Treat directory, cache, IPC, and playback text as untrusted. Display it with `textFormat: Text.PlainText`. Keep the existing length, count, URL, and id checks. Do not interpolate that text into shell commands.
- Station names go through `plainName` (`NAME_LIMIT` 80). `pluginVersion` accepts only a plain `major.minor.patch` string.
- mpv reaches the network only through the local proxy. A later `play` must return as soon as mpv accepts `loadfile replace`, and a newer station must replace one that is still connecting. Do not wait out the start grace before accepting the next command.
- The three-dot loader belongs on the clicked station row, left of the star, and only while that station is connecting. Do not put it in the player title. The station name stays in its original vertical position.
- Reloading the plugin does not restart `radio-playerd`.
- After every QML change, delete `~/.cache/quickshell/qmlcache` when the plugin is restarted. Stop the shell, delete that cache, then start the shell. A save or rescan can keep the previously compiled QML.
- The station list is `~/.cache/impero365.radio-italia/stations.json`. Logos are `icons/` and `icons.json` beside it. Deleting one leaves the other. An open panel keeps the list in memory, so stop the shell before deleting either, then start the shell. There is no `omarchy plugin restart`.
- Station logos may be HTTP or HTTPS. A redirect is followed only when the next URL passes the same public-address check.
- Playback stays Python and mpv behind the local proxy. A first play that reports stopped before any audio is the starting timer ending while mpv is still opening.
- The title uses Adwaita Sans, centered, with the version in small type beside it. Station rows do not highlight under the pointer. The play/stop control is a rounded square with radius `Math.round(width * 0.22)`.
- README install and remove stay as the two `omarchy plugin` commands. The dependency list stays the programs already on Omarchy (`mpv`, `bubblewrap`, `socat`, `python`, `iproute2`, `util-linux`). Do not turn that list into install steps.

## Checks

- `node --test model.test.js`
- `python3 tests/proxy.test.py`
- `python3 tests/player.test.py`
- `python3 tests/icon.test.py`
- `omarchy plugin validate .`

`model.test.js` may keep old version strings as parser fixtures. The live version is `manifest.json`.

## Releases

- A release is one commit. It sets `manifest.json` `version` to `major.minor.patch` and adds the Keep a Changelog section for that version. The annotated tag uses that same version string and points at that commit. Push the commit and the tag together.
- Leave a tag that is already on origin where it is.

## Changes

- Match the surrounding file. Commit subjects are short and imperative.
- For a bug, report what is wrong and a small proposed fix, then wait for approval before editing.
- A fix covers the reported behavior only. Do not add fetching, caching, or network policy in that change unless the report asked for it.

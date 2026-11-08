# Italian radios

Omarchy bar panel that lists Italian web radio stations from the [Radio Browser](https://www.radio-browser.info/) directory and plays the one you pick on the current audio device.

## Install

This folder is the installed plugin:

```text
~/.config/omarchy/plugins/mattia.radio
```

Enable it on the right of the bar, before the power icon:

```sh
omarchy plugin enable mattia.radio --section right --before omarchy.power
```

If it does not appear immediately:

```sh
omarchy-shell shell rescanPlugins
```

## Use

Click the radio icon. The panel has two columns. On the right, filter by name, by region, or both, and pick a station. On the left, the player stays visible, with favourites underneath. Click a row to play that stream with mpv. The player button pauses and resumes the current station. Choosing another station switches to it. Playback continues after the panel closes.

The star on a row saves that station in the Favourites section. A saved station is one directory entry, identified by its id. While the directory still lists that id, playback uses the current stream. If a later refresh drops the id, the saved copy remains. Favourites are stored at `~/.local/state/mattia.radio/favourites.json` (or under `XDG_STATE_HOME` when that is set).

The list is saved at `~/.cache/mattia.radio/stations.json`. Opening the panel uses that copy when it is less than a day old, and fetches the directory again when it is older or missing. The request goes to `de1.api.radio-browser.info`, then to `de2.api.radio-browser.info` if the first host fails.

## Check

```sh
node --test model.test.js
omarchy plugin validate .
```

## License

MIT. See [LICENSE](LICENSE).

Needs Omarchy and mpv. No extra packages.

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

Click the radio icon. The panel lists each station with its icon and name, and the region when the directory has one. Filter by name, by region, or both. Click a row to play that stream with mpv. Click the same row again, or Stop, to stop. Playback continues after the panel closes.

The list is saved at `~/.cache/mattia.radio/stations.json`. Opening the panel uses that copy when it is less than a day old, and fetches the directory again when it is older or missing. The request goes to `de1.api.radio-browser.info`, then to `de2.api.radio-browser.info` if the first host fails.

## Check

```sh
node --test model.test.js
omarchy plugin validate .
```

## License

MIT. See [LICENSE](LICENSE).

Needs Omarchy and mpv. No extra packages.

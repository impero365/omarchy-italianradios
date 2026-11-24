# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.5] - 2026-11-18

### Security

- The logo cache and icon directories must be real directories. Cleanup deletes only regular files whose names match a logo this plugin stored.

## [1.0.4] - 2026-11-18

### Added

- The panel shows the release number beside the title.

### Changed

- Logos the current directory no longer uses are dropped, and the icon directory stays within 64 MiB.

### Fixed

- Icon tests clean only a private directory they still own.

## [1.0.3] - 2026-11-17

### Added

- Station logos are fetched after a public-address check and stored locally. The panel no longer loads a directory icon URL. A private address is refused before any connection. Several logos are fetched at once.
- `preview.webp` in the README.

### Changed

- `manifest.json` reports version 1.0.3. The 1.0.2 version bump is in this release because it was committed after the 1.0.2 tag. The 1.0.1 and 1.0.2 tags still say 1.0.0.

### Fixed

- The README again has install and remove commands, plus the programs Omarchy already includes.

### Removed

- `screenshot.png`, replaced by `preview.webp`.

## [1.0.2] - 2026-11-16

### Added

- While a station is connecting, three dots sit on that row.

### Changed

- The play control is a rounded square.

### Fixed

- A newer station replaces one that is still connecting. Playback accepts the next station as soon as mpv takes it, and a status update from the replaced station is ignored.

### Removed

- Tracked `__pycache__`.

## [1.0.1] - 2026-11-16

### Added

- Volume control.
- A short README description, a screenshot, and credit to Radio Atlas and Vantage.

### Changed

- The plugin id is `impero365.radio-italia`. Runtime files moved off `mattia.radio`.

### Removed

- Install, use, and check instructions from the README.

## [1.0.0] - 2026-11-16

### Added

- Italian stations from Radio Browser, played with mpv.
- Favorites.
- A sandboxed player. mpv has no network of its own. Streams go through a local proxy that accepts public addresses only.
- One player process stays running, so a click does not start Python again.

### Fixed

- A longer socat timeout.

[Unreleased]: https://github.com/impero365/omarchy-italianradios/compare/1.0.5...HEAD
[1.0.5]: https://github.com/impero365/omarchy-italianradios/compare/1.0.4...1.0.5
[1.0.4]: https://github.com/impero365/omarchy-italianradios/compare/1.0.3...1.0.4
[1.0.3]: https://github.com/impero365/omarchy-italianradios/compare/1.0.2...1.0.3
[1.0.2]: https://github.com/impero365/omarchy-italianradios/compare/1.0.1...1.0.2
[1.0.1]: https://github.com/impero365/omarchy-italianradios/compare/1.0.0...1.0.1
[1.0.0]: https://github.com/impero365/omarchy-italianradios/releases/tag/1.0.0

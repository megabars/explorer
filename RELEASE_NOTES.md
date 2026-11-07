# Explorer 1.1.0

Localization and app icon release for macOS 14 and later (build 4).

- Adds Russian, English, and Spanish throughout the interface, menus, and app errors.
- Follows the system language by default, with an explicit language choice in Settings.
  Language changes take effect after restarting Explorer.
- Localizes dates, file sizes, item counts, and default new-folder names while
  preserving existing filenames, paths, favorites, and stored Finder tags.
- Adds a new blue folder and compass-arrow app icon for Finder and the Dock.
- Includes 61 regression tests covering language selection, resource catalogs,
  plural forms, and existing file-manager behavior.

The GitHub ZIP contains a universal app for Apple Silicon and Intel Macs and
includes a SHA-256 checksum. The app uses an ad hoc code signature; this release
is not Developer ID signed or notarized by Apple. Local builds for personal use
are available through `bash script/package_release.sh`.

# Explorer 1.0.1

Maintenance release for macOS 14 and later (build 2).

- Fixes file copying, ZIP archives, Trash restoration, and directory watching.
- Corrects menu command routing, selection, rename editors, filtering, and grid navigation.
- Keeps navigation responsive when another directory is waiting on filesystem metadata.
- Adds 54 regression tests and reproducible release packaging.

The GitHub ZIP contains a universal app for Apple Silicon and Intel Macs and
includes a SHA-256 checksum. The app uses an ad hoc code signature; this release
is not Developer ID signed or notarized by Apple. Local builds for personal use
are available through `bash script/package_release.sh`.

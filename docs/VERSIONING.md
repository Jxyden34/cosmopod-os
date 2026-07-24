# Cosmopod OS versioning

Cosmopod OS uses semantic versions.

- Every testable development iteration advances the minor version: `0.2.0`,
  `0.3.0`, `0.4.0`, and so on. Existing output directories are retained so a
  new iteration never overwrites the previous artifact set.
- Rebuilding identical source does not create a fake new version. Any source,
  configuration, package, security, boot, backend, or release-process change
  advances the next build version.
- Development artifacts are not promoted by renaming files. The version is
  embedded into `/etc/os-release`, the Mender artifact identity, manifests,
  checksums, and artifact filenames during the build.
- `1.0.0` is reserved for the first fully qualified release. It requires
  successful Raspberry Pi 4 and Pi 5 image builds, x86-64 ISO/VM boot tests,
  Wayland, networking and SSH checks, signed A/B OTA validation, production
  backend validation, security/release gates, and published GitHub records.

The repository `VERSION` file is the default for build, smoke-test, signing,
and validation scripts. An explicit `--version` or `-Version` creates a named
test iteration without overwriting older output.

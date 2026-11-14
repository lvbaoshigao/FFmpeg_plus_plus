# Liquid Glass Widgets vendor

- Upstream: https://github.com/sdegenaar/liquid_glass_widgets
- Version: **1.17.3** (published release, not GitHub main).
- Archive: https://pub.dev/api/archives/liquid_glass_widgets-1.17.3.tar.gz
- SHA-256: `4b1d093122b35f71735b16470280d4c75dd17cfc84272edcec1aed7b4d5121ef`
- License: MIT; upstream `LICENSE` retained.

The archive checksum was verified before extraction. Runtime `lib/`, `shaders/`,
`ios/`, `pubspec.yaml`, `LICENSE`, and `README.md` are retained without source
modifications. Upstream examples, tests, documentation assets, and agent skills
are omitted. The path dependency follows this project's existing vendor workflow:
Dart registry socket requests failed against both the configured mirror and
`pub.dev`, while the official release archive was retrievable.

The upstream analyzer policy is retained separately from the release tag:
https://raw.githubusercontent.com/sdegenaar/liquid_glass_widgets/v1.17.3/analysis_options.yaml
This keeps upstream source under its own lint policy, without modifying the
application lint settings or suppressing analyzer errors.

Desktop integration uses only the lightweight shader path, with no background
screenshot source and no premium `ImageFilter.shader` pipeline. This is a
standard-quality approximation, not refraction of arbitrary underlying content.
Keep the existing fallback for initialization failure.

Validation from `ffmpegpp_gui/`:

```text
flutter pub get --offline
flutter analyze --no-pub
flutter test --no-pub
flutter build windows --release --no-pub
```

Revalidate all packaged shaders on Windows when upgrading, even if the runtime
does not select the premium path. Do not remove existing renderer overrides.

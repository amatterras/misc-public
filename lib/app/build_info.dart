// Which build of THEapp this is. Set when building, e.g.
//   flutter build windows --release --dart-define=THEAPP_BUILD=<git hash>
// (codemagic.yaml and tool\testenv.ps1 do this). Shown in Settings and
// written to the log at start, so every device's build can be checked:
// all devices paired with one hub must run builds from `371c6ca` on, or an
// older build can drop fields that newer ones added.
const String appBuild = String.fromEnvironment(
  'THEAPP_BUILD',
  defaultValue: 'dev',
);

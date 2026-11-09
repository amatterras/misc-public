# misc.

A personal workspace for notes, mindmaps, a calendar with tasks, and an
Archive of saved links and files. It runs on Windows and on iPad/iPhone, keeps
everything on your own devices, and syncs through a hub on your own PC.

The app is called **misc.** (always lowercase, with the period).

## Naming

The product was renamed from THEapp to misc. This is a branding change only.
Everything below keeps its original spelling on purpose, so existing installs
keep their data and keep working without a reinstall:

- the Flutter package and repository name (`flutter_application_1`, `THEapp`)
- the iOS bundle identifier, App Group and Keychain service name
- data folders (`%APPDATA%\THEapp`, `THEapp-hub`, `THEapp Backups`,
  `THEapp Exports`, `THEapp Downloads`), the log file name, and the encryption
  key labels
- the hub protocol markers, the `theapp://` link scheme and the method-channel
  names
- the `.theappbackup` file extension
- the Windows executable name in the build folder (`flutter_application_1.exe`);
  the release packages from `scripts\build_windows_release.ps1` ship the same
  file renamed to `misc.exe` (see "Windows release" below)

Anything the user can read (window title, iOS home-screen name, permission
prompts, settings, messages, the Windows Send-to entry) says **misc.**

## Development

```
flutter pub get
flutter analyze
flutter test -j 1
flutter run -d windows
```

See `ARCHITECTURE.md`, `docs/SYNC_ARCHITECTURE.md`, `docs/STORAGE_MODES.md` and
`docs/IOS_BUILD_GUIDE.md` for how it is put together.

## Windows release

```
powershell -ExecutionPolicy Bypass -File scripts\build_windows_release.ps1
```

Checks Flutter and Visual Studio, runs `pub get`, `analyze` and
`build windows --release`, then writes (git-ignored):

- `dist\windows\misc-windows-x64\` - portable app: `misc.exe`, Flutter and
  Visual C++ runtime DLLs, `data\`
- `dist\windows\misc-windows-x64.zip` - the same folder, zipped
- `dist\windows\misc-Setup.exe` - per-user installer (Windows IExpress, no
  admin rights): installs to `%LOCALAPPDATA%\Programs\misc`, Start Menu
  shortcut, optional desktop shortcut, entry in Settings > Apps. Upgrades
  replace only the program files; uninstalling keeps `%APPDATA%\THEapp`.

Options: `-SkipAnalyze`, `-RunTests` (slow), `-SkipInstaller`. Installer
sources: `scripts\installer\install.ps1` and `uninstall.ps1`.

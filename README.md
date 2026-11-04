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
- the Windows executable name (`flutter_application_1.exe`)

Anything the user can read (window title, iOS home-screen name, permission
prompts, settings, messages, the Windows Send-to entry) says **misc.**

## Development

```
flutter pub get
flutter analyze
flutter test -j 1
flutter run -d windows
```

See `ARCHITECTURE.md`, `SYNC_ARCHITECTURE.md`, `STORAGE_MODES.md` and
`IOS_BUILD_GUIDE.md` for how it is put together.

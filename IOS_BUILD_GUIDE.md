# iOS IPA build guide (Windows + Codemagic)

misc. is a Flutter project with a native iOS Runner, a home-screen widget, a share extension, and custom Swift platform integrations. This Windows checkout cannot compile or sign iOS binaries; Codemagic's macOS/Xcode runner performs those steps.

## Current configuration

- Flutter package: `flutter_application_1`; visible app name: `misc.`.
- Main bundle ID: `com.amaterasu.theapp`; widget: `com.amaterasu.theapp.widget`; share extension: `com.amaterasu.theapp.share`.
- iOS deployment target: 15.0 for Runner and extensions.
- App Group: `group.com.theapp.shared` (needed for widget/share shared data).
- `pubspec.yaml` currently declares no third-party Flutter plugins; native integrations are implemented in Swift. Flutter asset declarations include quote and greeting JSON.
- `codemagic.yaml` defines manual workflows `ios-unsigned` and `ios-signed`. No signing secrets are committed.

## Connect this project to Codemagic

1. Preserve and review the existing local changes. Commit and push them to your Git host when you choose; Codemagic builds the selected remote commit, not unpushed Windows files.
2. Sign in at [codemagic.io](https://codemagic.io/) and connect the GitHub account/repository containing misc. Grant repository access.
3. Add the repository as a Flutter app. Select the repository and branch containing `codemagic.yaml`; choose the workflow `ios-unsigned` for the first build.
4. Press **Start new build**, select the intended branch/commit, and start. The workflow installs packages, validates plist/project settings, runs `flutter analyze`, compiles with `flutter build ios --release --no-codesign`, and packages the app into an IPA.
5. Wait for the build to finish. A failed dependency, analysis, Xcode, or packaging step fails the workflow. Inspect the step log; the workflow also collects Xcode logs.
6. Open the successful build's **Artifacts** section and download `THEapp-unsigned.ipa`. The optional `THEapp-with-widgets.ipa` is ad-hoc repackaged and is not guaranteed installable with widgets; use the regular unsigned IPA for sideload signing.

## Signing and installation

An unsigned IPA is not directly installable. For personal sideloading, download the IPA to Windows and use a trusted iOS sideloading tool that signs with your Apple ID; free-account signing commonly expires and may require periodic reinstall. Confirm current tool/device requirements with that tool.

For an automatically signed IPA, enroll in the paid Apple Developer Program, register target devices for Ad Hoc distribution (or choose App Store distribution for TestFlight), create an App Store Connect API key, and register the App Group `group.com.theapp.shared` for all three bundle IDs. In Codemagic, create an environment group named `theapp_signing` with `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_KEY_IDENTIFIER`, `APP_STORE_CONNECT_PRIVATE_KEY`, and `CERTIFICATE_PRIVATE_KEY`. Upload/provision the distribution certificate and ensure profiles cover the app, widget, and share extension. Then run `ios-signed`; select `IOS_APP_ADHOC` for registered-device installs. Never put keys or certificates in Git.

## What Windows can and cannot verify

On Windows, run `C:\\src\\flutter\\bin\\flutter.bat pub get`, `flutter analyze`, and `flutter test --concurrency=1`. These validate Dart/dependency resolution and tests, but do not compile Swift, resolve Xcode build settings, sign, or produce a valid iOS IPA. A successful Codemagic macOS build is required to verify those. This repository's native iOS code is explicitly marked uncompiled/unverified in `ios/Runner/AppDelegate.swift`.

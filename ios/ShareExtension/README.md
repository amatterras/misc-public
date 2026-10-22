# iOS Share Extension — draft, untested, needs the paid Apple account

These files (`ShareViewController.swift`, `Info.plist`) are a Share Extension
for THEapp. They have **never been compiled or run** (no Mac available).

- Every shared link, text and photo becomes a request file in the App Group
  folder `group.com.theapp.shared/inbox_requests/` (photos as JPEG in
  `inbox_files/`). THEapp imports them into the Inbox when it starts or comes
  back to the front (`AppState.importSharedItems`, same import code as Windows
  "Send to"; tested on Windows with files in this format).
- App Groups need the paid Apple Developer Program. Without it the extension
  can't hand anything to the app and saves nothing (it never claims success).
  The free alternative is the iOS Shortcut described in `../README_IOS.md`.
- The earlier draft opened the app through a hidden `UIApplication` trick and
  built links that cut off URLs containing `&`; both were removed.

Setup on a Mac (paid account): in Xcode, File → New → Target → Share
Extension, replace the generated files with these two, and enable the App
Groups capability with `group.com.theapp.shared` on both the Runner and the
extension targets.

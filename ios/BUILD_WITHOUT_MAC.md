# THEapp on your iPad without a Mac (zero cost)

**Status: prepared, not yet run.** No iOS build has been made and nothing has
been installed. The Swift code has never been compiled, so the first cloud
build is also the first compile check and may show errors to fix.

Route: Codemagic (cloud Mac, free tier) builds an **unsigned** app → you
download it on Windows → **Sideloadly** signs it with your **free Apple ID** and
installs it over USB.

## Will it work with free signing?

| Part | First test build | Why |
|---|---|---|
| THEapp itself (canvas, notes, calendar, tasks, backups) | yes | no special capabilities |
| Hub key in the Keychain | yes | default Keychain access needs no entitlement |
| `theapp://capture` links (Shortcut) | yes | URL scheme in `Info.plist`, no entitlement |
| Photo picker, PDF picker, PDF preview | yes | PHPicker / document picker need no permission entitlement |
| Task reminder notifications | yes (iOS asks you to allow them) | local notifications need no entitlement |
| Sync over Tailscale with the **test** hub | yes, if the Tailscale app is on | plain network access |
| Share Extension ("Add to THEapp" in the Share menu) | **no** | not in the Xcode project yet, and it needs App Groups (paid Apple Developer Program, $99/year) |
| TestFlight / App Store / push notifications / iCloud | no | paid account; THEapp does not use them |

Free Apple ID limits (Apple's rules, applied when signing):
- the app stops opening after **7 days** until you sign and install it again (your data stays on the iPad as long as you don't delete the app);
- at most **3** sideloaded apps per Apple ID at a time, and about **10 new app IDs per 7 days**;
- **iPadOS 16 or later** needs **Developer Mode** turned on.

The project's bundle ID is `com.amaterasu.theapp` (Flutter's default
`com.example…` is taken by other developers). Change it in
`ios/Runner.xcodeproj/project.pbxproj` if you prefer another; it must be unique.

## Cost

- Codemagic personal account: **500 free macOS M2 minutes per month**; one
  build should take about 10 minutes. Leave billing **off**: then running out of
  minutes just stops builds, nothing is charged.
- Sideloadly, iTunes, iCloud for Windows, a free Apple ID: free.
- Nothing to buy. A GitHub account with a **private** repository is free.

## Step 1: put the code in a private repository (your decision)

Codemagic builds from a Git repository, so the code must be uploaded to a
host it can read (GitHub, GitLab or Bitbucket). **This uploads THEapp's source
code to that host and to Codemagic's build machines.** Nothing is pushed
automatically; only you can do it.

What the repository contains: source code, tests, documentation. It does **not**
contain your notes, canvases, hub data, tokens or passwords (those live in
`%APPDATA%\THEapp` / `THEapp-hub`, outside the project). The documentation
mentions this PC's Windows user folder and Tailscale addresses from testing;
remove them first if you don't want them on GitHub, even in a private repo.

1. Create a **private** repository on github.com (no README, no licence).
2. Commit the current work first (Codemagic only sees committed and pushed
   files: `codemagic.yaml` and the bundle-ID change are part of this work).
3. Push it, in PowerShell in the project folder (replace the address):

   ```bash
   git remote add origin https://github.com/<you>/theapp.git
   ```
   ```bash
   git push -u origin master
   ```

## Step 2: connect Codemagic safely

1. Go to codemagic.io → **Sign up** → with GitHub. Use a **personal** account
   (team accounts get no free minutes).
2. When GitHub asks which repositories Codemagic may see, choose **Only select
   repositories** → your THEapp repository. Nothing else.
3. Codemagic → **Add application** → GitHub → your repository → project type
   **Flutter App (via codemagic.yaml)**.
4. Do **not** add code-signing certificates, an App Store Connect key, an Apple
   ID, or any environment variables. None are needed.
5. Billing: leave it disabled.

## Step 3: build

1. In the app's page, **Start new build** → branch `master` → workflow
   **THEapp iOS (unsigned, for sideloading)** → Start.
2. When it finishes, open **Artifacts** and download
   **`THEapp-unsigned.ipa`** to Windows.
3. If it fails: open the failed step, copy the red error lines (or download the
   `xcodebuild` log from Artifacts) and send them to Claude. Swift errors are
   expected on the very first build because the Swift files were written
   without a Mac.

## Step 4: install from Windows with Sideloadly

Sideloadly is third-party software (sideloadly.io). It sends your Apple ID
sign-in to Apple to get a free signing certificate. Use a **separate free Apple
ID** made only for this if you'd rather not use your main one.

1. Install **iTunes** and **iCloud** from **apple.com** (the web downloads, not
   the Microsoft Store versions; remove the Store versions first if installed).
2. Install Sideloadly from **sideloadly.io** (only from there).
3. Connect the iPad by USB, unlock it, tap **Trust This Computer**. Open iTunes
   once so Windows sees the iPad.
4. Open Sideloadly → drag `THEapp-unsigned.ipa` onto it → choose your iPad →
   enter the Apple ID → **Start**. Sign in with the code Apple sends if asked.
5. On the iPad (iPadOS 16+): **Settings → Privacy & Security → Developer Mode →
   on**, restart, confirm.
6. **Settings → General → VPN & Device Management** → your Apple ID under
   *Developer App* → **Trust**.
7. Open THEapp.

Every 7 days: repeat step 4 with the same `.ipa` (or a newer build) and the
**same** Apple ID. Do not delete the app first, or its data is lost. Signing
with a different Apple ID makes the app forget its hub key; it then asks to be
paired again (your data stays).

## Step 5: first test on the iPad (test data only)

The app starts empty on the iPad. Follow the checklist in
[README_IOS.md](README_IOS.md) ("Checklist for the first run"). For sync use
**only the test hub** on port **47799**:
`tool\testenv.ps1 hub-start -PrivateHost <PC's Tailscale address>` on the PC,
then pair the iPad with `http://<PC's Tailscale address>:47799`. Never pair a
test build with the real hub (port 47710).

Report back what works and what doesn't; nothing here counts as verified until
it has been seen working on the iPad.

<#
  misc. installer (runs from inside misc-Setup.exe).

  misc-Setup.exe is a Windows IExpress package: it unpacks payload.zip,
  app.version and this script to a temporary folder and runs this script there.

  Per-user install, no administrator rights needed:
    app files  -> %LOCALAPPDATA%\Programs\misc   (replaced on upgrade)
    shortcuts  -> Start Menu (always), Desktop (optional)
    uninstall  -> Settings > Apps > Installed apps > misc.

  Your data is NOT in the install folder. It stays in %APPDATA%\THEapp
  (plus Documents\THEapp Backups / THEapp Exports when used) and is never
  touched by installing, upgrading or uninstalling.

  Unattended use (for testing):
    misc-Setup.exe /Q /C:"powershell.exe -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Quiet [-InstallDir <dir>] [-DesktopShortcut] [-NoStartMenu]"
#>
param(
  [string]$InstallDir = '',
  [switch]$Quiet,
  [switch]$DesktopShortcut,
  # Testing: skip the Start Menu shortcut and the Apps & features entry.
  [switch]$NoStartMenu,
  [switch]$NoLaunch
)
$ErrorActionPreference = 'Stop'

$AppName = 'misc.'
$ExeName = 'misc.exe'
$Marker = 'misc.install.json'
$UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\misc'
$Here = $PSScriptRoot
$Payload = Join-Path $Here 'payload.zip'
$Version = '0.0.0'
$VersionFile = Join-Path $Here 'app.version'
if (Test-Path $VersionFile) { $Version = (Get-Content $VersionFile -Raw).Trim() }
if (-not $InstallDir) { $InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\misc' }
$InstallDir = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\')

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

function Say([string]$text, [string]$icon = 'Information') {
  if ($Quiet) { Write-Output $text; return }
  [void][System.Windows.Forms.MessageBox]::Show($text, "$AppName Setup", 'OK', $icon)
}

function Fail([string]$text) {
  Say $text 'Error'
  exit 1
}

function New-Shortcut([string]$path, [string]$target, [string]$workDir) {
  $shell = New-Object -ComObject WScript.Shell
  $s = $shell.CreateShortcut($path)
  $s.TargetPath = $target
  $s.WorkingDirectory = $workDir
  $s.IconLocation = "$target,0"
  $s.Description = $AppName
  $s.Save()
}

# ------------------------------------------------------------ checks

if (-not [Environment]::Is64BitOperatingSystem) {
  Fail "$AppName needs 64-bit Windows 10 or Windows 11."
}
if ([Environment]::OSVersion.Version.Major -lt 10) {
  Fail "$AppName needs Windows 10 or Windows 11."
}
if (-not (Test-Path $Payload)) { Fail "The installer is damaged: payload.zip is missing." }

# Never install into, or over, the data folders.
$dataDirs = @(
  (Join-Path $env:APPDATA 'THEapp'),
  (Join-Path $env:APPDATA 'THEapp-hub'),
  (Join-Path $env:LOCALAPPDATA 'THEapp')
)
foreach ($d in $dataDirs) {
  $a = $InstallDir + '\'; $b = [IO.Path]::GetFullPath($d).TrimEnd('\') + '\'
  if ($a.StartsWith($b, [StringComparison]::OrdinalIgnoreCase) -or
      $b.StartsWith($a, [StringComparison]::OrdinalIgnoreCase)) {
    Fail "Refusing to install into $InstallDir`nbecause it overlaps the data folder $d."
  }
}

# An existing folder is only replaced when an earlier misc. install made it.
$isUpgrade = $false
if (Test-Path $InstallDir) {
  $hasMarker = Test-Path (Join-Path $InstallDir $Marker)
  $isEmpty = -not (Get-ChildItem -LiteralPath $InstallDir -Force | Select-Object -First 1)
  if (-not $hasMarker -and -not $isEmpty) {
    Fail "$InstallDir already exists and was not created by the $AppName installer.`nNothing was changed."
  }
  $isUpgrade = $hasMarker
}

# ------------------------------------------------------------ dialog

if (-not $Quiet) {
  $form = New-Object System.Windows.Forms.Form
  $form.Text = "$AppName Setup"
  $form.FormBorderStyle = 'FixedDialog'
  $form.MaximizeBox = $false
  $form.MinimizeBox = $false
  $form.StartPosition = 'CenterScreen'
  $form.AutoScaleMode = 'Dpi'
  $form.ClientSize = New-Object System.Drawing.Size(460, 220)
  $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

  $title = New-Object System.Windows.Forms.Label
  $title.Text = if ($isUpgrade) { "Update $AppName to version $Version" } else { "Install $AppName $Version" }
  $title.Font = New-Object System.Drawing.Font('Segoe UI', 13)
  $title.AutoSize = $true
  $title.Location = New-Object System.Drawing.Point(20, 18)
  $form.Controls.Add($title)

  $info = New-Object System.Windows.Forms.Label
  $info.Text = "Install folder:`n$InstallDir`n`nYour notes and settings stay in %APPDATA%\THEapp and are kept."
  $info.Location = New-Object System.Drawing.Point(22, 56)
  $info.Size = New-Object System.Drawing.Size(420, 80)
  $form.Controls.Add($info)

  $desk = New-Object System.Windows.Forms.CheckBox
  $desk.Text = 'Create a desktop shortcut'
  $desk.AutoSize = $true
  $desk.Location = New-Object System.Drawing.Point(24, 140)
  $desk.Checked = [bool]$DesktopShortcut
  $form.Controls.Add($desk)

  $ok = New-Object System.Windows.Forms.Button
  $ok.Text = if ($isUpgrade) { 'Update' } else { 'Install' }
  $ok.Location = New-Object System.Drawing.Point(262, 178)
  $ok.Size = New-Object System.Drawing.Size(85, 28)
  $ok.DialogResult = 'OK'
  $form.Controls.Add($ok)
  $form.AcceptButton = $ok

  $cancel = New-Object System.Windows.Forms.Button
  $cancel.Text = 'Cancel'
  $cancel.Location = New-Object System.Drawing.Point(355, 178)
  $cancel.Size = New-Object System.Drawing.Size(85, 28)
  $cancel.DialogResult = 'Cancel'
  $form.Controls.Add($cancel)
  $form.CancelButton = $cancel

  if ($form.ShowDialog() -ne 'OK') { exit 2 }
  $DesktopShortcut = [System.Management.Automation.SwitchParameter]$desk.Checked
}

# ------------------------------------------------------------ install

# misc. must be closed while its files are replaced.
$exePath = Join-Path $InstallDir $ExeName
while ($true) {
  $running = Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and ($_.Path -ieq $exePath) }
  if (-not $running) { break }
  if ($Quiet) { Fail "$AppName is running from $InstallDir. Close it and run Setup again." }
  $r = [System.Windows.Forms.MessageBox]::Show(
    "$AppName is open. Close it (your work is saved automatically), then press Retry.",
    "$AppName Setup", 'RetryCancel', 'Warning')
  if ($r -ne 'Retry') { exit 2 }
}

$work = Join-Path ([IO.Path]::GetTempPath()) ("misc-setup-" + [Guid]::NewGuid().ToString('N'))
try {
  Expand-Archive -LiteralPath $Payload -DestinationPath $work -Force
  $source = Join-Path $work 'misc-windows-x64'
  if (-not (Test-Path (Join-Path $source $ExeName))) { Fail "The installer is damaged: $ExeName is missing." }

  if ($isUpgrade) {
    # Only the old program files are removed (the folder carries our marker,
    # so it holds nothing else). User data lives elsewhere.
    Get-ChildItem -LiteralPath $InstallDir -Force | Remove-Item -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
  Copy-Item -Path (Join-Path $source '*') -Destination $InstallDir -Recurse -Force
  Copy-Item -LiteralPath (Join-Path $Here 'uninstall.ps1') -Destination $InstallDir -Force
} finally {
  if (Test-Path $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}

$startMenuLink = Join-Path ([Environment]::GetFolderPath('Programs')) "$AppName.lnk"
$desktopLink = Join-Path ([Environment]::GetFolderPath('Desktop')) "$AppName.lnk"

if (-not $NoStartMenu) { New-Shortcut $startMenuLink $exePath $InstallDir }
if ($DesktopShortcut) { New-Shortcut $desktopLink $exePath $InstallDir }

@{
  app = $AppName; version = $Version; installedAt = (Get-Date).ToString('o')
  startMenuShortcut = $(if ($NoStartMenu) { $null } else { $startMenuLink })
  desktopShortcut = $(if ($DesktopShortcut) { $desktopLink } else { $null })
  registered = (-not $NoStartMenu)
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $InstallDir $Marker) -Encoding UTF8

if (-not $NoStartMenu) {
  $sizeKb = [int]((Get-ChildItem -LiteralPath $InstallDir -Recurse -File | Measure-Object Length -Sum).Sum / 1KB)
  $un = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$InstallDir\uninstall.ps1`""
  New-Item -Path $UninstallKey -Force | Out-Null
  $props = @{
    DisplayName = $AppName; DisplayVersion = $Version; Publisher = $AppName
    DisplayIcon = "$exePath,0"; InstallLocation = $InstallDir
    UninstallString = $un; QuietUninstallString = "$un -Quiet"
  }
  foreach ($k in $props.Keys) { New-ItemProperty -Path $UninstallKey -Name $k -Value $props[$k] -PropertyType String -Force | Out-Null }
  foreach ($k in @('NoModify', 'NoRepair')) { New-ItemProperty -Path $UninstallKey -Name $k -Value 1 -PropertyType DWord -Force | Out-Null }
  New-ItemProperty -Path $UninstallKey -Name 'EstimatedSize' -Value $sizeKb -PropertyType DWord -Force | Out-Null
}

# The built-in web browser panel needs the Microsoft Edge WebView2 Runtime
# (part of Windows 11 and of current Windows 10). Everything else works without it.
$wv = @(
  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
  'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
  'HKCU:\Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
) | Where-Object { Test-Path $_ }
$note = ''
if (-not $wv) {
  $note = "`n`nNote: the Microsoft Edge WebView2 Runtime was not found. misc. works without it, " +
    "but its built-in web browser panel needs it (free from Microsoft)."
}

$verb = if ($isUpgrade) { 'updated' } else { 'installed' }
if ($Quiet) {
  Write-Output "$AppName $Version $verb in $InstallDir$note"
} else {
  $r = [System.Windows.Forms.MessageBox]::Show(
    "$AppName $Version was $verb.$note`n`nOpen $AppName now?",
    "$AppName Setup", 'YesNo', 'Information')
  if ($r -eq 'Yes' -and -not $NoLaunch) { Start-Process -FilePath $exePath -WorkingDirectory $InstallDir }
}
exit 0

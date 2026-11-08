<#
  misc. uninstaller (copied into the install folder by Setup; started from
  Settings > Apps > Installed apps > misc.).

  Removes the program files, the shortcuts Setup made, the Apps & features
  entry and the Explorer "Send to > misc." entry if it points at this copy.

  Your data is kept: %APPDATA%\THEapp, %APPDATA%\THEapp-hub,
  %LOCALAPPDATA%\THEapp and Documents\THEapp Backups / Exports are not
  touched. Delete them yourself only if you really want to erase everything.
#>
param([switch]$Quiet)
$ErrorActionPreference = 'Stop'

$AppName = 'misc.'
$ExeName = 'misc.exe'
$Marker = 'misc.install.json'
$UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\misc'
$InstallDir = $PSScriptRoot.TrimEnd('\')
$exePath = Join-Path $InstallDir $ExeName

Add-Type -AssemblyName System.Windows.Forms

function Say([string]$text, [string]$icon = 'Information') {
  if ($Quiet) { Write-Output $text; return }
  [void][System.Windows.Forms.MessageBox]::Show($text, "Uninstall $AppName", 'OK', $icon)
}

$markerFile = Join-Path $InstallDir $Marker
if (-not (Test-Path $markerFile)) {
  Say "$InstallDir is not a $AppName install folder. Nothing was removed." 'Error'
  exit 1
}
$info = Get-Content -LiteralPath $markerFile -Raw | ConvertFrom-Json

if (-not $Quiet) {
  $r = [System.Windows.Forms.MessageBox]::Show(
    "Remove $AppName from this PC?`n`nYour notes, settings and backups are kept " +
    "(in %APPDATA%\THEapp and Documents).",
    "Uninstall $AppName", 'YesNo', 'Question')
  if ($r -ne 'Yes') { exit 2 }
}

while (Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and ($_.Path -ieq $exePath) }) {
  if ($Quiet) { Say "$AppName is still running. Close it and try again." 'Error'; exit 1 }
  $r = [System.Windows.Forms.MessageBox]::Show(
    "$AppName is open. Close it, then press Retry.", "Uninstall $AppName", 'RetryCancel', 'Warning')
  if ($r -ne 'Retry') { exit 2 }
}

# Shortcuts: only the ones Setup made, and only while they still point here.
$shell = New-Object -ComObject WScript.Shell
$links = @($info.startMenuShortcut, $info.desktopShortcut,
  (Join-Path $env:APPDATA 'Microsoft\Windows\SendTo\misc..lnk')) | Where-Object { $_ }
foreach ($l in $links) {
  if (Test-Path -LiteralPath $l) {
    $target = $shell.CreateShortcut($l).TargetPath
    if ($target -and ($target -ieq $exePath)) { Remove-Item -LiteralPath $l -Force }
  }
}

if ($info.registered -and (Test-Path $UninstallKey)) {
  $loc = (Get-ItemProperty -Path $UninstallKey -ErrorAction SilentlyContinue).InstallLocation
  if ($loc -and ($loc.TrimEnd('\') -ieq $InstallDir)) { Remove-Item -Path $UninstallKey -Recurse -Force }
}

# Program files. This script is already loaded, so deleting it is safe.
Set-Location ([IO.Path]::GetTempPath())
Remove-Item -LiteralPath $InstallDir -Recurse -Force

Say "$AppName was removed. Your data was kept in %APPDATA%\THEapp."
exit 0

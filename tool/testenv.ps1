<#
  THEapp isolated manual-testing environment (test data only).

  Run from the project folder, for example:
    powershell -ExecutionPolicy Bypass -File tool\testenv.ps1 info

  Commands:
    setup       create the test folders and marker files (no data copied)
    build       build a separate test copy of the app (profile build) into <root>\bin
    app         start the test app on the test data folder
    hub-start   start the test hub (own folder, port 47799, this PC only;
                add -PrivateHost 100.x.y.z to also listen on Tailscale)
    ts-info     show this PC's Tailscale address and status (read-only)
    remote-check -PrivateHost 100.x.y.z   check the test hub through Tailscale
    hub-status  status of the test hub
    hub-pair    one-time pairing code from the TEST hub
    hub-stop    stop the test hub
    info        show the paths and port in use
    clean       delete the whole test environment (asks you to type DELETE)

  Never touches %APPDATA%\THEapp or %APPDATA%\THEapp-hub: every hub command
  passes --data and the app is started with --data-dir=, which the app only
  accepts for a folder holding the .theapp-test-data marker.
#>
param(
  [Parameter(Position = 0)][string]$Command = 'info',
  [string]$Root = '',
  # This PC's Tailscale address (100.x.y.z), for hub-start / remote-check.
  [string]$PrivateHost = ''
)
$ErrorActionPreference = 'Stop'
# Default: Documents\THEapp\THEapp-TESTENV (next to the project, outside the
# repository and outside %APPDATA%). $PSScriptRoot is empty in param defaults.
if (-not $Root) {
  $Root = Join-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot))) 'THEapp-TESTENV'
}

$Project = Split-Path $PSScriptRoot
$Port = 47799
$AppDir = Join-Path $Root 'app'
$HubDir = Join-Path $Root 'hub'
$BinDir = Join-Path $Root 'bin'
$Exe = Join-Path $BinDir 'flutter_application_1.exe'
$Dart = 'C:\src\flutter\bin\dart.bat'
$Flutter = 'C:\src\flutter\bin\flutter.bat'
$RootMarker = Join-Path $Root '.theapp-test-env'

function Full([string]$p) { [IO.Path]::GetFullPath($p).TrimEnd('\') + '\' }

# Refuse any test path inside the real data folders.
$real = @((Join-Path $env:APPDATA 'THEapp'), (Join-Path $env:APPDATA 'THEapp-hub'))
foreach ($r in $real) {
  foreach ($p in @($Root, $AppDir, $HubDir)) {
    $a = Full $p; $b = Full $r
    if ($a.StartsWith($b, [StringComparison]::OrdinalIgnoreCase) -or
        $b.StartsWith($a, [StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing: $p overlaps real data folder $r"
    }
  }
}

# Only Tailscale addresses (100.64.0.0/10) — never a home-network or public one.
function Assert-Tailscale([string]$ip) {
  $p = $ip.Split('.')
  if ($p.Count -ne 4 -or $p[0] -ne '100' -or [int]$p[1] -lt 64 -or [int]$p[1] -gt 127) {
    throw "Refusing: $ip is not a Tailscale address (100.64.x.x - 100.127.x.x)."
  }
}

function Need-Setup {
  if (-not (Test-Path $RootMarker)) { throw "Run 'setup' first ($Root has no test marker)." }
}

function Hub([string[]]$HubArgs) {
  Need-Setup
  Push-Location $Project
  try { & $Dart run bin/thehub.dart @HubArgs --data $HubDir } finally { Pop-Location }
}

switch ($Command) {
  'setup' {
    foreach ($d in @($Root, $AppDir, $HubDir, $BinDir)) {
      New-Item -ItemType Directory -Force -Path $d | Out-Null
    }
    Set-Content -Path $RootMarker -Value 'THEapp test environment. Safe to delete with: tool\testenv.ps1 clean' -Encoding utf8
    Set-Content -Path (Join-Path $AppDir '.theapp-test-data') -Value 'test data only' -Encoding utf8
    Set-Content -Path (Join-Path $HubDir '.theapp-test-data') -Value 'test hub only' -Encoding utf8
    "Test environment ready at $Root"
  }
  'build' {
    Need-Setup
    Push-Location $Project
    $build = (git -C $Project rev-parse --short HEAD)
    try { & $Flutter build windows --profile "--dart-define=THEAPP_BUILD=$build" } finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }
    $out = Join-Path $Project 'build\windows\x64\runner\Profile'
    # Mirrors only into <root>\bin (test-only folder).
    robocopy $out $BinDir /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Copy failed ($LASTEXITCODE)." }
    "Test build copied to $BinDir"
  }
  'app' {
    Need-Setup
    if (-not (Test-Path $Exe)) { throw "No test build yet. Run 'build' first." }
    Start-Process -FilePath $Exe -ArgumentList "--data-dir=$AppDir" -WorkingDirectory $BinDir
    "Test app started on $AppDir"
  }
  'hub-start' {
    Need-Setup
    $extra = ''
    if ($PrivateHost) {
      Assert-Tailscale $PrivateHost
      $extra = " --private-host $PrivateHost"
    }
    $cmd = "Set-Location '$Project'; & '$Dart' run bin/thehub.dart serve --data '$HubDir' --port $Port$extra"
    Start-Process powershell -ArgumentList '-NoProfile', '-Command', $cmd -WindowStyle Minimized
    "Test hub starting on http://127.0.0.1:$Port$(if ($PrivateHost) { " and http://${PrivateHost}:$Port" }) (data: $HubDir). Check with: hub-status"
  }
  'ts-info' {
    # Read-only: what Tailscale reports on this PC.
    $ts = Get-Command tailscale -ErrorAction SilentlyContinue
    if (-not $ts) { 'Tailscale is not installed on this PC.'; break }
    "Tailscale IPv4: $(& $ts.Source ip -4)"
    & $ts.Source status
  }
  'remote-check' {
    Need-Setup
    if (-not $PrivateHost) { throw 'Give this PC''s Tailscale address: -PrivateHost 100.x.y.z' }
    Assert-Tailscale $PrivateHost
    Push-Location $Project
    try { & $Dart run tool/remote_check.dart --data $HubDir --address $PrivateHost } finally { Pop-Location }
  }
  'hub-status' { Hub @('status') }
  'hub-pair' { Hub @('pair') }
  'hub-stop' { Hub @('stop') }
  'info' {
    "Test root : $Root  (ready: $(Test-Path $RootMarker))"
    "App data  : $AppDir"
    "Hub data  : $HubDir"
    "Hub port  : $Port   (real hub: 47710, untouched)"
    "Test app  : $Exe  (built: $(Test-Path $Exe))"
    "Pair URL  : http://127.0.0.1:$Port"
  }
  'clean' {
    if (-not (Test-Path $RootMarker)) { throw "$Root is not a test environment (no marker). Nothing deleted." }
    if (Test-Path (Join-Path $HubDir 'hub.json')) { throw 'The test hub seems to be running. Run hub-stop first.' }
    $answer = Read-Host "Type DELETE to remove $Root and everything in it"
    if ($answer -ne 'DELETE') { 'Cancelled. Nothing deleted.'; break }
    Remove-Item -Recurse -Force -LiteralPath $Root
    "Removed $Root"
  }
  default { throw "Unknown command '$Command'. See the top of tool\testenv.ps1." }
}

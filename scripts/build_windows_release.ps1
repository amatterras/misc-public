<#
  Builds the misc. Windows release (x64, Release mode) and packages it.

  Run from anywhere:
    powershell -ExecutionPolicy Bypass -File scripts\build_windows_release.ps1

  Output (all under dist\windows, ignored by git):
    misc-windows-x64\        portable app: misc.exe, DLLs, data\
    misc-windows-x64.zip     the same folder, zipped
    misc-Setup.exe           per-user installer (Windows IExpress package)

  Options:
    -SkipAnalyze   skip `flutter analyze`
    -RunTests      also run `flutter test` (slow: about 45 minutes)
    -SkipInstaller build only the portable folder and zip

  Stops at the first real failure with a nonzero exit code. Only the files
  this script generates under dist\windows are replaced; nothing else is
  deleted. The real app data (%APPDATA%\THEapp) is never touched.
#>
param(
  [switch]$SkipAnalyze,
  [switch]$RunTests,
  [switch]$SkipInstaller
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$Project = Split-Path $PSScriptRoot
$Dist = Join-Path $Project 'dist\windows'
$PackageName = 'misc-windows-x64'
$Portable = Join-Path $Dist $PackageName
$Zip = Join-Path $Dist "$PackageName.zip"
$Setup = Join-Path $Dist 'misc-Setup.exe'
$ReleaseDir = Join-Path $Project 'build\windows\x64\runner\Release'
$BuiltExe = 'flutter_application_1.exe'   # BINARY_NAME, kept on purpose (README "Naming")
$ShippedExe = 'misc.exe'
# Visual C++ runtime, shipped next to the exe so a PC without the
# "Microsoft Visual C++ Redistributable" can still start the app.
$CrtDlls = @('msvcp140.dll', 'msvcp140_1.dll', 'msvcp140_2.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')

function Step([string]$t) { Write-Host ''; Write-Host "==> $t" -ForegroundColor Cyan }
function Die([string]$t) { Write-Host "FAILED: $t" -ForegroundColor Red; exit 1 }
function Run([string]$exe, [string[]]$arguments) {
  & $exe @arguments
  if ($LASTEXITCODE -ne 0) { Die "$exe $($arguments -join ' ') exited with $LASTEXITCODE" }
}
function Size([string]$path) {
  if (Test-Path $path -PathType Container) {
    $b = (Get-ChildItem -LiteralPath $path -Recurse -File | Measure-Object Length -Sum).Sum
  } else { $b = (Get-Item -LiteralPath $path).Length }
  '{0:N1} MB' -f ($b / 1MB)
}
# Removes a path this script generated, and only inside dist\windows.
function Remove-Generated([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return }
  $full = [IO.Path]::GetFullPath($path)
  if (-not $full.StartsWith(([IO.Path]::GetFullPath($Dist) + '\'), [StringComparison]::OrdinalIgnoreCase)) {
    Die "Refusing to delete $full (outside $Dist)"
  }
  Remove-Item -LiteralPath $full -Recurse -Force
}

Push-Location $Project
try {
  # ------------------------------------------------------------ 1. Flutter
  Step 'Checking Flutter'
  $flutterCmd = Get-Command flutter.bat -ErrorAction SilentlyContinue
  if (-not $flutterCmd) { $flutterCmd = Get-Command flutter -ErrorAction SilentlyContinue }
  if ($flutterCmd) { $Flutter = $flutterCmd.Source }
  elseif (Test-Path 'C:\src\flutter\bin\flutter.bat') { $Flutter = 'C:\src\flutter\bin\flutter.bat' }
  else { Die 'Flutter was not found on PATH (or in C:\src\flutter).' }
  Run $Flutter @('--version')

  # ------------------------------------------------------------ 2. Prerequisites
  Step 'Checking Windows build prerequisites'
  if (-not [Environment]::Is64BitOperatingSystem) { Die 'A 64-bit Windows is required to build.' }
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (-not (Test-Path $vswhere)) { Die 'Visual Studio was not found (vswhere.exe missing). Install Visual Studio with "Desktop development with C++".' }
  $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
  if (-not $vs) { Die 'Visual Studio has no C++ x64 build tools ("Desktop development with C++" workload).' }
  Write-Host "Visual Studio: $vs"
  $crtDir = Get-ChildItem -Path (Join-Path $vs 'VC\Redist\MSVC') -Directory -ErrorAction SilentlyContinue |
    Sort-Object { try { [version]$_.Name } catch { [version]'0.0' } } -Descending |
    ForEach-Object { Get-ChildItem -Path (Join-Path $_.FullName 'x64') -Directory -Filter 'Microsoft.VC14*.CRT' -ErrorAction SilentlyContinue } |
    Select-Object -First 1
  if (-not $crtDir) { Die "Visual C++ runtime redistributable folder not found under $vs\VC\Redist\MSVC" }
  Write-Host "VC++ runtime: $($crtDir.FullName)"
  $config = & $Flutter config --list | Out-String
  if ($config -match 'enable-windows-desktop:\s*false') { Die 'Windows desktop support is disabled. Run: flutter config --enable-windows-desktop' }
  if (-not (Test-Path (Join-Path $Project 'windows\CMakeLists.txt'))) { Die 'The project has no windows\ folder.' }
  # A running copy of the Release exe blocks the linker (LNK1168).
  $lockedBy = Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -and $_.Path.StartsWith($ReleaseDir, [StringComparison]::OrdinalIgnoreCase) }
  if ($lockedBy) { Die "Close misc. first: it is running from $ReleaseDir (PID $($lockedBy.Id -join ', '))." }

  # ------------------------------------------------------------ 3. Dependencies
  Step 'flutter pub get'
  Run $Flutter @('pub', 'get')

  # ------------------------------------------------------------ 4. Checks
  if (-not $SkipAnalyze) {
    Step 'flutter analyze'
    Run $Flutter @('analyze')
  }
  if ($RunTests) {
    Step 'flutter test'
    Run $Flutter @('test')
  }

  # ------------------------------------------------------------ 5. Build
  # Build label shown in Settings and the log (same scheme as codemagic.yaml):
  # the commit, plus "-modified" when the working tree has uncommitted changes.
  $build = 'unknown'
  $git = Get-Command git -ErrorAction SilentlyContinue
  if ($git) {
    try {
      # Windows PowerShell turns git's stderr into errors under 'Stop'.
      $ErrorActionPreference = 'Continue'
      $hash = (& git -C $Project rev-parse --short HEAD 2>$null)
      if ($LASTEXITCODE -eq 0 -and $hash) {
        $build = "$hash".Trim()
        $dirty = (& git -C $Project status --porcelain --untracked-files=no 2>$null)
        if ($dirty) { $build += '-modified' }
      }
    } catch { $build = 'unknown' } finally { $ErrorActionPreference = 'Stop' }
  }
  Step "flutter build windows --release (build $build)"
  Run $Flutter @('build', 'windows', '--release', "--dart-define=THEAPP_BUILD=$build")
  foreach ($f in @($BuiltExe, 'flutter_windows.dll', 'data\app.so', 'data\icudtl.dat', 'data\flutter_assets\AssetManifest.bin')) {
    if (-not (Test-Path (Join-Path $ReleaseDir $f))) { Die "Build output is missing $f in $ReleaseDir" }
  }

  # ------------------------------------------------------------ 6. Portable folder + zip
  Step "Assembling $Portable"
  New-Item -ItemType Directory -Force -Path $Dist | Out-Null
  Remove-Generated $Portable
  Remove-Generated $Zip
  New-Item -ItemType Directory -Force -Path $Portable | Out-Null
  Copy-Item -Path (Join-Path $ReleaseDir '*') -Destination $Portable -Recurse -Force
  # Build leftovers that are not part of the app.
  Get-ChildItem -LiteralPath $Portable -File | Where-Object { $_.Extension -in @('.pdb', '.lib', '.exp', '.ilk') } |
    Remove-Item -Force
  Rename-Item -LiteralPath (Join-Path $Portable $BuiltExe) -NewName $ShippedExe
  foreach ($dll in $CrtDlls) {
    $src = Join-Path $crtDir.FullName $dll
    if (Test-Path $src) { Copy-Item -LiteralPath $src -Destination $Portable -Force }
    elseif ($dll -in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) { Die "Missing $dll in $($crtDir.FullName)" }
  }
  Set-Content -LiteralPath (Join-Path $Portable 'README.txt') -Encoding ASCII -Value @(
    'misc. for Windows 10/11 (x64) - portable copy',
    '',
    'Start misc.exe. Keep every file in this folder together: misc.exe needs',
    'the DLLs and the data folder next to it.',
    '',
    'Your notes and settings are NOT stored in this folder. They are in',
    '%APPDATA%\THEapp (backups/exports in Documents), so you can replace or',
    'delete this folder without losing data.'
  )

  # Entries are written one by one with standard "/" separators: both
  # Compress-Archive and ZipFile.CreateFromDirectory on Windows PowerShell 5.1
  # write "\", which some unzip tools turn into odd file names.
  Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
  $zipStream = [IO.File]::Open($Zip, [IO.FileMode]::CreateNew)
  try {
    $archive = New-Object IO.Compression.ZipArchive($zipStream, [IO.Compression.ZipArchiveMode]::Create)
    try {
      $baseLen = (Split-Path $Portable).Length + 1
      foreach ($file in Get-ChildItem -LiteralPath $Portable -Recurse -File) {
        $entry = $file.FullName.Substring($baseLen).Replace('\', '/')
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
          $archive, $file.FullName, $entry, [IO.Compression.CompressionLevel]::Optimal)
      }
    } finally { $archive.Dispose() }
  } finally { $zipStream.Dispose() }

  # ------------------------------------------------------------ 7. Installer
  if (-not $SkipInstaller) {
    Step 'Building misc-Setup.exe (IExpress)'
    $iexpress = Join-Path $env:SystemRoot 'System32\iexpress.exe'
    if (-not (Test-Path $iexpress)) { Die 'iexpress.exe (part of Windows) was not found.' }
    $pubspec = Get-Content (Join-Path $Project 'pubspec.yaml') -Raw
    if ($pubspec -notmatch '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)') { Die 'No version in pubspec.yaml' }
    $version = $Matches[1]

    $stage = Join-Path $Dist '.installer-stage'
    Remove-Generated $stage
    Remove-Generated $Setup
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    Copy-Item -LiteralPath $Zip -Destination (Join-Path $stage 'payload.zip')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'installer\install.ps1') -Destination $stage
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'installer\uninstall.ps1') -Destination $stage
    Set-Content -LiteralPath (Join-Path $stage 'app.version') -Value $version -Encoding ASCII -NoNewline

    $sed = Join-Path $stage 'misc-setup.sed'
    Set-Content -LiteralPath $sed -Encoding ASCII -Value @(
      '[Version]', 'Class=IEXPRESS', 'SEDVersion=3',
      '[Options]', 'PackagePurpose=InstallApp', 'ShowInstallProgramWindow=1',
      'HideExtractAnimation=0', 'UseLongFileName=1', 'InsideCompressed=0',
      'CAB_FixedSize=0', 'CAB_ResvCodeSigning=0', 'RebootMode=N',
      'InstallPrompt=%InstallPrompt%', 'DisplayLicense=%DisplayLicense%',
      'FinishMessage=%FinishMessage%', 'TargetName=%TargetName%',
      'FriendlyName=%FriendlyName%', 'AppLaunched=%AppLaunched%',
      'PostInstallCmd=%PostInstallCmd%', 'AdminQuietInstCmd=%AdminQuietInstCmd%',
      'UserQuietInstCmd=%UserQuietInstCmd%', 'SourceFiles=SourceFiles',
      '[Strings]', 'InstallPrompt=', 'DisplayLicense=', 'FinishMessage=',
      "TargetName=$Setup", 'FriendlyName=misc. Setup',
      'AppLaunched=powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File install.ps1',
      'PostInstallCmd=<None>', 'AdminQuietInstCmd=', 'UserQuietInstCmd=',
      'FILE0="payload.zip"', 'FILE1="install.ps1"', 'FILE2="uninstall.ps1"', 'FILE3="app.version"',
      '[SourceFiles]', "SourceFiles0=$stage\",
      '[SourceFiles0]', '%FILE0%=', '%FILE1%=', '%FILE2%=', '%FILE3%='
    )
    $p = Start-Process -FilePath $iexpress -ArgumentList @('/N', '/Q', $sed) -Wait -PassThru
    if ($p.ExitCode -ne 0 -or -not (Test-Path $Setup)) { Die "IExpress failed (exit $($p.ExitCode))." }
    Remove-Generated $stage
  }

  # ------------------------------------------------------------ 8. Verify
  Step 'Verifying output'
  $expect = @($ShippedExe, 'flutter_windows.dll', 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll',
    'data\app.so', 'data\icudtl.dat', 'data\flutter_assets\AssetManifest.bin',
    'data\flutter_assets\assets\motivation\quotes.json', 'data\flutter_assets\assets\motivation\greetings.json')
  foreach ($f in $expect) {
    if (-not (Test-Path (Join-Path $Portable $f))) { Die "Portable folder is missing $f" }
  }
  if (Test-Path (Join-Path $Portable $BuiltExe)) { Die "Portable folder still has $BuiltExe" }
  $ver = (Get-Item (Join-Path $Portable $ShippedExe)).VersionInfo
  if ($ver.ProductName -ne 'misc.') { Die "misc.exe ProductName is '$($ver.ProductName)', expected 'misc.'" }
  if (-not (Test-Path $Zip)) { Die "Missing $Zip" }
  if (-not $SkipInstaller -and -not (Test-Path $Setup)) { Die "Missing $Setup" }

  # ------------------------------------------------------------ 9. Summary
  Step 'Done'
  Write-Host "Version          : $($ver.ProductVersion)"
  Write-Host "Portable folder  : $Portable  ($(Size $Portable))"
  Write-Host "Portable zip     : $Zip  ($(Size $Zip))"
  if (-not $SkipInstaller) { Write-Host "Installer        : $Setup  ($(Size $Setup))" }
  exit 0
} finally {
  Pop-Location
}

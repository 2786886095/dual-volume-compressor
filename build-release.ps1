param(
    [string]$Version = '1.0.1',
    [switch]$SkipWindowsBuild,
    [switch]$SkipAndroidBuild,
    [switch]$SkipSetupBuild
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$distWindows = Join-Path $root 'dist\windows'
$windowsStage = Join-Path $root 'dist\.windows-release-stage'
$windowsZip = Join-Path $distWindows "DualVolumeCompressor-Windows-x64-v$Version.zip"

if (-not $SkipWindowsBuild) {
    & (Join-Path $root 'windows\build-windows.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Windows 构建失败。' }
}
if (-not $SkipAndroidBuild) {
    & (Join-Path $root 'android-app\build-android.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Android 构建失败。' }
}
if (-not $SkipSetupBuild) {
    & (Join-Path $root 'installer\windows\build-setup.ps1') -Version $Version -SkipWindowsBuild
    if ($LASTEXITCODE -ne 0) { throw 'Windows Setup 构建失败。' }
}

if (Test-Path -LiteralPath $windowsStage) { [IO.Directory]::Delete($windowsStage, $true) }
New-Item -ItemType Directory -Force -Path (Join-Path $windowsStage 'windows\bin'), (Join-Path $windowsStage 'windows'), (Join-Path $windowsStage 'dist\windows'), (Join-Path $windowsStage 'Assets') | Out-Null
$rootFiles = @('DualVolumeCompressor.ps1', 'Start-Compressor.bat', 'Install-Windows11-ContextMenu.bat', 'Remove-Windows11-ContextMenu.bat', 'README.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md')
foreach ($file in $rootFiles) { Copy-Item -LiteralPath (Join-Path $root $file) -Destination (Join-Path $windowsStage $file) }
foreach ($asset in @('AppIcon.ico', 'Square150x150Logo.png', 'Square44x44Logo.png', 'StoreLogo.png')) {
    Copy-Item -LiteralPath (Join-Path $root "Assets\$asset") -Destination (Join-Path $windowsStage "Assets\$asset")
}
Copy-Item -LiteralPath (Join-Path $root 'windows\bin\DualVolumeContextMenu.dll') -Destination (Join-Path $windowsStage 'windows\bin\DualVolumeContextMenu.dll')
Copy-Item -LiteralPath (Join-Path $root 'windows\bin\DualVolumeLauncher.exe') -Destination (Join-Path $windowsStage 'windows\bin\DualVolumeLauncher.exe')
Copy-Item -LiteralPath (Join-Path $root 'windows\install-context-menu.ps1') -Destination (Join-Path $windowsStage 'windows\install-context-menu.ps1')
Copy-Item -LiteralPath (Join-Path $root 'windows\uninstall-context-menu.ps1') -Destination (Join-Path $windowsStage 'windows\uninstall-context-menu.ps1')
Copy-Item -LiteralPath (Join-Path $distWindows 'DualVolumeCompressor.ContextMenu.msix') -Destination (Join-Path $windowsStage 'dist\windows\DualVolumeCompressor.ContextMenu.msix')
Copy-Item -LiteralPath (Join-Path $distWindows 'DualVolumeCompressor.ContextMenu.cer') -Destination (Join-Path $windowsStage 'dist\windows\DualVolumeCompressor.ContextMenu.cer')

if (Test-Path -LiteralPath $windowsZip) { [IO.File]::Delete($windowsZip) }
Compress-Archive -Path (Join-Path $windowsStage '*') -DestinationPath $windowsZip -CompressionLevel Optimal
[IO.Directory]::Delete($windowsStage, $true)

Get-ChildItem -LiteralPath (Join-Path $root 'dist') -Recurse -File | Where-Object { $_.Extension -in '.apk', '.exe', '.zip', '.msix', '.cer', '.gz' } | Get-FileHash -Algorithm SHA256

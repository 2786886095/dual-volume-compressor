param(
    [switch]$DevelopmentSigning
)

$ErrorActionPreference = 'Stop'
$sourceRoot = $PSScriptRoot
$repositoryRoot = Split-Path -Parent $sourceRoot
$distDir = Join-Path $repositoryRoot 'dist\android'
$cacheRoot = Join-Path $env:SystemDrive 'DualVolumeBuildCache'
$workRoot = $sourceRoot

if ($sourceRoot -match '[^\x00-\x7F]') {
    $workRoot = Join-Path $env:SystemDrive 'DualVolumeBuild\android-app'
    New-Item -ItemType Directory -Force -Path $workRoot | Out-Null
    & robocopy $sourceRoot $workRoot /MIR /XD build .dart_tool .gradle /XF key.properties release-keystore.jks | Out-Null
    if ($LASTEXITCODE -gt 7) { throw "复制到 ASCII 构建路径失败，Robocopy 退出码 $LASTEXITCODE" }
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'android\key.properties') -Destination (Join-Path $workRoot 'android\key.properties') -ErrorAction SilentlyContinue
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'android\release-keystore.jks') -Destination (Join-Path $workRoot 'android\release-keystore.jks') -ErrorAction SilentlyContinue
}

$keyProperties = Join-Path $workRoot 'android\key.properties'
$keyStore = Join-Path $workRoot 'android\release-keystore.jks'
if (-not $DevelopmentSigning -and (-not (Test-Path $keyProperties) -or -not (Test-Path $keyStore))) {
    throw '正式构建需要 android/key.properties 与 release-keystore.jks；开发测试可加 -DevelopmentSigning。'
}

$env:PUB_CACHE = Join-Path $cacheRoot 'pub'
$env:GRADLE_USER_HOME = Join-Path $cacheRoot 'gradle'
$env:ANDROID_HOME = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { 'C:\Android\Sdk' }
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
New-Item -ItemType Directory -Force -Path $env:PUB_CACHE, $env:GRADLE_USER_HOME, $distDir | Out-Null
$flutter = (Get-Command flutter.bat -ErrorAction Stop).Source

Push-Location $workRoot
try {
    & $flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'flutter pub get 失败。' }
    & $flutter analyze
    if ($LASTEXITCODE -ne 0) { throw 'flutter analyze 失败。' }
    & $flutter test
    if ($LASTEXITCODE -ne 0) { throw 'flutter test 失败。' }
    & $flutter build apk --release --target-platform android-arm64 --split-per-abi
    if ($LASTEXITCODE -ne 0) { throw 'Android Release APK 构建失败。' }
}
finally { Pop-Location }

$versionLine = [IO.File]::ReadAllLines((Join-Path $sourceRoot 'pubspec.yaml'), [Text.UTF8Encoding]::new($false)) | Where-Object { $_ -match '^version:' } | Select-Object -First 1
$version = (($versionLine -split ':', 2)[1].Trim() -split '\+', 2)[0]
$apkName = "DualVolumeCompressor-Android-arm64-v$version.apk"
$apkPath = Join-Path $distDir $apkName
Copy-Item -LiteralPath (Join-Path $workRoot 'build\app\outputs\flutter-apk\app-arm64-v8a-release.apk') -Destination $apkPath -Force

$buildTools = Get-ChildItem -LiteralPath (Join-Path $env:ANDROID_HOME 'build-tools') -Directory | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
$apksigner = Join-Path $buildTools.FullName 'apksigner.bat'
& $apksigner verify --verbose --print-certs $apkPath
if ($LASTEXITCODE -ne 0) { throw 'APK 签名验证失败。' }
Get-FileHash -Algorithm SHA256 -LiteralPath $apkPath

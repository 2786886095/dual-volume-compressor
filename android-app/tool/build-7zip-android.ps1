param(
    [string]$SourceDir = (Join-Path $env:SystemDrive 'DualVolumeBuild\7zip'),
    [string]$NdkRoot = $env:ANDROID_NDK_ROOT,
    [int]$Jobs = [Math]::Max(2, [Environment]::ProcessorCount)
)

$ErrorActionPreference = 'Stop'
$commit = 'f9d78aff31a5f2521ae7ddbdc97c4a8855808959'
$projectRoot = Split-Path -Parent $PSScriptRoot
$jniRoot = Join-Path $projectRoot 'android\app\src\main\jniLibs'

if (-not $NdkRoot) {
    $sdkRoot = if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } elseif ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { 'C:\Android\Sdk' }
    $NdkRoot = Join-Path $sdkRoot 'ndk\28.2.13676358'
}
if (-not (Test-Path -LiteralPath $NdkRoot)) { throw "找不到 Android NDK: $NdkRoot" }

if (-not (Test-Path -LiteralPath (Join-Path $SourceDir '.git'))) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $SourceDir) | Out-Null
    & git clone https://github.com/ip7z/7zip.git $SourceDir
    if ($LASTEXITCODE -ne 0) { throw '克隆 7-Zip 源码失败。' }
}
& git -C $SourceDir fetch origin $commit
if ($LASTEXITCODE -ne 0) { throw '获取指定 7-Zip 提交失败。' }
& git -C $SourceDir checkout --detach $commit
if ($LASTEXITCODE -ne 0) { throw '切换 7-Zip 提交失败。' }

$make = (Get-Command mingw32-make.exe -ErrorAction Stop).Source
$gitExe = (Get-Command git.exe -ErrorAction Stop).Source
$gitRoot = Split-Path -Parent (Split-Path -Parent $gitExe)
$bash = Join-Path $gitRoot 'bin\bash.exe'
if (-not (Test-Path -LiteralPath $bash)) { throw "Git Bash 不存在: $bash" }
$toolchain = Join-Path $NdkRoot 'toolchains\llvm\prebuilt\windows-x86_64'
$clang = (Join-Path $toolchain 'bin\clang.exe').Replace('\', '/')
$clangxx = (Join-Path $toolchain 'bin\clang++.exe').Replace('\', '/')
$alone2 = Join-Path $SourceDir 'CPP\7zip\Bundles\Alone2'
$targets = @(
    @{ Abi = 'arm64-v8a'; Triple = 'aarch64-linux-android24'; LibDir = 'aarch64-linux-android'; Out = 'b/android-arm64' },
    @{ Abi = 'x86_64'; Triple = 'x86_64-linux-android24'; LibDir = 'x86_64-linux-android'; Out = 'b/android-x86_64' }
)

$oldShell = $env:SHELL
$oldPath = $env:PATH
$oldSystemDrive = $env:SystemDrive
try {
    $env:SHELL = $bash.Replace('\', '/')
    $env:PATH = "$(Join-Path $gitRoot 'usr\bin');$(Join-Path $gitRoot 'bin');$oldPath"
    Remove-Item Env:SystemDrive -ErrorAction SilentlyContinue

    Push-Location $alone2
    try {
        foreach ($target in $targets) {
            $output = Join-Path $alone2 $target.Out
            if (Test-Path -LiteralPath $output) { [IO.Directory]::Delete($output, $true) }
            Write-Host "构建 7zz $($target.Abi)..."
            & $make -f makefile.gcc "-j$Jobs" "O=$($target.Out)" "CC=$clang" "CXX=$clangxx" "MY_ARCH=--target=$($target.Triple)" 'LIB2=-ldl'
            if ($LASTEXITCODE -ne 0) { throw "7zz $($target.Abi) 构建失败，退出码 $LASTEXITCODE" }

            $destination = Join-Path $jniRoot $target.Abi
            New-Item -ItemType Directory -Force -Path $destination | Out-Null
            Copy-Item -LiteralPath (Join-Path $output '7zz') -Destination (Join-Path $destination 'lib7zz.so') -Force
            Copy-Item -LiteralPath (Join-Path $toolchain "sysroot\usr\lib\$($target.LibDir)\libc++_shared.so") -Destination (Join-Path $destination 'libc++_shared.so') -Force
        }
    }
    finally { Pop-Location }
}
finally {
    $env:SHELL = $oldShell
    $env:PATH = $oldPath
    if ($null -ne $oldSystemDrive) { $env:SystemDrive = $oldSystemDrive }
}

Get-ChildItem -LiteralPath $jniRoot -Recurse -File | Select-Object FullName, Length

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$binDir = Join-Path $PSScriptRoot 'bin'
$launcherDir = Join-Path $PSScriptRoot 'launcher'
$contextMenuDir = Join-Path $PSScriptRoot 'context-menu'
$packageSource = Join-Path $PSScriptRoot 'package'
$packageStage = Join-Path $PSScriptRoot '.package-stage'
$distDir = Join-Path $projectRoot 'dist\windows'
$packagePath = Join-Path $distDir 'DualVolumeCompressor.ContextMenu.msix'
$certificatePath = Join-Path $distDir 'DualVolumeCompressor.ContextMenu.cer'

New-Item -ItemType Directory -Force -Path $binDir, $distDir | Out-Null
if (Test-Path -LiteralPath $packageStage) {
    [System.IO.Directory]::Delete($packageStage, $true)
}
New-Item -ItemType Directory -Force -Path $packageStage | Out-Null

$clang = (Get-Command clang++.exe -ErrorAction Stop).Source
$windres = (Get-Command windres.exe -ErrorAction Stop).Source
$sdkBinRoot = 'C:\Program Files (x86)\Windows Kits\10\bin'
$sdkVersionDir = Get-ChildItem -LiteralPath $sdkBinRoot -Directory |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'x64\makeappx.exe') } |
    Sort-Object { [version]$_.Name } -Descending |
    Select-Object -First 1
if (-not $sdkVersionDir) {
    throw '找不到 Windows SDK MakeAppx.exe。'
}
$makeAppx = Join-Path $sdkVersionDir.FullName 'x64\makeappx.exe'
$signTool = Join-Path $sdkVersionDir.FullName 'x64\signtool.exe'

Write-Host '编译 Windows 11 IExplorerCommand 扩展...'
& $clang `
    '-std=c++17' '-O2' '-shared' '-static' '-static-libgcc' '-static-libstdc++' `
    (Join-Path $contextMenuDir 'ExplorerCommand.cpp') (Join-Path $contextMenuDir 'ExplorerCommand.def') `
    '-o' (Join-Path $binDir 'DualVolumeContextMenu.dll') `
    '-lole32' '-lshell32' '-lshlwapi' '-luuid'
if ($LASTEXITCODE -ne 0) { throw "右键扩展编译失败，退出码 $LASTEXITCODE" }

Write-Host '编译启动器...'
$launcherResource = Join-Path $launcherDir 'Launcher.res'
Push-Location $launcherDir
try {
    & $windres '-i' 'Launcher.rc' '-o' $launcherResource '-O' 'coff'
    if ($LASTEXITCODE -ne 0) { throw "启动器资源编译失败，退出码 $LASTEXITCODE" }
}
finally {
    Pop-Location
}
& $clang `
    '-std=c++17' '-O2' '-mwindows' '-municode' '-static' '-static-libgcc' '-static-libstdc++' `
    (Join-Path $launcherDir 'Launcher.cpp') $launcherResource `
    '-o' (Join-Path $binDir 'DualVolumeLauncher.exe') `
    '-lshell32'
if ($LASTEXITCODE -ne 0) { throw "启动器编译失败，退出码 $LASTEXITCODE" }

Copy-Item -LiteralPath (Join-Path $packageSource 'AppxManifest.xml') -Destination (Join-Path $packageStage 'AppxManifest.xml')
Write-Host '生成外部位置身份 MSIX...'
& $makeAppx pack /o /d $packageStage /nv /p $packagePath
if ($LASTEXITCODE -ne 0) { throw "MSIX 打包失败，退出码 $LASTEXITCODE" }

$subject = 'CN=Langbai Studio'
$certificateFriendlyName = 'Dual Volume Compressor MSIX Code Signing'
$certificate = Get-ChildItem Cert:\CurrentUser\My |
    Where-Object { $_.Subject -eq $subject -and $_.FriendlyName -eq $certificateFriendlyName -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date).AddDays(30) } |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1
if (-not $certificate) {
    Write-Host '创建本地代码签名证书...'
    $certificate = New-SelfSignedCertificate `
        -Type CodeSigningCert `
        -Subject $subject `
        -FriendlyName $certificateFriendlyName `
        -CertStoreLocation 'Cert:\CurrentUser\My' `
        -KeyAlgorithm RSA `
        -KeyLength 2048 `
        -HashAlgorithm SHA256 `
        -KeyUsage DigitalSignature `
        -KeyExportPolicy NonExportable `
        -NotAfter (Get-Date).AddYears(3)
}
Export-Certificate -Cert $certificate -FilePath $certificatePath -Force | Out-Null

Write-Host '签名 MSIX...'
& $signTool sign /fd SHA256 /sha1 $certificate.Thumbprint /s My $packagePath
if ($LASTEXITCODE -ne 0) { throw "MSIX 签名失败，退出码 $LASTEXITCODE" }

if (Test-Path -LiteralPath $launcherResource) {
    [System.IO.File]::Delete($launcherResource)
}
[System.IO.Directory]::Delete($packageStage, $true)

Write-Host ''
Write-Host 'Windows 构建完成:'
Write-Host (Join-Path $binDir 'DualVolumeContextMenu.dll')
Write-Host (Join-Path $binDir 'DualVolumeLauncher.exe')
Write-Host $packagePath
Write-Host $certificatePath

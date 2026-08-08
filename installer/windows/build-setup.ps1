param(
    [string]$Version = '1.2.2',
    [switch]$SkipWindowsBuild
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$issPath = Join-Path $PSScriptRoot 'DualVolumeCompressor.iss'
$outputPath = Join-Path $projectRoot "dist\windows\DualVolumeCompressor-Setup-x64-v$Version.exe"

if (-not $SkipWindowsBuild) {
    & (Join-Path $projectRoot 'windows\build-windows.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Windows 组件构建失败。' }
}

$iscc = (Get-Command ISCC.exe -ErrorAction Stop).Source
& $iscc "/DMyAppVersion=$Version" $issPath
if ($LASTEXITCODE -ne 0) { throw "Setup 编译失败，退出码 $LASTEXITCODE" }
if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) { throw "Setup 产物未找到: $outputPath" }

$sdkBinRoot = 'C:\Program Files (x86)\Windows Kits\10\bin'
$sdkVersionDir = Get-ChildItem -LiteralPath $sdkBinRoot -Directory |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'x64\signtool.exe') } |
    Sort-Object { [version]$_.Name } -Descending |
    Select-Object -First 1
if (-not $sdkVersionDir) { throw 'Windows SDK SignTool 未找到。' }
$signTool = Join-Path $sdkVersionDir.FullName 'x64\signtool.exe'

$certificate = Get-ChildItem Cert:\CurrentUser\My |
    Where-Object {
        $_.Subject -eq 'CN=Langbai Studio' -and
        $_.FriendlyName -eq 'Dual Volume Compressor MSIX Code Signing' -and
        $_.HasPrivateKey -and
        $_.NotAfter -gt (Get-Date).AddDays(30)
    } |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1
if (-not $certificate) { throw '项目代码签名证书未找到。' }

& $signTool sign /fd SHA256 /sha1 $certificate.Thumbprint /s My $outputPath
if ($LASTEXITCODE -ne 0) { throw "Setup 签名失败，退出码 $LASTEXITCODE" }
& $signTool verify /pa /v $outputPath
if ($LASTEXITCODE -ne 0) { throw "Setup 签名验证失败，退出码 $LASTEXITCODE" }

Get-Item -LiteralPath $outputPath | Select-Object FullName, Length, LastWriteTime
Get-FileHash -LiteralPath $outputPath -Algorithm SHA256

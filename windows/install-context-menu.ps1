$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $quotedScript = '"' + $PSCommandPath.Replace('"', '\"') + '"'
    $process = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $quotedScript
    )
    exit $process.ExitCode
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$packagePath = Join-Path $projectRoot 'dist\windows\DualVolumeCompressor.ContextMenu.msix'
$certificatePath = Join-Path $projectRoot 'dist\windows\DualVolumeCompressor.ContextMenu.cer'
$identityName = 'LangbaiStudio.DualVolumeCompressor'

foreach ($required in @(
    (Join-Path $PSScriptRoot 'bin\DualVolumeContextMenu.dll'),
    (Join-Path $PSScriptRoot 'bin\DualVolumeLauncher.exe'),
    $packagePath,
    $certificatePath,
    (Join-Path $projectRoot 'DualVolumeCompressor.ps1')
)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "缺少安装文件: $required`n请先运行 windows\build-windows.ps1。"
    }
}

$publicCertificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($certificatePath)
foreach ($store in @('Cert:\CurrentUser\TrustedPeople', 'Cert:\LocalMachine\TrustedPeople', 'Cert:\LocalMachine\Root')) {
    $trusted = Get-ChildItem $store |
        Where-Object { $_.Thumbprint -eq $publicCertificate.Thumbprint } |
        Select-Object -First 1
    if (-not $trusted) {
        Import-Certificate -FilePath $certificatePath -CertStoreLocation $store | Out-Null
    }
}

$existing = Get-AppxPackage -Name $identityName -ErrorAction SilentlyContinue
if ($existing) {
    $existing | Remove-AppxPackage
}

Add-AppxPackage -Path $packagePath -ExternalLocation $projectRoot

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ShellRefresh {
    [DllImport("shell32.dll")]
    public static extern void SHChangeNotify(uint eventId, uint flags, IntPtr item1, IntPtr item2);
}
'@
[ShellRefresh]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)

$installed = Get-AppxPackage -Name $identityName
if (-not $installed) {
    throw '右键扩展包注册后未能查询到。'
}

Write-Host 'Windows 11 一级右键菜单已安装。'
Write-Host '菜单名称: 用双层分卷压缩器打开'
Write-Host '如果资源管理器未立即刷新，请注销一次 Windows 或重新启动资源管理器。'

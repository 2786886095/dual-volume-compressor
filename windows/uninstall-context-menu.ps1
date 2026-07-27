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
$identityName = 'LangbaiStudio.DualVolumeCompressor'
$packages = @(Get-AppxPackage -Name $identityName -ErrorAction SilentlyContinue)
foreach ($package in $packages) {
    Remove-AppxPackage -Package $package.PackageFullName
}
$certificatePath = Join-Path $projectRoot 'dist\windows\DualVolumeCompressor.ContextMenu.cer'
if (Test-Path -LiteralPath $certificatePath -PathType Leaf) {
    $certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($certificatePath)
    foreach ($store in @('Cert:\CurrentUser\TrustedPeople', 'Cert:\LocalMachine\TrustedPeople', 'Cert:\LocalMachine\Root')) {
        $installedCertificates = @(Get-ChildItem $store | Where-Object { $_.Thumbprint -eq $certificate.Thumbprint })
        foreach ($installedCertificate in $installedCertificates) {
            Remove-Item -LiteralPath $installedCertificate.PSPath -Force
        }
    }
}
Write-Host 'Windows 11 右键菜单扩展已移除。'

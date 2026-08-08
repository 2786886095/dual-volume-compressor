param(
    [string]$BandizipPath = 'C:\Program Files\Bandizip\bz.exe'
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$appScript = Join-Path $repositoryRoot 'DualVolumeCompressor.ps1'
$testRoot = Join-Path $repositoryRoot '.tmp-tests\ordinary-separate'
$inputRoot = Join-Path $testRoot 'input'
$outputRoot = Join-Path $testRoot 'output'

if (-not (Test-Path -LiteralPath $BandizipPath -PathType Leaf)) {
    throw "Bandizip CLI 未找到: $BandizipPath"
}

if (Test-Path -LiteralPath $testRoot) {
    $resolvedRepository = [IO.Path]::GetFullPath($repositoryRoot).TrimEnd('\') + '\'
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    if (-not $resolvedTestRoot.StartsWith($resolvedRepository, [StringComparison]::OrdinalIgnoreCase)) {
        throw "测试目录越界: $resolvedTestRoot"
    }
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
}

[IO.Directory]::CreateDirectory($inputRoot) | Out-Null
[IO.Directory]::CreateDirectory($outputRoot) | Out-Null
[IO.File]::WriteAllText((Join-Path $inputRoot 'alpha.txt'), 'alpha-content', [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $inputRoot 'beta.log'), 'beta-content', [Text.UTF8Encoding]::new($false))

$sourceLines = [IO.File]::ReadAllLines($appScript)
$formBoundary = -1
for ($index = 0; $index -lt $sourceLines.Length; $index += 1) {
    if ($sourceLines[$index] -match '^\$form\s*=\s*New-Object\s+System\.Windows\.Forms\.Form') {
        $formBoundary = $index
        break
    }
}
if ($formBoundary -lt 1) {
    throw '未找到 Windows 界面初始化边界。'
}

$functionSource = [string]::Join("`r`n", $sourceLines[0..($formBoundary - 1)])
Invoke-Expression $functionSource

$inputs = @(
    (Join-Path $inputRoot 'alpha.txt'),
    (Join-Path $inputRoot 'beta.log')
)
$results = @()
foreach ($inputPath in $inputs) {
    $baseName = Get-InputArchiveBaseName -Path $inputPath
    $job = [pscustomobject]@{
        Engine = 'Bandizip'
        ToolPath = $BandizipPath
        SevenZip = $BandizipPath
        Inputs = [string[]]@($inputPath)
        OutputDir = $outputRoot
        BaseName = $baseName
        DoubleCompressionEnabled = $false
        InnerFormat = '7z'
        OuterFormat = 'zip'
        VolumeMode = '按分卷大小'
        VolumeSpec = '1m'
        VolumeCount = 2
        Level = '5'
        Password = 'regression-password'
        EncryptHeaders = $false
        KeepParts = $false
        Overwrite = $false
    }
    $results += Invoke-CompressionJob -Job $job -Worker $null
}

$archives = @(Get-ChildItem -LiteralPath $outputRoot -File -Filter '*.zip')
$parts = @(Get-ChildItem -LiteralPath $outputRoot -File | Where-Object { $_.Name -match '\.\d{3}$' })
if ($archives.Count -ne 2) { throw "预期生成 2 个压缩包，实际为 $($archives.Count) 个。" }
if ($parts.Count -ne 0) { throw "预期不生成分卷，实际为 $($parts.Count) 个。" }
if (-not (Test-Path -LiteralPath (Join-Path $outputRoot 'alpha.zip') -PathType Leaf)) { throw 'alpha.zip 未生成。' }
if (-not (Test-Path -LiteralPath (Join-Path $outputRoot 'beta.zip') -PathType Leaf)) { throw 'beta.zip 未生成。' }

foreach ($archive in $archives) {
    & $BandizipPath 't' '-p:regression-password' $archive.FullName | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "压缩包完整性验证失败: $($archive.Name)"
    }
}

[pscustomobject]@{
    Mode = 'ordinary-separate'
    ArchiveCount = $archives.Count
    PartCount = $parts.Count
    Archives = [string[]]@($archives.Name)
    Verified = $true
    OutputDirectory = $outputRoot
} | ConvertTo-Json -Compress

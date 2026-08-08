if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $startupInputPaths = [string[]]@($args)
    $launchArguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-STA',
        '-File', "`"$PSCommandPath`""
    )
    foreach ($startupPath in @($startupInputPaths)) {
        $launchArguments += ('"' + $startupPath.Replace('"', '\"') + '"')
    }
    Start-Process powershell.exe -ArgumentList $launchArguments
    exit
}

$script:StartupInputPaths = [string[]]@($args)
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$legacySettingsPath = Join-Path $script:AppDir 'settings.json'
$appDirPrefix = [IO.Path]::GetFullPath($script:AppDir).TrimEnd('\') + '\'
$programFilesRoots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') + '\' }
$isInstalledLocation = @($programFilesRoots | Where-Object {
    $appDirPrefix.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase)
}).Count -gt 0

if ($isInstalledLocation) {
    $settingsDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Langbai Studio\双层分卷压缩器'
    [IO.Directory]::CreateDirectory($settingsDir) | Out-Null
    $script:SettingsPath = Join-Path $settingsDir 'settings.json'
    if (-not (Test-Path -LiteralPath $script:SettingsPath) -and (Test-Path -LiteralPath $legacySettingsPath -PathType Leaf)) {
        Copy-Item -LiteralPath $legacySettingsPath -Destination $script:SettingsPath
    }
}
else {
    $script:SettingsPath = $legacySettingsPath
}
$script:CurrentProcess = $null
$script:InputPaths = New-Object 'System.Collections.Generic.List[string]'
$script:IsLoadingSettings = $false
$script:CancelRequested = $false
$script:AppVersion = [version]'1.2.2'
$script:GitHubRepository = '2786886095/dual-volume-compressor'
$script:UpdateCheckInProgress = $false
$script:CompressionProfiles = New-Object System.Collections.ArrayList

function Get-LatestGitHubRelease {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $headers = @{
        'Accept' = 'application/vnd.github+json'
        'User-Agent' = "DualVolumeCompressor/$($script:AppVersion)"
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $uri = "https://api.github.com/repos/$($script:GitHubRepository)/releases/latest"
    $release = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -TimeoutSec 15
    if ($release.draft -or $release.prerelease) {
        throw 'GitHub 最新发布不是正式版本。'
    }

    $versionMatch = [regex]::Match([string]$release.tag_name, '\d+(?:\.\d+){1,3}')
    if (-not $versionMatch.Success) {
        throw "发布标签格式不正确: $($release.tag_name)"
    }

    $setupAsset = @($release.assets | Where-Object {
        $_.name -match '^DualVolumeCompressor-Setup-x64-v.+\.exe$'
    } | Select-Object -First 1)
    if ($setupAsset.Count -eq 0) {
        throw '最新发布中没有 Windows Setup 安装包。'
    }

    return [pscustomobject]@{
        Version = [version]$versionMatch.Value
        Tag = [string]$release.tag_name
        Name = [string]$release.name
        Notes = [string]$release.body
        PageUrl = [string]$release.html_url
        AssetName = [string]$setupAsset[0].name
        AssetUrl = [string]$setupAsset[0].browser_download_url
        AssetDigest = [string]$setupAsset[0].digest
    }
}

function Download-And-LaunchUpdate {
    param(
        [Parameter(Mandatory = $true)]$ReleaseInfo,
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner,
        [Parameter(Mandatory = $true)][System.Windows.Forms.Label]$StatusLabel,
        [Parameter(Mandatory = $true)][System.Windows.Forms.TextBox]$LogText
    )

    $choice = [System.Windows.Forms.MessageBox]::Show(
        $Owner,
        "发现新版本 v$($ReleaseInfo.Version)。`r`n`r`n是否下载并启动 Setup 安装程序？",
        '发现更新',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
    if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }

    $updateDir = Join-Path $env:TEMP 'DualVolumeCompressor\Updates'
    [IO.Directory]::CreateDirectory($updateDir) | Out-Null
    $setupPath = Join-Path $updateDir ([IO.Path]::GetFileName($ReleaseInfo.AssetName))
    $StatusLabel.Text = '下载更新...'
    Add-LogLine -TextBox $LogText -Line "正在下载更新: $($ReleaseInfo.AssetName)"
    [System.Windows.Forms.Application]::DoEvents()

    Invoke-WebRequest -Uri $ReleaseInfo.AssetUrl -OutFile $setupPath -UseBasicParsing -TimeoutSec 180
    if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf)) {
        throw '更新安装包下载后未找到。'
    }

    if ($ReleaseInfo.AssetDigest -match '^sha256:([0-9a-fA-F]{64})$') {
        $expectedHash = $Matches[1].ToUpperInvariant()
        $actualHash = (Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash
        if ($actualHash -ne $expectedHash) {
            [IO.File]::Delete($setupPath)
            throw '更新安装包 SHA-256 校验不一致。'
        }
        Add-LogLine -TextBox $LogText -Line "更新包校验通过: $actualHash"
    }

    $StatusLabel.Text = '启动安装...'
    Add-LogLine -TextBox $LogText -Line "启动安装程序: $setupPath"
    Start-Process -FilePath $setupPath
    $Owner.Close()
}

function Invoke-UpdateCheck {
    param(
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner,
        [Parameter(Mandatory = $true)][System.Windows.Forms.Button]$UpdateButton,
        [Parameter(Mandatory = $true)][System.Windows.Forms.Label]$StatusLabel,
        [Parameter(Mandatory = $true)][System.Windows.Forms.TextBox]$LogText,
        [switch]$Automatic
    )

    if ($script:UpdateCheckInProgress) {
        return
    }

    $script:UpdateCheckInProgress = $true
    $UpdateButton.Enabled = $false
    $previousStatus = $StatusLabel.Text
    $StatusLabel.Text = '检查更新...'
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $latest = Get-LatestGitHubRelease
        Add-LogLine -TextBox $LogText -Line "GitHub 最新版本: v$($latest.Version)，当前版本: v$($script:AppVersion)"
        if ($latest.Version -gt $script:AppVersion) {
            Download-And-LaunchUpdate -ReleaseInfo $latest -Owner $Owner -StatusLabel $StatusLabel -LogText $LogText
        }
        elseif (-not $Automatic) {
            [System.Windows.Forms.MessageBox]::Show(
                $Owner,
                "当前已是最新版本 v$($script:AppVersion)。",
                '检查更新',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        }
    }
    catch {
        Add-LogLine -TextBox $LogText -Line ('更新检查失败: ' + $_.Exception.Message)
        if (-not $Automatic) {
            [System.Windows.Forms.MessageBox]::Show(
                $Owner,
                $_.Exception.Message,
                '更新检查失败',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
        }
    }
    finally {
        if (-not $Owner.IsDisposed) {
            $UpdateButton.Enabled = $true
            if ($StatusLabel.Text -in @('检查更新...', '下载更新...')) {
                $StatusLabel.Text = $previousStatus
            }
        }
        $script:UpdateCheckInProgress = $false
    }
}

function Quote-WindowsArg {
    param([AllowNull()][string]$Argument)

    if ($null -eq $Argument -or $Argument.Length -eq 0) {
        return '""'
    }

    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    $result = '"'
    $slashes = 0

    foreach ($ch in $Argument.ToCharArray()) {
        if ($ch -eq '\') {
            $slashes += 1
        }
        elseif ($ch -eq '"') {
            if ($slashes -gt 0) {
                $result += ('\' * ($slashes * 2))
                $slashes = 0
            }
            $result += '\"'
        }
        else {
            if ($slashes -gt 0) {
                $result += ('\' * $slashes)
                $slashes = 0
            }
            $result += $ch
        }
    }

    if ($slashes -gt 0) {
        $result += ('\' * ($slashes * 2))
    }

    $result += '"'
    return $result
}

function ConvertTo-CommandLine {
    param([string[]]$Arguments)
    return (($Arguments | ForEach-Object { Quote-WindowsArg $_ }) -join ' ')
}

function Find-SevenZip {
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    $local = Join-Path $script:AppDir 'tools\7z.exe'
    [void]$candidates.Add($local)

    if ($env:ProgramFiles) {
        [void]$candidates.Add((Join-Path $env:ProgramFiles '7-Zip\7z.exe'))
    }
    if (${env:ProgramFiles(x86)}) {
        [void]$candidates.Add((Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe'))
    }

    $cmd = Get-Command '7z.exe' -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) {
        [void]$candidates.Add($cmd.Source)
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}

function Find-Bandizip {
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in @('bz.exe', 'Bandizip.exe')) {
        [void]$candidates.Add((Join-Path $script:AppDir ('tools\' + $name)))
    }

    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if ($root) {
            [void]$candidates.Add((Join-Path $root 'Bandizip\bz.exe'))
            [void]$candidates.Add((Join-Path $root 'Bandizip\Bandizip.exe'))
        }
    }

    foreach ($name in @('bz.exe', 'Bandizip.exe')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) {
            [void]$candidates.Add($cmd.Source)
        }
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}

function Find-CompressionTool {
    param([string]$Engine)

    if ($Engine -eq 'Bandizip') {
        return Find-Bandizip
    }

    return Find-SevenZip
}

function Get-ToolDisplayName {
    param([string]$Engine)

    if ($Engine -eq 'Bandizip') {
        return 'Bandizip'
    }

    return '7z'
}

function ConvertTo-BandizipVolumeSpec {
    param([string]$VolumeSpec)

    $match = [regex]::Match($VolumeSpec, '^(\d+)([kKmMgG])$')
    if (-not $match.Success) {
        return $VolumeSpec
    }

    $value = $match.Groups[1].Value
    switch ($match.Groups[2].Value.ToLowerInvariant()) {
        'k' { return ($value + 'KB') }
        'm' { return ($value + 'MB') }
        'g' { return ($value + 'GB') }
    }

    return $VolumeSpec
}

function Protect-Password {
    param([string]$Password)

    if ([string]::IsNullOrEmpty($Password)) {
        return ''
    }

    try {
        $secure = ConvertTo-SecureString -String $Password -AsPlainText -Force
        return (ConvertFrom-SecureString -SecureString $secure)
    }
    catch {
        return ''
    }
}

function Unprotect-Password {
    param([string]$ProtectedPassword)

    if ([string]::IsNullOrWhiteSpace($ProtectedPassword)) {
        return ''
    }

    try {
        $secure = ConvertTo-SecureString -String $ProtectedPassword
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
        }
        finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
        }
    }
    catch {
        return ''
    }
}

function Load-AppSettings {
    if (-not (Test-Path -LiteralPath $script:SettingsPath -PathType Leaf)) {
        return $null
    }

    try {
        $json = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($json)) {
            return $null
        }

        return ($json | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Save-AppSettings {
    param([pscustomobject]$Settings)

    try {
        $json = $Settings | ConvertTo-Json -Depth 8
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($script:SettingsPath, $json, $utf8NoBom)
    }
    catch {
    }
}

function Set-ComboSelection {
    param(
        [System.Windows.Forms.ComboBox]$ComboBox,
        [AllowNull()][string]$Value
    )

    if (-not [string]::IsNullOrWhiteSpace($Value) -and $ComboBox.Items.Contains($Value)) {
        $ComboBox.SelectedItem = $Value
    }
}

function Set-NumericValue {
    param(
        [System.Windows.Forms.NumericUpDown]$Control,
        [AllowNull()]$Value
    )

    if ($null -eq $Value) {
        return
    }

    try {
        $number = [decimal]$Value
        if ($number -lt $Control.Minimum) {
            $number = $Control.Minimum
        }
        if ($number -gt $Control.Maximum) {
            $number = $Control.Maximum
        }
        $Control.Value = $number
    }
    catch {
    }
}

function Report-ProgressLine {
    param(
        [AllowNull()]$Reporter,
        [string]$Line
    )

    if ($Reporter -is [System.Windows.Forms.TextBox]) {
        Add-LogLine -TextBox $Reporter -Line $Line
        [System.Windows.Forms.Application]::DoEvents()
        return
    }

    try {
        if ($Reporter -and ($Reporter.PSObject.Methods.Name -contains 'ReportProgress')) {
            $Reporter.ReportProgress(0, $Line)
        }
    }
    catch {
    }
}

function Test-CancelRequested {
    param([AllowNull()]$Reporter)

    if ($script:CancelRequested) {
        return $true
    }

    try {
        if ($Reporter -and $Reporter.CancellationPending) {
            return $true
        }
    }
    catch {
    }

    return $false
}

function Write-ListFile {
    param(
        [string]$Path,
        [string[]]$Lines
    )

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($Path, $Lines, $utf8NoBom)
}

function Split-FileEvenly {
    param(
        [string]$SourcePath,
        [int]$PartCount,
        [AllowNull()]$Worker
    )

    if ($PartCount -lt 2) {
        throw '固定分卷数量必须至少为 2。'
    }

    $source = Get-Item -LiteralPath $SourcePath
    if ($source.Length -lt $PartCount) {
        throw ('压缩包只有 {0} 字节，无法均分成 {1} 个非空分卷。' -f $source.Length, $PartCount)
    }

    $baseSize = [long][Math]::Floor($source.Length / $PartCount)
    $remainder = [long]($source.Length % $PartCount)
    $numberWidth = [Math]::Max(3, $PartCount.ToString().Length)
    $buffer = New-Object byte[] (1024 * 1024)
    $parts = New-Object 'System.Collections.Generic.List[object]'
    $inputStream = [System.IO.File]::OpenRead($source.FullName)

    try {
        for ($index = 1; $index -le $PartCount; $index += 1) {
            if (Test-CancelRequested -Reporter $Worker) {
                throw '用户已取消。'
            }

            $partSize = $baseSize
            if ($index -le $remainder) {
                $partSize += 1
            }

            $suffix = $index.ToString(('D' + $numberWidth))
            $partPath = $source.FullName + '.' + $suffix
            $outputStream = [System.IO.File]::Create($partPath)
            try {
                $remaining = $partSize
                while ($remaining -gt 0) {
                    $readSize = [int][Math]::Min([long]$buffer.Length, $remaining)
                    $read = $inputStream.Read($buffer, 0, $readSize)
                    if ($read -le 0) {
                        throw '读取完整压缩包时意外到达文件末尾。'
                    }
                    $outputStream.Write($buffer, 0, $read)
                    $remaining -= $read
                    [System.Windows.Forms.Application]::DoEvents()
                    if (Test-CancelRequested -Reporter $Worker) {
                        throw '用户已取消。'
                    }
                }
            }
            finally {
                $outputStream.Dispose()
            }

            [void]$parts.Add((Get-Item -LiteralPath $partPath))
            Report-ProgressLine -Reporter $Worker -Line ('已均分 {0}/{1}: {2}' -f $index, $PartCount, [System.IO.Path]::GetFileName($partPath))
        }
    }
    finally {
        $inputStream.Dispose()
    }

    return @($parts | ForEach-Object { $_ })
}

function Get-SafeFileName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ('double-archive-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    }

    $safe = $Name.Trim()
    foreach ($ch in [System.IO.Path]::GetInvalidFileNameChars()) {
        $safe = $safe.Replace([string]$ch, '_')
    }

    if ([string]::IsNullOrWhiteSpace($safe)) {
        return ('double-archive-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    }

    return $safe
}

function Get-InputArchiveBaseName {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path -PathType Container) {
        return Get-SafeFileName -Name ([System.IO.DirectoryInfo]$Path).Name
    }

    $fileName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    if ([string]::IsNullOrWhiteSpace($fileName)) {
        $fileName = [System.IO.Path]::GetFileName($Path)
    }

    return Get-SafeFileName -Name $fileName
}

function Invoke-SevenZip {
    param(
        [string]$Exe,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [AllowNull()]$Worker,
        [string]$DisplayName = '7z',
        [bool]$TreatExitCodeOneAsWarning = $true
    )

    $masked = $Arguments | ForEach-Object {
        if ($_ -like '-p*') { '-p********' } else { $_ }
    }
    Report-ProgressLine -Reporter $Worker -Line ('> ' + $DisplayName + ' ' + (ConvertTo-CommandLine $masked))

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = ConvertTo-CommandLine $Arguments
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError = $false
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    try {
        [void]$process.Start()
        $script:CurrentProcess = $process

        while (-not $process.WaitForExit(200)) {
            [System.Windows.Forms.Application]::DoEvents()
            if (Test-CancelRequested -Reporter $Worker) {
                try {
                    if (-not $process.HasExited) {
                        $process.Kill()
                    }
                }
                catch {
                }
                throw '用户已取消。'
            }
        }

        $process.WaitForExit()

        if (Test-CancelRequested -Reporter $Worker) {
            throw '用户已取消。'
        }

        if ($TreatExitCodeOneAsWarning -and $process.ExitCode -eq 1) {
            Report-ProgressLine -Reporter $Worker -Line ($DisplayName + ' 返回警告码 1；请检查是否有文件被跳过。')
        }
        elseif ($process.ExitCode -ne 0) {
            throw ("{0} 失败，退出码: {1}" -f $DisplayName, $process.ExitCode)
        }
    }
    finally {
        if ($script:CurrentProcess -eq $process) {
            $script:CurrentProcess = $null
        }
        $process.Dispose()
    }
}

function Invoke-ArchiveCreate {
    param(
        [string]$Engine,
        [string]$Exe,
        [string]$ArchivePath,
        [string]$Format,
        [string[]]$Inputs,
        [string]$WorkingDirectory,
        [string]$VolumeSpec,
        [string]$Level,
        [string]$Password,
        [bool]$EncryptHeaders,
        [AllowNull()]$Worker,
        [string]$ListFile
    )

    if ($Engine -eq 'Bandizip') {
        $args = @(
            'c',
            ('-fmt:' + $Format),
            ('-l:' + $Level),
            '-y'
        )

        if (-not [string]::IsNullOrWhiteSpace($VolumeSpec)) {
            $args += ('-v:' + (ConvertTo-BandizipVolumeSpec -VolumeSpec $VolumeSpec))
        }

        if ($Password.Length -gt 0) {
            $args += ('-p:' + $Password)
        }

        $args += $ArchivePath
        $args += $Inputs

        Invoke-SevenZip -Exe $Exe -Arguments $args -WorkingDirectory $WorkingDirectory -Worker $Worker -DisplayName 'Bandizip' -TreatExitCodeOneAsWarning $false
        return
    }

    $args = @(
        'a',
        ('-t' + $Format),
        $ArchivePath
    )

    if ($ListFile) {
        $args += ('@' + $ListFile)
        $args += '-scsUTF-8'
    }
    else {
        $args += $Inputs
    }

    $args += @(
        ('-mx=' + $Level),
        '-y'
    )

    if (-not [string]::IsNullOrWhiteSpace($VolumeSpec)) {
        $args += ('-v' + $VolumeSpec)
    }

    if ($Password.Length -gt 0) {
        $args += ('-p' + $Password)
        if ($Format -eq '7z' -and $EncryptHeaders) {
            $args += '-mhe=on'
        }
    }

    Invoke-SevenZip -Exe $Exe -Arguments $args -WorkingDirectory $WorkingDirectory -Worker $Worker -DisplayName '7z' -TreatExitCodeOneAsWarning $true
}

function Invoke-CompressionJob {
    param(
        [pscustomobject]$Job,
        [AllowNull()]$Worker
    )

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $stageDir = Join-Path $Job.OutputDir ('.double-archive-work-' + $timestamp)
    [void](New-Item -ItemType Directory -Force -Path $stageDir)

    try {
        $toolPath = if ($Job.ToolPath) { $Job.ToolPath } else { $Job.SevenZip }
        Report-ProgressLine -Reporter $Worker -Line '准备输入清单...'
        $inputList = Join-Path $stageDir 'inputs.txt'
        Write-ListFile -Path $inputList -Lines $Job.Inputs

        if (-not $Job.DoubleCompressionEnabled) {
            $finalArchive = Join-Path $Job.OutputDir ($Job.BaseName + '.' + $Job.OuterFormat)
            if (Test-Path -LiteralPath $finalArchive -PathType Leaf) {
                if ($Job.Overwrite) {
                    Remove-Item -LiteralPath $finalArchive -Force
                }
                else {
                    throw ('压缩包已存在: {0}' -f $finalArchive)
                }
            }

            Report-ProgressLine -Reporter $Worker -Line '普通压缩模式: 正在生成单个压缩包，不创建分卷...'
            Invoke-ArchiveCreate `
                -Engine $Job.Engine `
                -Exe $toolPath `
                -ArchivePath $finalArchive `
                -Format $Job.OuterFormat `
                -Inputs @($Job.Inputs) `
                -WorkingDirectory $stageDir `
                -VolumeSpec '' `
                -Level $Job.Level `
                -Password $Job.Password `
                -EncryptHeaders $Job.EncryptHeaders `
                -Worker $Worker `
                -ListFile $inputList

            if (-not (Test-Path -LiteralPath $finalArchive -PathType Leaf)) {
                throw '普通压缩包生成失败。'
            }
            Report-ProgressLine -Reporter $Worker -Line ('完成: {0}' -f $finalArchive)
            return [pscustomobject]@{
                FinalArchive = $finalArchive
                VolumeCount = 0
                KeptDir = $null
                IsDoubleCompression = $false
            }
        }

        $innerBaseName = ('{0}.payload.{1}' -f $Job.BaseName, $Job.InnerFormat)
        $innerArchive = Join-Path $stageDir $innerBaseName
        $innerStem = [System.IO.Path]::GetFileNameWithoutExtension($innerBaseName)

        $fixedCountMode = ($Job.VolumeMode -eq '固定分卷数量')
        $firstStageMessage = if ($fixedCountMode) {
            '阶段 1/2: 正在生成完整加密压缩包，随后精确均分...'
        }
        else {
            '阶段 1/2: 正在生成带密码的分卷压缩包...'
        }
        Report-ProgressLine -Reporter $Worker -Line $firstStageMessage
        Invoke-ArchiveCreate `
            -Engine $Job.Engine `
            -Exe $toolPath `
            -ArchivePath $innerArchive `
            -Format $Job.InnerFormat `
            -Inputs @($Job.Inputs) `
            -WorkingDirectory $stageDir `
            -VolumeSpec $(if ($fixedCountMode) { '' } else { $Job.VolumeSpec }) `
            -Level $Job.Level `
            -Password $Job.Password `
            -EncryptHeaders $Job.EncryptHeaders `
            -Worker $Worker `
            -ListFile $inputList

        if ($fixedCountMode) {
            if (-not (Test-Path -LiteralPath $innerArchive -PathType Leaf)) {
                throw '没有找到第一阶段生成的完整压缩包。'
            }

            $archiveLength = (Get-Item -LiteralPath $innerArchive).Length
            Report-ProgressLine -Reporter $Worker -Line ('完整压缩包大小: {0:N0} 字节，正在均分为 {1} 个分卷...' -f $archiveLength, $Job.VolumeCount)
            $volumes = @(Split-FileEvenly -SourcePath $innerArchive -PartCount $Job.VolumeCount -Worker $Worker)
            Remove-Item -LiteralPath $innerArchive -Force
        }
        else {
            $volumes = @(Get-ChildItem -LiteralPath $stageDir -File |
                Where-Object {
                    $_.Name -eq $innerBaseName -or
                    $_.Name -like ($innerBaseName + '.*') -or
                    $_.Name -like ($innerStem + '.z[0-9][0-9]')
                } |
                Sort-Object Name)
        }

        if ($volumes.Count -eq 0 -and (Test-Path -LiteralPath $innerArchive -PathType Leaf)) {
            $volumes = @((Get-Item -LiteralPath $innerArchive))
        }

        if ($volumes.Count -eq 0) {
            throw '没有找到第一阶段生成的分卷文件。'
        }

        Report-ProgressLine -Reporter $Worker -Line ('第一阶段完成，分卷数: {0}' -f $volumes.Count)

        $volumeList = Join-Path $stageDir 'volumes.txt'
        Write-ListFile -Path $volumeList -Lines @($volumes | ForEach-Object { $_.Name })

        $finalArchive = Join-Path $Job.OutputDir ($Job.BaseName + '.' + $Job.OuterFormat)
        if (Test-Path -LiteralPath $finalArchive -PathType Leaf) {
            if ($Job.Overwrite) {
                Remove-Item -LiteralPath $finalArchive -Force
            }
            else {
                throw ('最终压缩包已存在: {0}' -f $finalArchive)
            }
        }

        Report-ProgressLine -Reporter $Worker -Line '阶段 2/2: 正在把分卷包再次压缩成最终压缩包...'
        Invoke-ArchiveCreate `
            -Engine $Job.Engine `
            -Exe $toolPath `
            -ArchivePath $finalArchive `
            -Format $Job.OuterFormat `
            -Inputs @($volumes | ForEach-Object { $_.Name }) `
            -WorkingDirectory $stageDir `
            -VolumeSpec '' `
            -Level $Job.Level `
            -Password $Job.Password `
            -EncryptHeaders $Job.EncryptHeaders `
            -Worker $Worker `
            -ListFile $volumeList

        $keptDir = $null
        if ($Job.KeepParts) {
            $keptDir = Join-Path $Job.OutputDir ($Job.BaseName + '_volumes_' + $timestamp)
            [void](New-Item -ItemType Directory -Force -Path $keptDir)
            foreach ($volume in $volumes) {
                Move-Item -LiteralPath $volume.FullName -Destination (Join-Path $keptDir $volume.Name) -Force
            }
            Report-ProgressLine -Reporter $Worker -Line ('已保留第一阶段分卷目录: {0}' -f $keptDir)
        }

        Report-ProgressLine -Reporter $Worker -Line ('完成: {0}' -f $finalArchive)
        return [pscustomobject]@{
            FinalArchive = $finalArchive
            VolumeCount = $volumes.Count
            KeptDir = $keptDir
            IsDoubleCompression = $true
        }
    }
    finally {
        if (Test-Path -LiteralPath $stageDir) {
            Remove-Item -LiteralPath $stageDir -Recurse -Force
        }
    }
}

function New-Label {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$W = 120,
        [int]$H = 22
    )

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($W, $H)
    $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    return $label
}

function New-Button {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$W = 88,
        [int]$H = 32
    )

    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object System.Drawing.Point($X, $Y)
    $button.Size = New-Object System.Drawing.Size($W, $H)
    return $button
}

function Add-LogLine {
    param(
        [System.Windows.Forms.TextBox]$TextBox,
        [string]$Line
    )

    $TextBox.AppendText(('[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $Line + [Environment]::NewLine))
}

function Refresh-InputList {
    param([System.Windows.Forms.ListBox]$ListBox)

    $ListBox.Items.Clear()
    foreach ($path in $script:InputPaths) {
        [void]$ListBox.Items.Add($path)
    }
}

function Add-InputPaths {
    param(
        [string[]]$Paths,
        [System.Windows.Forms.ListBox]$ListBox
    )

    foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }

        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }

        $fullPath = (Resolve-Path -LiteralPath $path).Path
        if (-not $script:InputPaths.Contains($fullPath)) {
            [void]$script:InputPaths.Add($fullPath)
        }
    }

    Refresh-InputList -ListBox $ListBox
}

function Add-PresetValue {
    param(
        [System.Windows.Forms.ComboBox]$ComboBox,
        [string]$Value,
        [bool]$CaseSensitive = $true
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return -1
    }

    for ($index = 0; $index -lt $ComboBox.Items.Count; $index += 1) {
        $existing = [string]$ComboBox.Items[$index]
        $comparison = if ($CaseSensitive) {
            [string]::Equals($existing, $Value, [System.StringComparison]::Ordinal)
        }
        else {
            [string]::Equals($existing, $Value, [System.StringComparison]::OrdinalIgnoreCase)
        }

        if ($comparison) {
            return $index
        }
    }

    return $ComboBox.Items.Add($Value)
}

function Get-PresetValues {
    param([System.Windows.Forms.ComboBox]$ComboBox)

    return @($ComboBox.Items | ForEach-Object { [string]$_ })
}

function Update-HeaderEncryptAvailability {
    $usesSevenZipFormat = if ($doubleCompressionCheck.Checked) {
        ($innerFormat.SelectedItem -eq '7z') -or ($outerFormat.SelectedItem -eq '7z')
    }
    else {
        $outerFormat.SelectedItem -eq '7z'
    }
    $headerEncryptCheck.Enabled = (($engineBox.SelectedItem -eq '7-Zip') -and $usesSevenZipFormat)
}

function Update-VolumeModeAvailability {
    $doubleEnabled = [bool]$doubleCompressionCheck.Checked
    $fixedCount = $doubleEnabled -and ($volumeModeBox.SelectedItem -eq '固定分卷数量')
    $volumeModeLabel.Enabled = $doubleEnabled
    $volumeModeBox.Enabled = $doubleEnabled
    $innerLabel.Enabled = $doubleEnabled
    $innerFormat.Enabled = $doubleEnabled
    $keepPartsCheck.Enabled = $doubleEnabled
    $separateOutputsCheck.Enabled = $true
    $outerLabel.Text = if ($doubleEnabled) { '最终格式' } else { '压缩格式' }
    $volumeSize.Enabled = $doubleEnabled -and -not $fixedCount
    $volumeUnit.Enabled = $doubleEnabled -and -not $fixedCount
    $volumeCount.Enabled = $fixedCount
    $volumeSizeLabel.Visible = $doubleEnabled -and -not $fixedCount
    $volumeSize.Visible = $doubleEnabled -and -not $fixedCount
    $volumeUnit.Visible = $doubleEnabled -and -not $fixedCount
    $volumeCountLabel.Visible = $fixedCount
    $volumeCount.Visible = $fixedCount
    $volumeCountSuffix.Visible = $fixedCount
    $singleModeLabel.Visible = -not $doubleEnabled
    Update-HeaderEncryptAvailability
}

function Update-NamePresetAvailability {
    $enabled = -not $separateOutputsCheck.Checked
    $baseText.Enabled = $enabled
    $saveNameButton.Enabled = $enabled
    $deleteNameButton.Enabled = $enabled
}

function Update-CompressionProfileControls {
    param([int]$SelectedIndex = -1)

    if ($null -eq $profileBox) {
        return
    }

    $script:IsLoadingSettings = $true
    try {
        $profileBox.Items.Clear()
        [void]$profileBox.Items.Add('＋ 新建预设')
        foreach ($profile in @($script:CompressionProfiles)) {
            [void]$profileBox.Items.Add([string]$profile.Name)
        }
        if ($SelectedIndex -ge 0 -and $SelectedIndex -lt $script:CompressionProfiles.Count) {
            $profileBox.SelectedIndex = $SelectedIndex + 1
        }
        else {
            $profileBox.SelectedIndex = 0
        }
    }
    finally {
        $script:IsLoadingSettings = $false
    }

    $hasProfile = ($profileBox.SelectedIndex -gt 0)
    $deleteProfileButton.Enabled = $hasProfile
    $note = if ($hasProfile) { [string]$script:CompressionProfiles[$profileBox.SelectedIndex - 1].Note } else { '' }
    $toolTip.SetToolTip($profileBox, $note)
}

function Get-CurrentCompressionProfile {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowEmptyString()][string]$Note = ''
    )

    $protectedPassword = ''
    if (-not [string]::IsNullOrEmpty($passwordText.Text)) {
        $protectedPassword = Protect-Password -Password $passwordText.Text
    }

    return [pscustomobject][ordered]@{
        Name = $Name.Trim()
        Note = $Note.Trim()
        Engine = [string]$engineBox.SelectedItem
        ToolPath = ([string]$sevenZipText.Text).Trim()
        OutputDir = ([string]$outputText.Text).Trim()
        BaseName = ([string]$baseText.Text).Trim()
        DoubleCompressionEnabled = [bool]$doubleCompressionCheck.Checked
        InnerFormat = [string]$innerFormat.SelectedItem
        OuterFormat = [string]$outerFormat.SelectedItem
        SeparateOutputs = [bool]$separateOutputsCheck.Checked
        VolumeMode = [string]$volumeModeBox.SelectedItem
        VolumeSize = [int]$volumeSize.Value
        VolumeUnit = [string]$volumeUnit.SelectedItem
        VolumeCount = [int]$volumeCount.Value
        LevelText = [string]$levelBox.SelectedItem
        Overwrite = [bool]$overwriteCheck.Checked
        KeepParts = [bool]$keepPartsCheck.Checked
        EncryptHeaders = [bool]$headerEncryptCheck.Checked
        PasswordProtected = $protectedPassword
        UpdatedAt = [DateTime]::UtcNow.ToString('o')
    }
}

function Apply-CompressionProfile {
    param([Parameter(Mandatory = $true)]$Profile)

    $script:IsLoadingSettings = $true
    try {
        Set-ComboSelection -ComboBox $engineBox -Value ([string]$Profile.Engine)
        if (-not [string]::IsNullOrWhiteSpace([string]$Profile.ToolPath)) {
            $sevenZipText.Text = [string]$Profile.ToolPath
        }
        else {
            $sevenZipText.Text = Find-CompressionTool -Engine ([string]$engineBox.SelectedItem)
        }

        $outputText.Text = [string]$Profile.OutputDir
        $profileBaseName = [string]$Profile.BaseName
        if (-not [string]::IsNullOrWhiteSpace($profileBaseName)) {
            [void](Add-PresetValue -ComboBox $baseText -Value $profileBaseName -CaseSensitive $false)
        }
        $baseText.Text = $profileBaseName

        $doubleProperty = $Profile.PSObject.Properties['DoubleCompressionEnabled']
        $doubleCompressionCheck.Checked = if ($null -eq $doubleProperty) { $true } else { [bool]$Profile.DoubleCompressionEnabled }

        Set-ComboSelection -ComboBox $innerFormat -Value ([string]$Profile.InnerFormat)
        Set-ComboSelection -ComboBox $outerFormat -Value ([string]$Profile.OuterFormat)
        Set-ComboSelection -ComboBox $volumeModeBox -Value ([string]$Profile.VolumeMode)
        Set-NumericValue -Control $volumeSize -Value $Profile.VolumeSize
        Set-ComboSelection -ComboBox $volumeUnit -Value ([string]$Profile.VolumeUnit)
        Set-NumericValue -Control $volumeCount -Value $Profile.VolumeCount
        Set-ComboSelection -ComboBox $levelBox -Value ([string]$Profile.LevelText)

        $separateOutputsCheck.Checked = [bool]$Profile.SeparateOutputs
        $overwriteCheck.Checked = [bool]$Profile.Overwrite
        $keepPartsCheck.Checked = [bool]$Profile.KeepParts
        $headerEncryptCheck.Checked = [bool]$Profile.EncryptHeaders

        $restoredPassword = ''
        if (-not [string]::IsNullOrWhiteSpace([string]$Profile.PasswordProtected)) {
            $restoredPassword = Unprotect-Password -ProtectedPassword ([string]$Profile.PasswordProtected)
        }
        if (-not [string]::IsNullOrEmpty($restoredPassword)) {
            $passwordIndex = Add-PresetValue -ComboBox $passwordText -Value $restoredPassword -CaseSensitive $true
            $passwordText.SelectedIndex = $passwordIndex
        }
        $passwordText.Text = $restoredPassword
        $confirmText.Text = $restoredPassword
    }
    finally {
        $script:IsLoadingSettings = $false
        Update-HeaderEncryptAvailability
        Update-VolumeModeAvailability
        Update-NamePresetAvailability
    }

    Save-CurrentSettings
}

function Read-CompressionProfileDetails {
    param(
        [AllowEmptyString()][string]$DefaultName = '',
        [AllowEmptyString()][string]$DefaultNote = ''
    )

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = '保存当前配置'
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ClientSize = New-Object System.Drawing.Size(520, 230)
    $dialog.Font = $form.Font
    if ($form.Icon) { $dialog.Icon = $form.Icon }

    $nameLabel = New-Label -Text '预设名称' -X 18 -Y 20 -W 88
    $dialog.Controls.Add($nameLabel)
    $nameInput = New-Object System.Windows.Forms.TextBox
    $nameInput.Name = 'CompressionProfileName'
    $nameInput.Location = New-Object System.Drawing.Point(108, 18)
    $nameInput.Size = New-Object System.Drawing.Size(390, 26)
    $nameInput.Text = $DefaultName
    $dialog.Controls.Add($nameInput)

    $noteLabel = New-Label -Text '备注' -X 18 -Y 62 -W 88
    $dialog.Controls.Add($noteLabel)
    $noteInput = New-Object System.Windows.Forms.TextBox
    $noteInput.Name = 'CompressionProfileNote'
    $noteInput.Location = New-Object System.Drawing.Point(108, 60)
    $noteInput.Size = New-Object System.Drawing.Size(390, 105)
    $noteInput.Multiline = $true
    $noteInput.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $noteInput.Text = $DefaultNote
    $dialog.Controls.Add($noteInput)

    $okButton = New-Button -Text '保存' -X 326 -Y 184 -W 82 -H 32
    $okButton.Name = 'ConfirmCompressionProfileSave'
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dialog.Controls.Add($okButton)
    $cancelDialogButton = New-Button -Text '取消' -X 416 -Y 184 -W 82 -H 32
    $cancelDialogButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($cancelDialogButton)
    $dialog.AcceptButton = $okButton
    $dialog.CancelButton = $cancelDialogButton

    $result = $null
    if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $name = $nameInput.Text.Trim()
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $result = [pscustomobject]@{ Name = $name; Note = $noteInput.Text.Trim() }
        }
    }
    $dialog.Dispose()
    return $result
}

function Apply-SavedSettings {
    param($Settings)

    if ($null -eq $Settings) {
        return
    }

    $script:IsLoadingSettings = $true
    try {
        Set-ComboSelection -ComboBox $engineBox -Value $Settings.Engine

        if (-not [string]::IsNullOrWhiteSpace($Settings.ToolPath)) {
            $sevenZipText.Text = [string]$Settings.ToolPath
        }
        else {
            $sevenZipText.Text = Find-CompressionTool -Engine ([string]$engineBox.SelectedItem)
        }

        if (-not [string]::IsNullOrWhiteSpace($Settings.OutputDir)) {
            $outputText.Text = [string]$Settings.OutputDir
        }
        $baseText.Items.Clear()
        $namePresetsProperty = $Settings.PSObject.Properties['NamePresets']
        if ($null -ne $namePresetsProperty) {
            foreach ($savedName in @($Settings.NamePresets)) {
                [void](Add-PresetValue -ComboBox $baseText -Value ([string]$savedName) -CaseSensitive $false)
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($Settings.BaseName)) {
            $savedBaseName = [string]$Settings.BaseName
            if ($null -eq $namePresetsProperty) {
                [void](Add-PresetValue -ComboBox $baseText -Value $savedBaseName -CaseSensitive $false)
            }
            $baseText.Text = $savedBaseName
        }

        Set-ComboSelection -ComboBox $innerFormat -Value $Settings.InnerFormat
        Set-ComboSelection -ComboBox $outerFormat -Value $Settings.OuterFormat
        $doubleProperty = $Settings.PSObject.Properties['DoubleCompressionEnabled']
        $doubleCompressionCheck.Checked = if ($null -eq $doubleProperty) { $true } else { [bool]$Settings.DoubleCompressionEnabled }
        Set-ComboSelection -ComboBox $volumeModeBox -Value $Settings.VolumeMode
        Set-NumericValue -Control $volumeSize -Value $Settings.VolumeSize
        Set-ComboSelection -ComboBox $volumeUnit -Value $Settings.VolumeUnit
        Set-NumericValue -Control $volumeCount -Value $Settings.VolumeCount
        Set-ComboSelection -ComboBox $levelBox -Value $Settings.LevelText

        if ($null -ne $Settings.Overwrite) {
            $overwriteCheck.Checked = [bool]$Settings.Overwrite
        }
        if ($null -ne $Settings.KeepParts) {
            $keepPartsCheck.Checked = [bool]$Settings.KeepParts
        }
        if ($null -ne $Settings.SeparateOutputs) {
            $separateOutputsCheck.Checked = [bool]$Settings.SeparateOutputs
        }
        if ($null -ne $Settings.EncryptHeaders) {
            $headerEncryptCheck.Checked = [bool]$Settings.EncryptHeaders
        }
        $passwordText.Items.Clear()
        foreach ($protectedPreset in @($Settings.ProtectedPasswordPresets)) {
            $restoredPreset = Unprotect-Password -ProtectedPassword ([string]$protectedPreset)
            if (-not [string]::IsNullOrEmpty($restoredPreset)) {
                [void](Add-PresetValue -ComboBox $passwordText -Value $restoredPreset -CaseSensitive $true)
            }
        }

        $restoredPassword = ''
        if (-not [string]::IsNullOrWhiteSpace($Settings.SelectedPasswordProtected)) {
            $restoredPassword = Unprotect-Password -ProtectedPassword ([string]$Settings.SelectedPasswordProtected)
        }
        elseif ($Settings.RememberPassword -and -not [string]::IsNullOrWhiteSpace($Settings.ProtectedPassword)) {
            $restoredPassword = Unprotect-Password -ProtectedPassword ([string]$Settings.ProtectedPassword)
        }

        if (-not [string]::IsNullOrEmpty($restoredPassword)) {
            $presetIndex = Add-PresetValue -ComboBox $passwordText -Value $restoredPassword -CaseSensitive $true
            $passwordText.SelectedIndex = $presetIndex
            $passwordText.Text = $restoredPassword
            $confirmText.Text = $restoredPassword
        }
        else {
            $passwordText.Text = ''
            $confirmText.Clear()
        }

        $script:CompressionProfiles.Clear()
        $profilesProperty = $Settings.PSObject.Properties['CompressionProfiles']
        if ($null -ne $profilesProperty) {
            foreach ($profile in @($Settings.CompressionProfiles)) {
                if ($null -ne $profile -and -not [string]::IsNullOrWhiteSpace([string]$profile.Name)) {
                    [void]$script:CompressionProfiles.Add($profile)
                }
            }
        }
    }
    finally {
        $script:IsLoadingSettings = $false
        Update-HeaderEncryptAvailability
        Update-VolumeModeAvailability
        Update-NamePresetAvailability
        Update-CompressionProfileControls
    }
}

function Save-CurrentSettings {
    $protectedPasswordPresets = @()
    $selectedPasswordProtected = ''
    foreach ($preset in @(Get-PresetValues -ComboBox $passwordText)) {
        $protected = Protect-Password -Password $preset
        if (-not [string]::IsNullOrWhiteSpace($protected)) {
            $protectedPasswordPresets += $protected
        }
        if ([string]::Equals($preset, $passwordText.Text, [System.StringComparison]::Ordinal)) {
            $selectedPasswordProtected = $protected
        }
    }

    $settings = [pscustomobject][ordered]@{
        Version = 4
        Engine = [string]$engineBox.SelectedItem
        ToolPath = ([string]$sevenZipText.Text).Trim()
        OutputDir = ([string]$outputText.Text).Trim()
        BaseName = ([string]$baseText.Text).Trim()
        NamePresets = [string[]]@(Get-PresetValues -ComboBox $baseText)
        DoubleCompressionEnabled = [bool]$doubleCompressionCheck.Checked
        InnerFormat = [string]$innerFormat.SelectedItem
        OuterFormat = [string]$outerFormat.SelectedItem
        VolumeMode = [string]$volumeModeBox.SelectedItem
        VolumeSize = [int]$volumeSize.Value
        VolumeUnit = [string]$volumeUnit.SelectedItem
        VolumeCount = [int]$volumeCount.Value
        LevelText = [string]$levelBox.SelectedItem
        Overwrite = [bool]$overwriteCheck.Checked
        KeepParts = [bool]$keepPartsCheck.Checked
        SeparateOutputs = [bool]$separateOutputsCheck.Checked
        EncryptHeaders = [bool]$headerEncryptCheck.Checked
        ProtectedPasswordPresets = [string[]]$protectedPasswordPresets
        SelectedPasswordProtected = $selectedPasswordProtected
        CompressionProfiles = @($script:CompressionProfiles | ForEach-Object { $_ })
    }

    Save-AppSettings -Settings $settings
}

$script:SavedSettings = Load-AppSettings

$form = New-Object System.Windows.Forms.Form
$form.Text = '双层分卷压缩器'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(860, 780)
$form.MinimumSize = New-Object System.Drawing.Size(860, 720)
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$appIconPath = @(
    (Join-Path $script:AppDir 'AppIcon.ico'),
    (Join-Path $script:AppDir 'Assets\AppIcon.ico')
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if ($appIconPath) {
    $form.Icon = New-Object System.Drawing.Icon($appIconPath)
}
$toolTip = New-Object System.Windows.Forms.ToolTip

$title = New-Object System.Windows.Forms.Label
$title.Text = '双层分卷压缩器'
$title.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 18, [System.Drawing.FontStyle]::Bold)
$title.Location = New-Object System.Drawing.Point(20, 16)
$title.Size = New-Object System.Drawing.Size(320, 36)
$form.Controls.Add($title)

$versionLabel = New-Object System.Windows.Forms.Label
$versionLabel.Text = "v$($script:AppVersion)"
$versionLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$versionLabel.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
$versionLabel.Location = New-Object System.Drawing.Point(684, 20)
$versionLabel.Size = New-Object System.Drawing.Size(126, 28)
$versionLabel.Anchor = 'Top,Right'
$form.Controls.Add($versionLabel)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = '拖入文件或文件夹，先分卷压缩，再把分卷包合成一个带同一密码的最终压缩包。'
$subtitle.Location = New-Object System.Drawing.Point(22, 54)
$subtitle.Size = New-Object System.Drawing.Size(440, 24)
$form.Controls.Add($subtitle)

$profileBox = New-Object System.Windows.Forms.ComboBox
$profileBox.Name = 'CompressionProfileSelector'
$profileBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$profileBox.Location = New-Object System.Drawing.Point(470, 51)
$profileBox.Size = New-Object System.Drawing.Size(180, 26)
$profileBox.Anchor = 'Top,Right'
$toolTip.SetToolTip($profileBox, '选择后立即切换整套方案；悬停可查看备注')
$form.Controls.Add($profileBox)

$saveProfileButton = New-Button -Text '保存' -X 656 -Y 48 -W 50 -H 30
$saveProfileButton.Anchor = 'Top,Right'
$toolTip.SetToolTip($saveProfileButton, '把当前全部压缩配置保存为预设')
$form.Controls.Add($saveProfileButton)

$deleteProfileButton = New-Button -Text '删除' -X 710 -Y 48 -W 50 -H 30
$deleteProfileButton.Anchor = 'Top,Right'
$deleteProfileButton.Enabled = $false
$form.Controls.Add($deleteProfileButton)

$engineLabel = New-Label -Text '压缩核心' -X 22 -Y 92 -W 84
$form.Controls.Add($engineLabel)

$engineBox = New-Object System.Windows.Forms.ComboBox
$engineBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$engineBox.Location = New-Object System.Drawing.Point(112, 91)
$engineBox.Size = New-Object System.Drawing.Size(128, 26)
[void]$engineBox.Items.Add('7-Zip')
[void]$engineBox.Items.Add('Bandizip')
$bandizipPath = Find-Bandizip
$sevenZipPath = Find-SevenZip
$engineBox.SelectedItem = if ($bandizipPath) { 'Bandizip' } else { '7-Zip' }
$form.Controls.Add($engineBox)

$sevenZipLabel = New-Label -Text '工具路径' -X 258 -Y 92 -W 74
$form.Controls.Add($sevenZipLabel)

$sevenZipText = New-Object System.Windows.Forms.TextBox
$sevenZipText.Location = New-Object System.Drawing.Point(334, 91)
$sevenZipText.Size = New-Object System.Drawing.Size(368, 26)
$sevenZipText.Anchor = 'Top,Left,Right'
$sevenZipText.Text = if ($engineBox.SelectedItem -eq 'Bandizip') { $bandizipPath } else { $sevenZipPath }
$form.Controls.Add($sevenZipText)

$browseSevenZipButton = New-Button -Text '选择' -X 716 -Y 88 -W 94
$browseSevenZipButton.Anchor = 'Top,Right'
$form.Controls.Add($browseSevenZipButton)

$dropPanel = New-Object System.Windows.Forms.Panel
$dropPanel.Location = New-Object System.Drawing.Point(22, 130)
$dropPanel.Size = New-Object System.Drawing.Size(788, 180)
$dropPanel.Anchor = 'Top,Left,Right'
$dropPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$dropPanel.AllowDrop = $true
$dropPanel.BackColor = [System.Drawing.Color]::FromArgb(248, 250, 252)
$form.Controls.Add($dropPanel)

$dropHint = New-Object System.Windows.Forms.Label
$dropHint.Text = '把要压缩的文件或文件夹拖到这里'
$dropHint.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 12, [System.Drawing.FontStyle]::Bold)
$dropHint.Location = New-Object System.Drawing.Point(16, 12)
$dropHint.Size = New-Object System.Drawing.Size(520, 28)
$dropPanel.Controls.Add($dropHint)

$inputList = New-Object System.Windows.Forms.ListBox
$inputList.Location = New-Object System.Drawing.Point(18, 48)
$inputList.Size = New-Object System.Drawing.Size(748, 112)
$inputList.Anchor = 'Top,Left,Right'
$inputList.HorizontalScrollbar = $true
$dropPanel.Controls.Add($inputList)

$addFilesButton = New-Button -Text '添加文件' -X 22 -Y 324 -W 100
$form.Controls.Add($addFilesButton)

$addFolderButton = New-Button -Text '添加文件夹' -X 132 -Y 324 -W 112
$form.Controls.Add($addFolderButton)

$removeButton = New-Button -Text '移除选中' -X 254 -Y 324 -W 112
$form.Controls.Add($removeButton)

$clearButton = New-Button -Text '清空' -X 376 -Y 324 -W 82
$form.Controls.Add($clearButton)

$outputLabel = New-Label -Text '输出目录' -X 22 -Y 374 -W 84
$form.Controls.Add($outputLabel)

$outputText = New-Object System.Windows.Forms.TextBox
$outputText.Location = New-Object System.Drawing.Point(112, 373)
$outputText.Size = New-Object System.Drawing.Size(590, 26)
$outputText.Anchor = 'Top,Left,Right'
$desktop = [Environment]::GetFolderPath('Desktop')
$outputText.Text = if ($desktop) { $desktop } else { $script:AppDir }
$form.Controls.Add($outputText)

$browseOutputButton = New-Button -Text '选择' -X 716 -Y 370 -W 94
$browseOutputButton.Anchor = 'Top,Right'
$form.Controls.Add($browseOutputButton)

$baseLabel = New-Label -Text '压缩包名称' -X 22 -Y 412 -W 84
$form.Controls.Add($baseLabel)

$baseText = New-Object System.Windows.Forms.ComboBox
$baseText.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
$baseText.Location = New-Object System.Drawing.Point(112, 411)
$baseText.Size = New-Object System.Drawing.Size(210, 26)
$baseText.Text = 'double-archive-' + (Get-Date -Format 'yyyyMMdd-HHmm')
$form.Controls.Add($baseText)

$saveNameButton = New-Button -Text '保存' -X 328 -Y 408 -W 58 -H 30
$toolTip.SetToolTip($saveNameButton, '保存当前压缩包名称到下拉预设')
$form.Controls.Add($saveNameButton)

$deleteNameButton = New-Button -Text '删除' -X 392 -Y 408 -W 58 -H 30
$toolTip.SetToolTip($deleteNameButton, '删除当前选中的名称预设')
$form.Controls.Add($deleteNameButton)

$innerLabel = New-Label -Text '分卷格式' -X 466 -Y 412 -W 68
$form.Controls.Add($innerLabel)

$innerFormat = New-Object System.Windows.Forms.ComboBox
$innerFormat.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$innerFormat.Location = New-Object System.Drawing.Point(536, 411)
$innerFormat.Size = New-Object System.Drawing.Size(66, 26)
[void]$innerFormat.Items.Add('7z')
[void]$innerFormat.Items.Add('zip')
$innerFormat.SelectedItem = '7z'
$form.Controls.Add($innerFormat)

$outerLabel = New-Label -Text '最终格式' -X 616 -Y 412 -W 66
$form.Controls.Add($outerLabel)

$outerFormat = New-Object System.Windows.Forms.ComboBox
$outerFormat.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$outerFormat.Location = New-Object System.Drawing.Point(684, 411)
$outerFormat.Size = New-Object System.Drawing.Size(66, 26)
[void]$outerFormat.Items.Add('7z')
[void]$outerFormat.Items.Add('zip')
$outerFormat.SelectedItem = '7z'
$form.Controls.Add($outerFormat)

$separateOutputsCheck = New-Object System.Windows.Forms.CheckBox
$separateOutputsCheck.Text = '单独压缩'
$separateOutputsCheck.Location = New-Object System.Drawing.Point(756, 411)
$separateOutputsCheck.Size = New-Object System.Drawing.Size(88, 26)
$form.Controls.Add($separateOutputsCheck)

$volumeModeLabel = New-Label -Text '分卷模式' -X 22 -Y 450 -W 84
$form.Controls.Add($volumeModeLabel)

$volumeModeBox = New-Object System.Windows.Forms.ComboBox
$volumeModeBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$volumeModeBox.Location = New-Object System.Drawing.Point(112, 449)
$volumeModeBox.Size = New-Object System.Drawing.Size(130, 26)
[void]$volumeModeBox.Items.Add('按分卷大小')
[void]$volumeModeBox.Items.Add('固定分卷数量')
$volumeModeBox.SelectedItem = '按分卷大小'
$form.Controls.Add($volumeModeBox)

$volumeSizeLabel = New-Label -Text '每卷大小' -X 258 -Y 450 -W 70
$form.Controls.Add($volumeSizeLabel)

$volumeSize = New-Object System.Windows.Forms.NumericUpDown
$volumeSize.Location = New-Object System.Drawing.Point(330, 449)
$volumeSize.Size = New-Object System.Drawing.Size(90, 26)
$volumeSize.Minimum = 1
$volumeSize.Maximum = 1048576
$volumeSize.Value = 500
$form.Controls.Add($volumeSize)

$volumeUnit = New-Object System.Windows.Forms.ComboBox
$volumeUnit.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$volumeUnit.Location = New-Object System.Drawing.Point(426, 449)
$volumeUnit.Size = New-Object System.Drawing.Size(70, 26)
[void]$volumeUnit.Items.Add('MB')
[void]$volumeUnit.Items.Add('GB')
$volumeUnit.SelectedItem = 'MB'
$form.Controls.Add($volumeUnit)

$volumeCountLabel = New-Label -Text '分卷数量' -X 258 -Y 450 -W 70
$volumeCountLabel.Visible = $false
$form.Controls.Add($volumeCountLabel)

$volumeCount = New-Object System.Windows.Forms.NumericUpDown
$volumeCount.Location = New-Object System.Drawing.Point(330, 449)
$volumeCount.Size = New-Object System.Drawing.Size(90, 26)
$volumeCount.Minimum = 2
$volumeCount.Maximum = 999
$volumeCount.Value = 5
$volumeCount.Visible = $false
$form.Controls.Add($volumeCount)

$volumeCountSuffix = New-Label -Text '个' -X 426 -Y 450 -W 40
$volumeCountSuffix.Visible = $false
$form.Controls.Add($volumeCountSuffix)

$singleModeLabel = New-Label -Text '普通压缩：生成单个压缩包，不分卷' -X 258 -Y 450 -W 250
$singleModeLabel.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
$singleModeLabel.Visible = $false
$form.Controls.Add($singleModeLabel)

$levelLabel = New-Label -Text '压缩等级' -X 520 -Y 450 -W 72
$form.Controls.Add($levelLabel)

$levelBox = New-Object System.Windows.Forms.ComboBox
$levelBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$levelBox.Location = New-Object System.Drawing.Point(594, 449)
$levelBox.Size = New-Object System.Drawing.Size(140, 26)
@('0 - 仅打包', '1 - 最快', '5 - 标准', '7 - 高', '9 - 极限') | ForEach-Object { [void]$levelBox.Items.Add($_) }
$levelBox.SelectedItem = '5 - 标准'
$form.Controls.Add($levelBox)

$overwriteCheck = New-Object System.Windows.Forms.CheckBox
$overwriteCheck.Text = '覆盖同名最终包'
$overwriteCheck.Location = New-Object System.Drawing.Point(22, 487)
$overwriteCheck.Size = New-Object System.Drawing.Size(132, 26)
$form.Controls.Add($overwriteCheck)

$keepPartsCheck = New-Object System.Windows.Forms.CheckBox
$keepPartsCheck.Text = '保留第一阶段分卷'
$keepPartsCheck.Location = New-Object System.Drawing.Point(170, 487)
$keepPartsCheck.Size = New-Object System.Drawing.Size(150, 26)
$form.Controls.Add($keepPartsCheck)

$headerEncryptCheck = New-Object System.Windows.Forms.CheckBox
$headerEncryptCheck.Text = '7z文件名加密'
$headerEncryptCheck.Location = New-Object System.Drawing.Point(336, 487)
$headerEncryptCheck.Size = New-Object System.Drawing.Size(120, 26)
$headerEncryptCheck.Checked = $true
$headerEncryptCheck.Enabled = ($engineBox.SelectedItem -eq '7-Zip')
$form.Controls.Add($headerEncryptCheck)

$doubleCompressionCheck = New-Object System.Windows.Forms.CheckBox
$doubleCompressionCheck.Text = '启用双重分卷压缩'
$doubleCompressionCheck.Location = New-Object System.Drawing.Point(472, 487)
$doubleCompressionCheck.Size = New-Object System.Drawing.Size(166, 26)
$doubleCompressionCheck.Checked = $true
$toolTip.SetToolTip($doubleCompressionCheck, '关闭后按普通压缩方式输出；可继续使用“单独压缩”，但不创建分卷')
$form.Controls.Add($doubleCompressionCheck)

$passwordLabel = New-Label -Text '统一密码' -X 22 -Y 526 -W 84
$form.Controls.Add($passwordLabel)

$passwordText = New-Object System.Windows.Forms.ComboBox
$passwordText.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
$passwordText.Location = New-Object System.Drawing.Point(112, 525)
$passwordText.Size = New-Object System.Drawing.Size(250, 26)
$form.Controls.Add($passwordText)

$savePasswordButton = New-Button -Text '保存' -X 370 -Y 522 -W 70 -H 30
$toolTip.SetToolTip($savePasswordButton, '加密保存当前密码到下拉预设')
$form.Controls.Add($savePasswordButton)

$deletePasswordButton = New-Button -Text '删除' -X 448 -Y 522 -W 70 -H 30
$toolTip.SetToolTip($deletePasswordButton, '删除当前选中的密码预设')
$form.Controls.Add($deletePasswordButton)

$confirmLabel = New-Label -Text '确认密码' -X 536 -Y 526 -W 72
$form.Controls.Add($confirmLabel)

$confirmText = New-Object System.Windows.Forms.TextBox
$confirmText.Location = New-Object System.Drawing.Point(610, 525)
$confirmText.Size = New-Object System.Drawing.Size(200, 26)
$form.Controls.Add($confirmText)

$startButton = New-Button -Text '开始压缩' -X 22 -Y 568 -W 112 -H 36
$form.Controls.Add($startButton)

$cancelButton = New-Button -Text '取消' -X 144 -Y 568 -W 92 -H 36
$cancelButton.Enabled = $false
$form.Controls.Add($cancelButton)

$updateButton = New-Button -Text '检查更新' -X 246 -Y 568 -W 104 -H 36
$toolTip.SetToolTip($updateButton, '检查 GitHub Release，下载并启动最新 Setup 安装包')
$form.Controls.Add($updateButton)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = '就绪'
$statusLabel.Location = New-Object System.Drawing.Point(362, 575)
$statusLabel.Size = New-Object System.Drawing.Size(130, 24)
$form.Controls.Add($statusLabel)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point(502, 575)
$progress.Size = New-Object System.Drawing.Size(308, 22)
$progress.Anchor = 'Top,Left,Right'
$progress.Style = [System.Windows.Forms.ProgressBarStyle]::Blocks
$form.Controls.Add($progress)

$logText = New-Object System.Windows.Forms.TextBox
$logText.Location = New-Object System.Drawing.Point(22, 618)
$logText.Size = New-Object System.Drawing.Size(788, 104)
$logText.Anchor = 'Top,Bottom,Left,Right'
$logText.Multiline = $true
$logText.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$logText.ReadOnly = $true
$logText.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($logText)

Apply-SavedSettings -Settings $script:SavedSettings
if ($script:StartupInputPaths.Count -gt 0) {
    Add-InputPaths -Paths $script:StartupInputPaths -ListBox $inputList
}
Refresh-InputList -ListBox $inputList

$dropPanel.Add_DragEnter({
    if ($_.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        $_.Effect = [System.Windows.Forms.DragDropEffects]::Copy
    }
})

$dropPanel.Add_DragDrop({
    $paths = [string[]]$_.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
    Add-InputPaths -Paths $paths -ListBox $inputList
})

$inputList.Add_DragEnter({
    if ($_.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        $_.Effect = [System.Windows.Forms.DragDropEffects]::Copy
    }
})

$inputList.Add_DragDrop({
    $paths = [string[]]$_.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
    Add-InputPaths -Paths $paths -ListBox $inputList
})

$inputList.AllowDrop = $true

$engineBox.Add_SelectedIndexChanged({
    if ($script:IsLoadingSettings) {
        return
    }

    $engine = [string]$engineBox.SelectedItem
    $detected = Find-CompressionTool -Engine $engine
    $sevenZipText.Text = $detected
    Update-HeaderEncryptAvailability
})

$browseSevenZipButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    if ($engineBox.SelectedItem -eq 'Bandizip') {
        $dialog.Filter = 'Bandizip 命令行|bz.exe;Bandizip.exe|可执行文件|*.exe|所有文件|*.*'
        $dialog.Title = '选择 bz.exe 或 Bandizip.exe'
    }
    else {
        $dialog.Filter = '7z.exe|7z.exe|可执行文件|*.exe|所有文件|*.*'
        $dialog.Title = '选择 7z.exe'
    }
    if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $sevenZipText.Text = $dialog.FileName
    }
    $dialog.Dispose()
})

$addFilesButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Multiselect = $true
    $dialog.Filter = '所有文件|*.*'
    if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        Add-InputPaths -Paths $dialog.FileNames -ListBox $inputList
    }
    $dialog.Dispose()
})

$addFolderButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = '选择要压缩的文件夹'
    if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        Add-InputPaths -Paths @($dialog.SelectedPath) -ListBox $inputList
    }
    $dialog.Dispose()
})

$removeButton.Add_Click({
    $selected = @($inputList.SelectedItems | ForEach-Object { [string]$_ })
    foreach ($item in $selected) {
        [void]$script:InputPaths.Remove($item)
    }
    Refresh-InputList -ListBox $inputList
})

$clearButton.Add_Click({
    $script:InputPaths.Clear()
    Refresh-InputList -ListBox $inputList
})

$browseOutputButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = '选择最终压缩包输出目录'
    $dialog.SelectedPath = $outputText.Text
    if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $outputText.Text = $dialog.SelectedPath
    }
    $dialog.Dispose()
})

$profileBox.Add_SelectedIndexChanged({
    if ($script:IsLoadingSettings) { return }
    $index = $profileBox.SelectedIndex - 1
    $hasProfile = ($index -ge 0 -and $index -lt $script:CompressionProfiles.Count)
    $deleteProfileButton.Enabled = $hasProfile
    $note = if ($hasProfile) { [string]$script:CompressionProfiles[$index].Note } else { '' }
    $toolTip.SetToolTip($profileBox, $note)
    if ($hasProfile) {
        $profileName = [string]$script:CompressionProfiles[$index].Name
        Apply-CompressionProfile -Profile $script:CompressionProfiles[$index]
        Add-LogLine -TextBox $logText -Line "已切换方案预设: $profileName"
    }
})

$saveProfileButton.Add_Click({
    $selectedIndex = $profileBox.SelectedIndex - 1
    $defaultName = if ($selectedIndex -ge 0) { [string]$script:CompressionProfiles[$selectedIndex].Name } else { '方案-' + (Get-Date -Format 'yyyyMMdd-HHmm') }
    $defaultNote = if ($selectedIndex -ge 0) { [string]$script:CompressionProfiles[$selectedIndex].Note } else { '' }
    $details = Read-CompressionProfileDetails -DefaultName $defaultName -DefaultNote $defaultNote
    if ($null -eq $details) { return }

    $targetIndex = $selectedIndex
    if ($targetIndex -lt 0) {
        for ($index = 0; $index -lt $script:CompressionProfiles.Count; $index += 1) {
            if ([string]::Equals([string]$script:CompressionProfiles[$index].Name, [string]$details.Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                $targetIndex = $index
                break
            }
        }
    }
    $profile = Get-CurrentCompressionProfile -Name ([string]$details.Name) -Note ([string]$details.Note)
    if ($targetIndex -ge 0) {
        $script:CompressionProfiles[$targetIndex] = $profile
    }
    else {
        $targetIndex = $script:CompressionProfiles.Add($profile)
    }
    Update-CompressionProfileControls -SelectedIndex $targetIndex
    Save-CurrentSettings
    Add-LogLine -TextBox $logText -Line "已保存当前配置为方案预设: $($profile.Name)"
})

$deleteProfileButton.Add_Click({
    $index = $profileBox.SelectedIndex - 1
    if ($index -ge 0 -and $index -lt $script:CompressionProfiles.Count) {
        $script:CompressionProfiles.RemoveAt($index)
        Update-CompressionProfileControls -SelectedIndex ([Math]::Min($index, $script:CompressionProfiles.Count - 1))
        Save-CurrentSettings
    }
})

$saveNameButton.Add_Click({
    $name = Get-SafeFileName -Name $baseText.Text
    $index = Add-PresetValue -ComboBox $baseText -Value $name -CaseSensitive $false
    $baseText.SelectedIndex = $index
    $baseText.Text = $name
    Save-CurrentSettings
})

$deleteNameButton.Add_Click({
    $index = $baseText.SelectedIndex
    if ($index -lt 0) {
        for ($candidate = 0; $candidate -lt $baseText.Items.Count; $candidate += 1) {
            if ([string]::Equals([string]$baseText.Items[$candidate], $baseText.Text, [System.StringComparison]::OrdinalIgnoreCase)) {
                $index = $candidate
                break
            }
        }
    }
    if ($index -ge 0) {
        $baseText.Items.RemoveAt($index)
        $baseText.Text = ''
        Save-CurrentSettings
    }
})

$passwordText.Add_SelectedIndexChanged({
    if ($passwordText.SelectedIndex -ge 0) {
        $confirmText.Text = $passwordText.Text
    }
})

$savePasswordButton.Add_Click({
    if ([string]::IsNullOrEmpty($passwordText.Text)) {
        [System.Windows.Forms.MessageBox]::Show($form, '请输入要保存的密码。', '密码为空', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    $index = Add-PresetValue -ComboBox $passwordText -Value $passwordText.Text -CaseSensitive $true
    $passwordText.SelectedIndex = $index
    $confirmText.Text = $passwordText.Text
    Save-CurrentSettings
})

$deletePasswordButton.Add_Click({
    $index = $passwordText.SelectedIndex
    if ($index -lt 0) {
        for ($candidate = 0; $candidate -lt $passwordText.Items.Count; $candidate += 1) {
            if ([string]::Equals([string]$passwordText.Items[$candidate], $passwordText.Text, [System.StringComparison]::Ordinal)) {
                $index = $candidate
                break
            }
        }
    }
    if ($index -ge 0) {
        $passwordText.Items.RemoveAt($index)
        $passwordText.Text = ''
        $confirmText.Text = ''
        Save-CurrentSettings
    }
})

$innerFormat.Add_SelectedIndexChanged({
    Update-HeaderEncryptAvailability
})

$outerFormat.Add_SelectedIndexChanged({
    Update-HeaderEncryptAvailability
})

$volumeModeBox.Add_SelectedIndexChanged({
    Update-VolumeModeAvailability
})

$doubleCompressionCheck.Add_CheckedChanged({
    Update-VolumeModeAvailability
})

$separateOutputsCheck.Add_CheckedChanged({
    Update-NamePresetAvailability
})

$startButton.Add_Click({
    try {
        if ($cancelButton.Enabled) {
            return
        }

        $engine = [string]$engineBox.SelectedItem
        $toolPath = ([string]$sevenZipText.Text).Trim()
        if ([string]::IsNullOrWhiteSpace($toolPath) -or -not (Test-Path -LiteralPath $toolPath -PathType Leaf)) {
            $missingMessage = if ($engine -eq 'Bandizip') {
                '找不到 Bandizip 命令行程序。请安装 Bandizip，或手动选择 bz.exe / Bandizip.exe，也可以放到工具目录的 tools 文件夹中。'
            }
            else {
                '找不到 7z.exe。请安装 7-Zip，或把 7z.exe 放到工具目录的 tools 文件夹中。'
            }
            [System.Windows.Forms.MessageBox]::Show($form, $missingMessage, ('缺少 ' + (Get-ToolDisplayName -Engine $engine)), [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        if ($script:InputPaths.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show($form, '请先拖入或添加要压缩的文件/文件夹。', '缺少输入', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        $outputDir = ([string]$outputText.Text).Trim()
        if ([string]::IsNullOrWhiteSpace($outputDir)) {
            [System.Windows.Forms.MessageBox]::Show($form, '请选择输出目录。', '缺少输出目录', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        if (-not (Test-Path -LiteralPath $outputDir -PathType Container)) {
            [void](New-Item -ItemType Directory -Force -Path $outputDir)
        }

        if ($passwordText.Text -ne $confirmText.Text) {
            [System.Windows.Forms.MessageBox]::Show($form, '两次输入的密码不一致。', '密码不一致', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }

        if ($passwordText.Text.Length -eq 0) {
            $choice = [System.Windows.Forms.MessageBox]::Show($form, '当前没有设置密码，将生成无密码压缩包。是否继续？', '未设置密码', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
            if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) {
                return
            }
        }

        $separateOutputs = [bool]$separateOutputsCheck.Checked
        $doubleCompressionEnabled = [bool]$doubleCompressionCheck.Checked
        $baseName = Get-SafeFileName -Name $baseText.Text
        if (-not $separateOutputs) {
            $baseText.Text = $baseName
        }

        $levelMatch = [regex]::Match([string]$levelBox.SelectedItem, '^\d+')
        $level = if ($levelMatch.Success) { $levelMatch.Value } else { '5' }

        $volumeModeValue = [string]$volumeModeBox.SelectedItem
        $unitSuffix = if ($volumeUnit.SelectedItem -eq 'GB') { 'g' } else { 'm' }
        $volumeSpec = if ($volumeModeValue -eq '固定分卷数量') {
            ''
        }
        else {
            ([int]$volumeSize.Value).ToString() + $unitSuffix
        }
        $volumeCountValue = [int]$volumeCount.Value

        $outputDirResolved = (Resolve-Path -LiteralPath $outputDir).Path
        $outerFormatValue = [string]$outerFormat.SelectedItem
        $innerFormatValue = [string]$innerFormat.SelectedItem
        $jobs = @()
        $plannedArchives = @()

        if ($separateOutputs) {
            $seenArchives = @{}
            $duplicateArchives = @()
            $existingArchives = @()

            foreach ($inputPath in @($script:InputPaths)) {
                $itemBaseName = Get-InputArchiveBaseName -Path $inputPath
                $itemArchive = Join-Path $outputDirResolved ($itemBaseName + '.' + $outerFormatValue)
                $itemKey = $itemArchive.ToLowerInvariant()

                if ($seenArchives.ContainsKey($itemKey)) {
                    $duplicateArchives += $itemArchive
                }
                else {
                    $seenArchives[$itemKey] = $true
                }

                if ((Test-Path -LiteralPath $itemArchive -PathType Leaf) -and -not $overwriteCheck.Checked) {
                    $existingArchives += $itemArchive
                }

                $plannedArchives += $itemArchive
                $jobs += [pscustomobject]@{
                    Engine = $engine
                    ToolPath = $toolPath
                    SevenZip = $toolPath
                    Inputs = [string[]]@($inputPath)
                    OutputDir = $outputDirResolved
                    BaseName = $itemBaseName
                    DoubleCompressionEnabled = $doubleCompressionEnabled
                    InnerFormat = $innerFormatValue
                    OuterFormat = $outerFormatValue
                    VolumeMode = $volumeModeValue
                    VolumeSpec = $volumeSpec
                    VolumeCount = $volumeCountValue
                    Level = $level
                    Password = $passwordText.Text
                    EncryptHeaders = [bool]$headerEncryptCheck.Checked
                    KeepParts = [bool]$keepPartsCheck.Checked
                    Overwrite = [bool]$overwriteCheck.Checked
                }
            }

            if ($duplicateArchives.Count -gt 0) {
                $preview = ($duplicateArchives | Select-Object -Unique -First 8) -join "`r`n"
                [System.Windows.Forms.MessageBox]::Show($form, ('单独压缩模式下存在重复输出文件名，请调整输入项或输出目录:`r`n' + $preview), '输出文件名重复', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                return
            }

            if ($existingArchives.Count -gt 0) {
                $preview = ($existingArchives | Select-Object -First 8) -join "`r`n"
                [System.Windows.Forms.MessageBox]::Show($form, ('以下最终压缩包已存在，请改名、清理输出目录或勾选覆盖:`r`n' + $preview), '文件已存在', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                return
            }
        }
        else {
            $finalArchive = Join-Path $outputDirResolved ($baseName + '.' + $outerFormatValue)
            if ((Test-Path -LiteralPath $finalArchive -PathType Leaf) -and -not $overwriteCheck.Checked) {
                [System.Windows.Forms.MessageBox]::Show($form, ('最终压缩包已存在，请改名或勾选覆盖:`r`n' + $finalArchive), '文件已存在', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                return
            }

            $plannedArchives += $finalArchive
            $jobs += [pscustomobject]@{
                Engine = $engine
                ToolPath = $toolPath
                SevenZip = $toolPath
                Inputs = [string[]]@($script:InputPaths)
                OutputDir = $outputDirResolved
                BaseName = $baseName
                DoubleCompressionEnabled = $doubleCompressionEnabled
                InnerFormat = $innerFormatValue
                OuterFormat = $outerFormatValue
                VolumeMode = $volumeModeValue
                VolumeSpec = $volumeSpec
                VolumeCount = $volumeCountValue
                Level = $level
                Password = $passwordText.Text
                EncryptHeaders = [bool]$headerEncryptCheck.Checked
                KeepParts = [bool]$keepPartsCheck.Checked
                Overwrite = [bool]$overwriteCheck.Checked
            }
        }

        $logText.Clear()
        Add-LogLine -TextBox $logText -Line '任务开始。'
        Add-LogLine -TextBox $logText -Line ('压缩核心: {0}' -f $engine)
        Add-LogLine -TextBox $logText -Line ('输出模式: {0}' -f $(if ($separateOutputs) { '每个输入项单独生成最终包' } else { '全部输入合并为一个最终包' }))
        Add-LogLine -TextBox $logText -Line ('压缩模式: {0}' -f $(if ($doubleCompressionEnabled) { '双重分卷压缩' } else { '普通单层压缩（不分卷）' }))
        if ($doubleCompressionEnabled) {
            Add-LogLine -TextBox $logText -Line ('分卷模式: {0}' -f $(if ($volumeModeValue -eq '固定分卷数量') { ('固定生成 ' + $volumeCountValue + ' 个') } else { ('每卷 ' + $volumeSize.Value + ' ' + $volumeUnit.SelectedItem) }))
        }
        Add-LogLine -TextBox $logText -Line ('输入数量: {0}' -f $script:InputPaths.Count)
        Add-LogLine -TextBox $logText -Line ('最终输出: {0}' -f $(if ($separateOutputs) { $outputDirResolved } else { $plannedArchives[0] }))

        Save-CurrentSettings
        $script:CancelRequested = $false
        $statusLabel.Text = '压缩中...'
        $progress.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
        $startButton.Enabled = $false
        $cancelButton.Enabled = $true

        try {
            $results = New-Object 'System.Collections.Generic.List[object]'
            $jobIndex = 0
            foreach ($job in $jobs) {
                $jobIndex += 1
                if ($jobs.Count -gt 1) {
                    Add-LogLine -TextBox $logText -Line ('单独压缩 {0}/{1}: {2}' -f $jobIndex, $jobs.Count, $job.BaseName)
                }
                [void]$results.Add((Invoke-CompressionJob -Job $job -Worker $logText))
            }

            $statusLabel.Text = '完成'
            if ($results.Count -eq 1) {
                $result = $results[0]
                $message = "最终压缩包:`r`n$($result.FinalArchive)"
                if ($result.IsDoubleCompression) {
                    $message += "`r`n`r`n分卷数: $($result.VolumeCount)"
                }
                if ($result.KeptDir) {
                    $message += "`r`n分卷保留目录:`r`n$($result.KeptDir)"
                }
            }
            else {
                $message = "已完成 $($results.Count) 个最终压缩包。`r`n`r`n输出目录:`r`n$outputDirResolved"
                $names = @($results | Select-Object -First 8 | ForEach-Object { [System.IO.Path]::GetFileName($_.FinalArchive) })
                if ($names.Count -gt 0) {
                    $message += "`r`n`r`n" + ($names -join "`r`n")
                    if ($results.Count -gt $names.Count) {
                        $message += "`r`n..."
                    }
                }
            }
            [System.Windows.Forms.MessageBox]::Show($form, $message, '压缩完成', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        }
        catch {
            if ($_.Exception.Message -eq '用户已取消。') {
                $statusLabel.Text = '已取消'
                Add-LogLine -TextBox $logText -Line '任务已取消。'
            }
            else {
                $statusLabel.Text = '失败'
                Add-LogLine -TextBox $logText -Line ('失败: ' + $_.Exception.Message)
                [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, '压缩失败', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            }
        }
        finally {
            $script:CancelRequested = $false
            $startButton.Enabled = $true
            $cancelButton.Enabled = $false
            $progress.Style = [System.Windows.Forms.ProgressBarStyle]::Blocks
            $progress.Value = 0
        }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, '启动失败', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
})

$cancelButton.Add_Click({
    if ($cancelButton.Enabled) {
        $script:CancelRequested = $true
        $statusLabel.Text = '正在取消...'
        Add-LogLine -TextBox $logText -Line '正在请求取消任务...'
        try {
            if ($script:CurrentProcess -and -not $script:CurrentProcess.HasExited) {
                $script:CurrentProcess.Kill()
            }
        }
        catch {
        }
    }
})

$updateButton.Add_Click({
    Invoke-UpdateCheck -Owner $form -UpdateButton $updateButton -StatusLabel $statusLabel -LogText $logText
})

$automaticUpdateTimer = New-Object System.Windows.Forms.Timer
$automaticUpdateTimer.Interval = 1500
$automaticUpdateTimer.Add_Tick({
    $automaticUpdateTimer.Stop()
    Invoke-UpdateCheck -Owner $form -UpdateButton $updateButton -StatusLabel $statusLabel -LogText $logText -Automatic
})
$form.Add_Shown({
    $automaticUpdateTimer.Start()
})

$form.Add_FormClosing({
    $automaticUpdateTimer.Stop()
    if ($cancelButton.Enabled) {
        $choice = [System.Windows.Forms.MessageBox]::Show($form, '压缩仍在进行，确定要取消并退出吗？', '确认退出', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) {
            $_.Cancel = $true
            return
        }

        $script:CancelRequested = $true
        try {
            if ($script:CurrentProcess -and -not $script:CurrentProcess.HasExited) {
                $script:CurrentProcess.Kill()
            }
        }
        catch {
        }
        $_.Cancel = $true
        return
    }

    Save-CurrentSettings
})

Add-LogLine -TextBox $logText -Line '准备就绪。'
if (-not $sevenZipText.Text) {
    if ($engineBox.SelectedItem -eq 'Bandizip') {
        Add-LogLine -TextBox $logText -Line '未自动找到 Bandizip。请安装 Bandizip，或手动选择 bz.exe / Bandizip.exe。'
    }
    else {
        Add-LogLine -TextBox $logText -Line '未自动找到 7z.exe。请安装 7-Zip，或手动选择 7z.exe。'
    }
}

[void][System.Windows.Forms.Application]::Run($form)

#ifndef MyAppVersion
  #define MyAppVersion "1.1.0"
#endif

#define MyAppName "双层分卷压缩器"
#define MyAppPublisher "Langbai Studio"
#define MyAppURL "https://github.com/2786886095/dual-volume-compressor"
#define RepoRoot "..\.."

[Setup]
AppId={{8B5E6E77-6944-46AE-9958-49691207035A}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} v{#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases/latest
DefaultDirName={autopf}\Langbai Studio\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir={#RepoRoot}\dist\windows
OutputBaseFilename=DualVolumeCompressor-Setup-x64-v{#MyAppVersion}
SetupIconFile={#RepoRoot}\Assets\AppIcon.ico
UninstallDisplayIcon={app}\AppIcon.ico
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.22000
CloseApplications=yes
RestartApplications=no
ChangesAssociations=yes
SetupLogging=yes

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加快捷方式:"; Flags: unchecked

[Files]
Source: "{#RepoRoot}\DualVolumeCompressor.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#RepoRoot}\Start-Compressor.bat"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#RepoRoot}\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#RepoRoot}\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#RepoRoot}\THIRD_PARTY_NOTICES.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#RepoRoot}\Assets\AppIcon.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#RepoRoot}\Assets\Square150x150Logo.png"; DestDir: "{app}\Assets"; Flags: ignoreversion
Source: "{#RepoRoot}\Assets\Square44x44Logo.png"; DestDir: "{app}\Assets"; Flags: ignoreversion
Source: "{#RepoRoot}\Assets\StoreLogo.png"; DestDir: "{app}\Assets"; Flags: ignoreversion
Source: "{#RepoRoot}\windows\bin\DualVolumeContextMenu.dll"; DestDir: "{app}\windows\bin"; Flags: ignoreversion
Source: "{#RepoRoot}\windows\bin\DualVolumeLauncher.exe"; DestDir: "{app}\windows\bin"; Flags: ignoreversion
Source: "{#RepoRoot}\windows\install-context-menu.ps1"; DestDir: "{app}\windows"; Flags: ignoreversion
Source: "{#RepoRoot}\windows\uninstall-context-menu.ps1"; DestDir: "{app}\windows"; Flags: ignoreversion
Source: "{#RepoRoot}\dist\windows\DualVolumeCompressor.ContextMenu.msix"; DestDir: "{app}\dist\windows"; Flags: ignoreversion
Source: "{#RepoRoot}\dist\windows\DualVolumeCompressor.ContextMenu.cer"; DestDir: "{app}\dist\windows"; Flags: ignoreversion

[Icons]
Name: "{group}\双层分卷压缩器"; Filename: "{app}\windows\bin\DualVolumeLauncher.exe"; WorkingDir: "{app}"; IconFilename: "{app}\AppIcon.ico"
Name: "{autodesktop}\双层分卷压缩器"; Filename: "{app}\windows\bin\DualVolumeLauncher.exe"; WorkingDir: "{app}"; IconFilename: "{app}\AppIcon.ico"; Tasks: desktopicon

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -ExecutionPolicy Bypass -File ""{app}\windows\install-context-menu.ps1"""; StatusMsg: "正在注册 Windows 11 一级右键菜单..."; Flags: runhidden waituntilterminated
Filename: "{app}\windows\bin\DualVolumeLauncher.exe"; Description: "启动双层分卷压缩器"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -ExecutionPolicy Bypass -File ""{app}\windows\uninstall-context-menu.ps1"""; Flags: runhidden waituntilterminated; RunOnceId: "RemoveContextMenu"

[Code]
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
  ScriptPath: String;
begin
  Result := '';
  ScriptPath := ExpandConstant('{app}\windows\uninstall-context-menu.ps1');
  if FileExists(ScriptPath) then
  begin
    Exec(
      ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
      '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + ScriptPath + '"',
      '',
      SW_HIDE,
      ewWaitUntilTerminated,
      ResultCode
    );
  end;
end;

; ============================================================
; FFmpeg++ v4.5.0 Inno Setup Installer Script
; Build: 2026-07-11
; ============================================================
; 使用方法:
;   1. 确保 build/ 文件夹已准备好 (flutter build + ffmpegpp.dll)
;   2. Inno Setup Compiler → File → Open → 选此文件 → Build → Compile
;   3. 或命令行: iscc setup.iss
;   4. 输出: dist\FFmpeg++_v4.0.0_setup.exe
; ============================================================

#define MyAppName "FFmpeg++"
#define MyAppVersion "4.5.0"
#define MyAppPublisher "氯堡拾稿"
#define MyAppURL "https://blog-clstone.netlify.app/"
#define MyAppGitHub "https://github.com/pity-Fox/FFmpeg_plus_plus"
#define MyAppExeName "ffmpegpp_gui.exe"

; 源文件根目录 — 相对于本 .iss 文件所在目录 (make/)
#define SourceRoot "..\build"

[Setup]
AppId={{E4EA3A3E-0CC0-48D2-B685-9ADCDEE7EB40}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppGitHub}
AppUpdatesURL={#MyAppGitHub}
VersionInfoVersion={#MyAppVersion}.0
VersionInfoDescription={#MyAppName} Installer
VersionInfoProductName={#MyAppName}
VersionInfoProductVersion={#MyAppVersion}
DefaultDirName={autopf}\{#MyAppName}
UninstallDisplayName={#MyAppName} {#MyAppVersion}
UninstallDisplayIcon={app}\{#MyAppExeName}
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
ChangesAssociations=yes
DisableProgramGroupPage=yes
PrivilegesRequiredOverridesAllowed=dialog
OutputDir={#SourceRoot}\..\dist
OutputBaseFilename=FFmpeg++_v{#MyAppVersion}_setup
SetupIconFile=app_icon.ico
SolidCompression=yes
WizardStyle=modern dynamic windows11
Compression=lzma2/max
InternalCompressLevel=max

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; ── 主程序 ──
Source: "{#SourceRoot}\{#MyAppExeName}";                         DestDir: "{app}"; Flags: ignoreversion

; ── C++ 后端 DLL ──
Source: "{#SourceRoot}\ffmpegpp.dll";                            DestDir: "{app}"; Flags: ignoreversion

; ── Flutter 运行时 ──
Source: "{#SourceRoot}\flutter_windows.dll";                     DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceRoot}\dartjni.dll";                             DestDir: "{app}"; Flags: ignoreversion

; ── 插件 DLL ──
Source: "{#SourceRoot}\desktop_drop_plugin.dll";                 DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceRoot}\screen_retriever_windows_plugin.dll";     DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceRoot}\window_manager_plugin.dll";               DestDir: "{app}"; Flags: ignoreversion

; ── VC++ 运行时（如存在） ──
Source: "{#SourceRoot}\msvcp140.dll";                            DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "{#SourceRoot}\vcruntime140.dll";                        DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "{#SourceRoot}\vcruntime140_1.dll";                      DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist

; ── Flutter AOT 编译产物 + 资源 ──
Source: "{#SourceRoot}\data\*";                                  DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}";                            Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}";                             Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[Registry]
Root: HKA; Subkey: "Software\Classes\.ffmpegpp\OpenWithProgids";  ValueType: string; ValueName: "FFmpegppFile"; ValueData: ""; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\FFmpegppFile";               ValueType: string; ValueName: ""; ValueData: "FFmpeg++ 项目文件"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\FFmpegppFile\DefaultIcon";   ValueType: string; ValueName: ""; ValueData: "{app}\{#MyAppExeName},0"
Root: HKA; Subkey: "Software\Classes\FFmpegppFile\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#MyAppExeName}"" ""%1"""

[Code]
function InitializeSetup: Boolean;
begin
  Result := True;
  if CheckForMutexes('{#MyAppExeName}') then
  begin
    if MsgBox('{#MyAppName} 正在运行，请先关闭再继续安装。' + #13#10 +
              '{#MyAppName} is running, please close it first.',
              mbError, MB_OKCANCEL) = IDCANCEL then
      Result := False;
  end;
end;

function InitializeUninstall: Boolean;
begin
  Result := True;
  if CheckForMutexes('{#MyAppExeName}') then
  begin
    if MsgBox('{#MyAppName} 正在运行，请先关闭再卸载。' + #13#10 +
              '{#MyAppName} is running, please close it first.',
              mbError, MB_OKCANCEL) = IDCANCEL then
      Result := False;
  end;
end;

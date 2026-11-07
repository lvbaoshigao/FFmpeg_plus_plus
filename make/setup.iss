; ============================================================
; FFmpeg++ v5.30.51 Inno Setup Installer Script
; Build: 2026-10-18
; ============================================================
; 使用方法:
;   1. 确保 build/ 文件夹已准备好 (flutter build + ffmpegpp.dll)
;   2. Inno Setup Compiler → File → Open → 选此文件 → Build → Compile
;   3. 或命令行: iscc setup.iss
;   4. 输出: dist\FFmpeg++_v5.30.51_setup.exe
; ============================================================

#define MyAppName "FFmpeg++"
#define MyAppVersion "5.30.51"
; 纯数字版本号（Windows 版本资源要求 x.x.x.x，不能包含 beta 等字符）
#define MyAppVersionNumeric "5.30.51.0"
#define MyAppPublisher "氯堡拾稿"
#define MyAppURL "https://blog-clstone.netlify.app/"
#define MyAppGitHub "https://github.com/lvbaoshigao/FFmpeg_plus_plus"
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
VersionInfoVersion={#MyAppVersionNumeric}
VersionInfoDescription={#MyAppName} Installer
VersionInfoProductName={#MyAppName}
VersionInfoProductVersion={#MyAppVersionNumeric}
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
Name: "chinesetraditional"; MessagesFile: "compiler:Languages\ChineseTraditional.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; ── 主程序 ──
Source: "{#SourceRoot}\{#MyAppExeName}";                         DestDir: "{app}"; Flags: ignoreversion

; ── 运行时与插件 DLL（一律通配收录）──
; DLL 集合由构建期决定，不做手工清单：flutter_windows.dll、ffmpegpp.dll、
; generated_plugins.cmake 的 FLUTTER_PLUGIN_LIST 各 *_plugin.dll
; （desktop_drop / desktop_multi_window / flutter_secure_storage_windows /
; screen_retriever_windows / window_manager）、FFI 的 dartjni.dll、
; VC++ 运行时（构建目录里有才打包）。手工清单必然漂移 —— 2026-11-07 就漏了
; desktop_multi_window_plugin.dll 与 flutter_secure_storage_windows_plugin.dll，
; 安装后启动报「由于找不到 xxx.dll，无法继续执行代码」。新增原生插件无需再改本脚本。
Source: "{#SourceRoot}\*.dll";                                   DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist

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

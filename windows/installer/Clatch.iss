; SPDX-License-Identifier: GPL-3.0-or-later
; Clatch for Windows installer (Inno Setup 6.3+).
;   iscc /DVersion=0.1.0 /DX64Dir=..\out\win-x64 /DArm64Dir=..\out\win-arm64 Clatch.iss
; One installer for x64 and ARM64; installs for the current user, no admin rights.

#ifndef Version
  #define Version "0.0.0"
#endif

[Setup]
AppId={{B6F2C1E4-3A7D-4E8B-9C21-5D4F8A6E0B17}
AppName=Clatch
AppVersion={#Version}
AppVerName=Clatch {#Version}
AppPublisher=Issen Software Group
AppPublisherURL=https://issen.kurokamicorp.com/
AppSupportURL=https://github.com/AA-EION/Clatch/issues
AppUpdatesURL=https://github.com/AA-EION/Clatch/releases
AppCopyright=© 2026 Issen Software Group. GNU GPL v3 or later.
DefaultDirName={localappdata}\Programs\Clatch
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible or arm64
ArchitecturesInstallIn64BitMode=x64compatible or arm64
MinVersion=10.0.17763
LicenseFile=..\..\LICENSE
SetupIconFile=..\src\Clatch\Assets\Clatch.ico
UninstallDisplayIcon={app}\Clatch.exe
UninstallDisplayName=Clatch
OutputDir=..\out
OutputBaseFilename=Clatch-{#Version}-windows-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; Close a running Clatch (politely, via Restart Manager) when updating.
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "startup"; Description: "Open Clatch when I sign in to Windows"; Flags: checkedonce

[Files]
Source: "{#X64Dir}\*"; DestDir: "{app}"; Check: not IsArm64; Flags: recursesubdirs createallsubdirs ignoreversion
Source: "{#Arm64Dir}\*"; DestDir: "{app}"; Check: IsArm64; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{autoprograms}\Clatch"; Filename: "{app}\Clatch.exe"; Comment: "Switch Claude Desktop accounts"

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Clatch"; \
  ValueData: """{app}\Clatch.exe"""; Tasks: startup; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueName: "Clatch"; \
  Flags: dontcreatekey uninsdeletevalue

[Run]
Filename: "{app}\Clatch.exe"; Description: "Open Clatch now"; Flags: nowait postinstall skipifsilent

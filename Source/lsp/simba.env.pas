{
  Author: Raymond van Venetië and Merlijn Wajer
  Project: Simba (https://github.com/MerlijnWajer/Simba)
  License: GNU General Public License (https://www.gnu.org/licenses/gpl-3.0)

  Stub simba.env for standalone LSP server.
  Provides environment interface for codetools with configurable paths.
}
unit simba.env;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, simba.base;

type
  TSimbaEnv = class
  private
    FSimbaPath: String;
    FIncludesPath: String;
    FPluginsPath: String;
    FDataPath: String;
    FDumpsPath: String;
    FIncludePaths: TStringList;
  public
    constructor Create;
    destructor Destroy; override;

    function FindPlugin(FileName: String; ExtraSearchDirs: TStringArray = nil): String;
    function FindInclude(FileName: String; ExtraSearchDirs: TStringArray = nil): String;
    function HasInclude(FileName: String; ExtraSearchDirs: TStringArray = nil): Boolean;
    function HasPlugin(FileName: String; ExtraSearchDirs: TStringArray = nil): Boolean;
    function FindSimbaExecutable: String;

    procedure AddIncludePath(const Path: String);
    procedure SetSimbaPath(const Path: String);

    property SimbaPath: String read FSimbaPath;
    property IncludesPath: String read FIncludesPath;
    property PluginsPath: String read FPluginsPath;
    property DataPath: String read FDataPath;
    property DumpsPath: String read FDumpsPath;
  end;

var
  SimbaEnv: TSimbaEnv;

implementation

constructor TSimbaEnv.Create;
begin
  inherited Create;
  FIncludePaths := TStringList.Create;
  FIncludePaths.Duplicates := dupIgnore;

  // Default to executable location
  FSimbaPath := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
  FIncludesPath := FSimbaPath + 'Includes' + PathDelim;
  FPluginsPath := FSimbaPath + 'Plugins' + PathDelim;
  FDataPath := GetTempDir;
  FDumpsPath := IncludeTrailingPathDelimiter(GetTempDir) + 'SimbaLSP' + PathDelim;

  // Ensure dumps directory exists
  if not DirectoryExists(FDumpsPath) then
    ForceDirectories(FDumpsPath);
end;

destructor TSimbaEnv.Destroy;
begin
  FreeAndNil(FIncludePaths);
  inherited Destroy;
end;

procedure TSimbaEnv.SetSimbaPath(const Path: String);
begin
  if Path <> '' then
  begin
    FSimbaPath := IncludeTrailingPathDelimiter(Path);
    FIncludesPath := FSimbaPath + 'Includes' + PathDelim;
    FPluginsPath := FSimbaPath + 'Plugins' + PathDelim;
  end;
end;

procedure TSimbaEnv.AddIncludePath(const Path: String);
begin
  if (Path <> '') and DirectoryExists(Path) then
    FIncludePaths.Add(IncludeTrailingPathDelimiter(Path));
end;

function TSimbaEnv.FindInclude(FileName: String; ExtraSearchDirs: TStringArray): String;
var
  SearchDir: String;
  I: Integer;
begin
  // Check if it's an absolute path that exists
  if FileExists(FileName) then
    Exit(FileName);

  // Search in extra directories (passed by codetools, usually script directory)
  for SearchDir in ExtraSearchDirs do
  begin
    Result := IncludeTrailingPathDelimiter(SearchDir) + FileName;
    if FileExists(Result) then
      Exit(Result);

    Result := IncludeTrailingPathDelimiter(SearchDir) + FileName + '.simba';
    if FileExists(Result) then
      Exit(Result);
  end;

  // Search in configured include paths (from LSP settings)
  for I := 0 to FIncludePaths.Count - 1 do
  begin
    Result := FIncludePaths[I] + FileName;
    if FileExists(Result) then
      Exit(Result);

    Result := FIncludePaths[I] + FileName + '.simba';
    if FileExists(Result) then
      Exit(Result);
  end;

  // Search in default Simba includes path
  if FIncludesPath <> '' then
  begin
    Result := FIncludesPath + FileName;
    if FileExists(Result) then
      Exit(Result);

    Result := FIncludesPath + FileName + '.simba';
    if FileExists(Result) then
      Exit(Result);
  end;

  // Search in Simba path
  if FSimbaPath <> '' then
  begin
    Result := FSimbaPath + FileName;
    if FileExists(Result) then
      Exit(Result);

    Result := FSimbaPath + FileName + '.simba';
    if FileExists(Result) then
      Exit(Result);
  end;

  Result := '';
end;

function TSimbaEnv.FindPlugin(FileName: String; ExtraSearchDirs: TStringArray): String;
const
  {$IF DEFINED(CPUAARCH64)}
  SimbaSuffix = '.so.aarch64';
  {$ELSEIF DEFINED(WINDOWS)}
  SimbaSuffix = {$IFDEF CPU32}'32.dll'{$ELSE}'64.dll'{$ENDIF};
  {$ELSE}
  SimbaSuffix = {$IFDEF CPU32}'32.so'{$ELSE}'64.so'{$ENDIF};
  {$ENDIF}
var
  SearchDir: String;
begin
  // Check if it's an absolute path that exists
  if FileExists(FileName) then
    Exit(FileName);

  // Search in extra directories
  for SearchDir in ExtraSearchDirs do
  begin
    Result := IncludeTrailingPathDelimiter(SearchDir) + FileName;
    if FileExists(Result) then
      Exit(Result);

    Result := IncludeTrailingPathDelimiter(SearchDir) + FileName + SimbaSuffix;
    if FileExists(Result) then
      Exit(Result);
  end;

  // Search in default plugins path
  if FPluginsPath <> '' then
  begin
    Result := FPluginsPath + FileName;
    if FileExists(Result) then
      Exit(Result);

    Result := FPluginsPath + FileName + SimbaSuffix;
    if FileExists(Result) then
      Exit(Result);
  end;

  // Search in Simba path
  if FSimbaPath <> '' then
  begin
    Result := FSimbaPath + FileName;
    if FileExists(Result) then
      Exit(Result);

    Result := FSimbaPath + FileName + SimbaSuffix;
    if FileExists(Result) then
      Exit(Result);
  end;

  Result := '';
end;

function TSimbaEnv.HasInclude(FileName: String; ExtraSearchDirs: TStringArray): Boolean;
begin
  Result := FindInclude(FileName, ExtraSearchDirs) <> '';
end;

function TSimbaEnv.HasPlugin(FileName: String; ExtraSearchDirs: TStringArray): Boolean;
begin
  Result := FindPlugin(FileName, ExtraSearchDirs) <> '';
end;

function TSimbaEnv.FindSimbaExecutable: String;
const
  {$IFDEF WINDOWS}
  SimbaExeName = 'Simba.exe';
  {$ELSE}
  SimbaExeName = 'Simba';
  {$ENDIF}
begin
  // First check if Simba is in the configured SimbaPath
  Result := FSimbaPath + SimbaExeName;
  if FileExists(Result) then
    Exit;

  // Check parent directory (if LSP is in a subdirectory)
  Result := ExtractFilePath(ExcludeTrailingPathDelimiter(FSimbaPath)) + SimbaExeName;
  if FileExists(Result) then
    Exit;

  // Check alongside this executable
  Result := ExtractFilePath(ParamStr(0)) + SimbaExeName;
  if FileExists(Result) then
    Exit;

  // Not found
  Result := '';
end;

procedure InitFromEnvironment;
var
  EnvPaths, SimbaPath: String;
  PathList: TStringList;
  I: Integer;
begin
  // Allow setting Simba path via environment variable
  SimbaPath := GetEnvironmentVariable('SIMBA_PATH');
  if SimbaPath <> '' then
    SimbaEnv.SetSimbaPath(SimbaPath);

  // Allow setting include paths via environment variable (semicolon-separated)
  EnvPaths := GetEnvironmentVariable('SIMBA_INCLUDE_PATHS');
  if EnvPaths <> '' then
  begin
    PathList := TStringList.Create;
    try
      PathList.Delimiter := ';';
      PathList.StrictDelimiter := True;
      PathList.DelimitedText := EnvPaths;
      for I := 0 to PathList.Count - 1 do
        SimbaEnv.AddIncludePath(PathList[I]);
    finally
      PathList.Free;
    end;
  end;
end;

initialization
  SimbaEnv := TSimbaEnv.Create;
  InitFromEnvironment;

finalization
  FreeAndNil(SimbaEnv);

end.

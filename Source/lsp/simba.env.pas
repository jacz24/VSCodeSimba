{
  Author: Raymond van Venetië and Merlijn Wajer
  Project: Simba (https://github.com/MerlijnWajer/Simba)
  License: GNU General Public License (https://www.gnu.org/licenses/gpl-3.0)

  Stub simba.env for standalone LSP server.
  Provides environment interface for codetools with configurable paths.
  Uses class methods to match the full Simba implementation.
}
unit simba.env;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, simba.base;

type
  SimbaEnv = class
  private
  class var
    FSimbaPath: String;
    FIncludesPath: String;
    FPluginsPath: String;
    FDataPath: String;
    FDumpsPath: String;
    FIncludePaths: TStringList;
  public
    class constructor Create;
    class destructor Destroy;

    class function FindPlugin(FileName: String; ExtraSearchDirs: TStringArray = nil): String;
    class function FindInclude(FileName: String; ExtraSearchDirs: TStringArray = nil): String;
    class function HasInclude(FileName: String; ExtraSearchDirs: TStringArray = nil): Boolean;
    class function HasPlugin(FileName: String; ExtraSearchDirs: TStringArray = nil): Boolean;
    class function FindSimbaExecutable: String;

    class procedure AddIncludePath(const Path: String);
    class procedure SetSimbaPath(const Path: String);
    class procedure LoadIncludePathsFromEnv;

    class property SimbaPath: String read FSimbaPath;
    class property IncludesPath: String read FIncludesPath;
    class property PluginsPath: String read FPluginsPath;
    class property DataPath: String read FDataPath;
    class property DumpsPath: String read FDumpsPath;
  end;

implementation

uses
  simba.fs;

class constructor SimbaEnv.Create;
begin
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

  // Load custom include paths from environment variable
  LoadIncludePathsFromEnv;
end;

class destructor SimbaEnv.Destroy;
begin
  FreeAndNil(FIncludePaths);
end;

class procedure SimbaEnv.SetSimbaPath(const Path: String);
begin
  if Path <> '' then
  begin
    FSimbaPath := IncludeTrailingPathDelimiter(Path);
    FIncludesPath := FSimbaPath + 'Includes' + PathDelim;
    FPluginsPath := FSimbaPath + 'Plugins' + PathDelim;
  end;
end;

class procedure SimbaEnv.AddIncludePath(const Path: String);
begin
  if (Path <> '') and DirectoryExists(Path) then
    FIncludePaths.Add(IncludeTrailingPathDelimiter(Path));
end;

class procedure SimbaEnv.LoadIncludePathsFromEnv;
var
  EnvPaths, EnvSimbaPath: String;
  PathList: TStringList;
  I: Integer;
begin
  // Allow setting Simba path via environment variable
  EnvSimbaPath := GetEnvironmentVariable('SIMBA_PATH');
  if EnvSimbaPath <> '' then
    SetSimbaPath(EnvSimbaPath);

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
        AddIncludePath(PathList[I]);
    finally
      PathList.Free;
    end;
  end;
end;

class function SimbaEnv.FindInclude(FileName: String; ExtraSearchDirs: TStringArray): String;
var
  SearchDir: String;
  I: Integer;
begin
  // Check if it's an absolute path that exists
  if TSimbaFile.FileExists(FileName) then
    Exit(FileName);

  // Search in extra directories (passed by codetools, usually script directory)
  for SearchDir in ExtraSearchDirs do
  begin
    Result := TSimbaPath.PathJoin([SearchDir, FileName]);
    if TSimbaFile.FileExists(Result) then
      Exit(Result);

    Result := TSimbaPath.PathJoin([SearchDir, FileName]) + '.simba';
    if TSimbaFile.FileExists(Result) then
      Exit(Result);
  end;

  // Search in configured include paths (from LSP settings)
  for I := 0 to FIncludePaths.Count - 1 do
  begin
    Result := TSimbaPath.PathJoin([FIncludePaths[I], FileName]);
    if TSimbaFile.FileExists(Result) then
      Exit(Result);

    Result := TSimbaPath.PathJoin([FIncludePaths[I], FileName]) + '.simba';
    if TSimbaFile.FileExists(Result) then
      Exit(Result);
  end;

  // Search in default Simba includes path
  Result := TSimbaPath.PathJoin([IncludesPath, FileName]);
  if TSimbaFile.FileExists(Result) then
    Exit(Result);
  Result := TSimbaPath.PathJoin([IncludesPath, FileName]) + '.simba';
  if TSimbaFile.FileExists(Result) then
    Exit(Result);

  // Search in Simba path
  Result := TSimbaPath.PathJoin([SimbaPath, FileName]);
  if TSimbaFile.FileExists(Result) then
    Exit(Result);
  Result := TSimbaPath.PathJoin([SimbaPath, FileName]) + '.simba';
  if TSimbaFile.FileExists(Result) then
    Exit(Result);

  Result := '';
end;

class function SimbaEnv.FindPlugin(FileName: String; ExtraSearchDirs: TStringArray): String;
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
  if TSimbaFile.FileExists(FileName) then
    Exit(FileName);

  // Search in extra directories
  for SearchDir in ExtraSearchDirs do
  begin
    Result := TSimbaPath.PathJoin([SearchDir, FileName]);
    if TSimbaFile.FileExists(Result) then
      Exit(Result);

    Result := TSimbaPath.PathJoin([SearchDir, FileName]) + SimbaSuffix;
    if TSimbaFile.FileExists(Result) then
      Exit(Result);
  end;

  // Search in plugins path
  Result := TSimbaPath.PathJoin([PluginsPath, FileName]);
  if TSimbaFile.FileExists(Result) then
    Exit(Result);
  Result := TSimbaPath.PathJoin([PluginsPath, FileName]) + SimbaSuffix;
  if TSimbaFile.FileExists(Result) then
    Exit(Result);

  // Search in Simba path
  Result := TSimbaPath.PathJoin([SimbaPath, FileName]);
  if TSimbaFile.FileExists(Result) then
    Exit(Result);
  Result := TSimbaPath.PathJoin([SimbaPath, FileName]) + SimbaSuffix;
  if TSimbaFile.FileExists(Result) then
    Exit(Result);

  Result := '';
end;

class function SimbaEnv.HasInclude(FileName: String; ExtraSearchDirs: TStringArray): Boolean;
begin
  Result := FindInclude(FileName, ExtraSearchDirs) <> '';
end;

class function SimbaEnv.HasPlugin(FileName: String; ExtraSearchDirs: TStringArray): Boolean;
begin
  Result := FindPlugin(FileName, ExtraSearchDirs) <> '';
end;

class function SimbaEnv.FindSimbaExecutable: String;
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

end.

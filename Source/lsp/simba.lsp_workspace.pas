{
  Author: Raymond van Venetie and Merlijn Wajer
  Project: Simba (https://github.com/MerlijnWajer/Simba)
  License: GNU General Public License (https://www.gnu.org/licenses/gpl-3.0)

  Workspace-wide file discovery and symbol caching for LSP.
}
unit simba.lsp_workspace;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fgl,
  simba.ide_codetools_parser,
  simba.ide_codetools_base;

type
  TLSPSymbolKindInt = Integer;

  TWorkspaceCachedDecl = record
    Name: String;
    Kind: TLSPSymbolKindInt;
    Line: Integer;
    Col: Integer;
    FilePath: String;
    Detail: String;
  end;
  TWorkspaceCachedDeclArray = array of TWorkspaceCachedDecl;

const
  LSP_SK_FUNCTION = 12;
  LSP_SK_CLASS = 5;
  LSP_SK_VARIABLE = 13;
  LSP_SK_CONSTANT = 14;
  LSP_SK_STRUCT = 23;

type
  TFileCacheEntry = record
    FilePath: String;
    ModifiedTime: TDateTime;
    Declarations: TWorkspaceCachedDeclArray;
  end;

  TFileCacheMap = specialize TFPGMap<String, TFileCacheEntry>;

  TWorkspaceIndex = class
  private
    FWorkspaceRoot: String;
    FCache: TFileCacheMap;

    function GetFileModTime(const FilePath: String): TDateTime;
    function ParseFileDeclarations(const FilePath: String): TWorkspaceCachedDeclArray;
    procedure EnsureFileCached(const FilePath: String);
  public
    constructor Create;
    destructor Destroy; override;

    procedure SetWorkspaceRoot(const Path: String);
    function Search(const Query: String): TWorkspaceCachedDeclArray;
    procedure InvalidateFile(const FilePath: String);
    procedure Clear;

    property WorkspaceRoot: String read FWorkspaceRoot;
  end;

function FindSimbaFiles(const RootDir: String): TStringList;

implementation

uses
  simba.fs;

const
  EXCLUDED_DIRS: array[0..4] of String = (
    '.git',
    '.svn',
    'node_modules',
    'build',
    '__pycache__'
  );

  MAX_RESULTS = 100;

function IsExcludedDir(const DirName: String): Boolean;
var
  I: Integer;
  LowerName: String;
begin
  Result := False;
  if DirName = '' then Exit;

  if DirName[1] = '.' then
    Exit(True);

  LowerName := LowerCase(DirName);
  for I := Low(EXCLUDED_DIRS) to High(EXCLUDED_DIRS) do
    if LowerName = EXCLUDED_DIRS[I] then
      Exit(True);
end;

procedure ScanDirectory(const Dir: String; Files: TStringList);
var
  SR: TSearchRec;
  FullPath: String;
begin
  if FindFirst(Dir + '*', faAnyFile, SR) = 0 then
  begin
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then
          Continue;

        FullPath := Dir + SR.Name;

        if (SR.Attr and faDirectory) <> 0 then
        begin
          if not IsExcludedDir(SR.Name) then
            ScanDirectory(FullPath + PathDelim, Files);
        end
        else
        begin
          // Case-insensitive extension match (.simba, .SIMBA, .Simba all match)
          if LowerCase(ExtractFileExt(SR.Name)) = '.simba' then
            Files.Add(FullPath);
        end;
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;
end;

function FindSimbaFiles(const RootDir: String): TStringList;
var
  NormalizedDir: String;
begin
  Result := TStringList.Create;

  if (RootDir = '') or not DirectoryExists(RootDir) then
    Exit;

  NormalizedDir := IncludeTrailingPathDelimiter(RootDir);
  ScanDirectory(NormalizedDir, Result);
end;

{ TWorkspaceIndex }

constructor TWorkspaceIndex.Create;
begin
  inherited Create;
  FCache := TFileCacheMap.Create;
  FWorkspaceRoot := '';
end;

destructor TWorkspaceIndex.Destroy;
begin
  FCache.Free;
  inherited Destroy;
end;

procedure TWorkspaceIndex.SetWorkspaceRoot(const Path: String);
begin
  if FWorkspaceRoot <> Path then
  begin
    FWorkspaceRoot := Path;
    Clear;
  end;
end;

procedure TWorkspaceIndex.Clear;
begin
  FCache.Clear;
end;

procedure TWorkspaceIndex.InvalidateFile(const FilePath: String);
var
  Idx: Integer;
begin
  Idx := FCache.IndexOf(FilePath);
  if Idx >= 0 then
    FCache.Delete(Idx);
end;

function TWorkspaceIndex.GetFileModTime(const FilePath: String): TDateTime;
begin
  Result := 0;
  if FileExists(FilePath) then
    Result := FileDateToDateTime(FileAge(FilePath));
end;

function TWorkspaceIndex.ParseFileDeclarations(const FilePath: String): TWorkspaceCachedDeclArray;
var
  Parser: TCodeParser;
  Content: String;
  Decls: TDeclarationArray;
  Decl: TDeclaration;
  I, Count: Integer;
begin
  SetLength(Result, 0);

  Content := TSimbaFile.FileRead(FilePath);
  if Content = '' then
    Exit;

  Parser := TCodeParser.Create;
  try
    try
      Parser.SetScript(Content, FilePath);
      Parser.Run;

      Decls := Parser.Items.ToArray;
      SetLength(Result, Length(Decls));
      Count := 0;

      for I := 0 to High(Decls) do
      begin
        Decl := Decls[I];
        if (Decl.Name = '') or (Decl.DocPos.FileName <> FilePath) then
          Continue;

        Result[Count].Name := Decl.Name;
        Result[Count].Line := Decl.DocPos.Line;
        Result[Count].Col := Decl.DocPos.Col;
        Result[Count].FilePath := FilePath;

        if Decl is TDeclaration_Method then
          Result[Count].Kind := LSP_SK_FUNCTION
        else if Decl is TDeclaration_Type then
          Result[Count].Kind := LSP_SK_CLASS
        else if Decl is TDeclaration_Const then
          Result[Count].Kind := LSP_SK_CONSTANT
        else if Decl is TDeclaration_Var then
          Result[Count].Kind := LSP_SK_VARIABLE
        else
          Result[Count].Kind := LSP_SK_VARIABLE;

        Inc(Count);
      end;

      SetLength(Result, Count);
    except
      // Parse error - return empty array
      SetLength(Result, 0);
    end;
  finally
    Parser.Free;
  end;
end;

procedure TWorkspaceIndex.EnsureFileCached(const FilePath: String);
var
  Idx: Integer;
  Entry: TFileCacheEntry;
  CurrentModTime: TDateTime;
begin
  CurrentModTime := GetFileModTime(FilePath);
  if CurrentModTime = 0 then
    Exit; // File doesn't exist

  Idx := FCache.IndexOf(FilePath);

  if Idx >= 0 then
  begin
    Entry := FCache.Data[Idx];
    if Entry.ModifiedTime = CurrentModTime then
      Exit; // Cache is valid
  end;

  // Parse and cache
  Entry.FilePath := FilePath;
  Entry.ModifiedTime := CurrentModTime;
  Entry.Declarations := ParseFileDeclarations(FilePath);

  if Idx >= 0 then
    FCache.Data[Idx] := Entry
  else
    FCache.Add(FilePath, Entry);
end;

function TWorkspaceIndex.Search(const Query: String): TWorkspaceCachedDeclArray;
var
  Files: TStringList;
  I, J, Count: Integer;
  Entry: TFileCacheEntry;
  LowerQuery: String;
  Idx: Integer;
begin
  SetLength(Result, 0);
  if FWorkspaceRoot = '' then
    Exit;

  LowerQuery := LowerCase(Query);
  Count := 0;

  Files := FindSimbaFiles(FWorkspaceRoot);
  try
    // Pre-allocate reasonable size
    SetLength(Result, MAX_RESULTS);

    for I := 0 to Files.Count - 1 do
    begin
      EnsureFileCached(Files[I]);

      Idx := FCache.IndexOf(Files[I]);
      if Idx < 0 then
        Continue;

      Entry := FCache.Data[Idx];

      for J := 0 to High(Entry.Declarations) do
      begin
        // Match if query is empty or substring matches
        if (Query = '') or (Pos(LowerQuery, LowerCase(Entry.Declarations[J].Name)) > 0) then
        begin
          if Count >= Length(Result) then
            SetLength(Result, Length(Result) * 2);

          Result[Count] := Entry.Declarations[J];
          Inc(Count);

          if Count >= MAX_RESULTS then
            Break;
        end;
      end;

      if Count >= MAX_RESULTS then
        Break;
    end;

    SetLength(Result, Count);
  finally
    Files.Free;
  end;
end;

end.

{
  Author: Raymond van Venetië and Merlijn Wajer
  Project: Simba (https://github.com/MerlijnWajer/Simba)
  License: GNU General Public License (https://www.gnu.org/licenses/gpl-3.0)

  LSP Server implementation for Simba.
  Communicates via stdin/stdout using JSON-RPC 2.0.

  Can be built standalone without full Simba IDE dependencies.
}
unit simba.lsp_server;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson, jsonparser,
  simba.lsp_types,
  simba.lsp_workspace,
  simba.ide_codetools_parser,
  simba.ide_codetools_paslexer;

type
  // Error categories for code action matching (Phase 1)
  TDiagnosticErrorCategory = (
    ecUnknown,                   // Unrecognized error
    ecMissingParens,             // Function used without () - "Can't assign function to Type", etc.
    ecExtraParens,               // Property called with () - "Cannot invoke property like this"
    ecPointerWhereVarExpected,   // @Obj passed to var param - "Don't know which overloaded method"
    ecUnknownDeclaration,        // Typo or missing include - "Unknown declaration X"
    ecTooManyParams,             // Old API signature - "Too many parameters"
    ecTypeMismatch               // Type incompatibility
  );

  TDiagnosticErrorInfo = record
    RawMessage: String;          // Original formatted message from codetools
    Message: String;             // Extracted human-readable message
    Category: TDiagnosticErrorCategory;
    Line: Integer;               // 1-based line (0 if unknown)
    Col: Integer;                // 1-based column (0 if unknown)
    FileName: String;            // Source file (empty if current)
  end;
  TDiagnosticErrorInfoArray = array of TDiagnosticErrorInfo;

  TSimbaLSPServer = class
  private
    FDocuments: TStringList;
    FInitialized: Boolean;
    FShutdown: Boolean;
    FSimbaPath: String;
    FBaseDeclarations: String;
    FDiagnosticErrors: TDiagnosticErrorInfoArray;
    FDiagnosticURI: String;
    FWorkspaceIndex: TWorkspaceIndex;

    procedure LogMessage(const Msg: String);
    procedure SendResponse(const ID: TJSONData; const Result: TJSONData);
    procedure SendError(const ID: TJSONData; Code: Integer; const Msg: String);
    procedure SendNotification(const Method: String; const Params: TJSONData);
    procedure PublishDiagnostics(const URI: String; const Diagnostics: TLSPDiagnosticArray);

    function ReadMessage: String;
    procedure WriteMessage(const Msg: String);

    procedure HandleInitialize(const ID: TJSONData; const Params: TJSONObject);
    procedure HandleInitialized(const Params: TJSONObject);
    procedure HandleShutdown(const ID: TJSONData);
    procedure HandleExit;
    procedure HandleTextDocumentDidOpen(const Params: TJSONObject);
    procedure HandleTextDocumentDidChange(const Params: TJSONObject);
    procedure HandleTextDocumentDidClose(const Params: TJSONObject);
    procedure HandleTextDocumentDidSave(const Params: TJSONObject);
    procedure HandleTextDocumentCompletion(const ID: TJSONData; const Params: TJSONObject);
    procedure HandleTextDocumentHover(const ID: TJSONData; const Params: TJSONObject);
    procedure HandleTextDocumentDefinition(const ID: TJSONData; const Params: TJSONObject);
    procedure HandleTextDocumentSignatureHelp(const ID: TJSONData; const Params: TJSONObject);
    procedure HandleTextDocumentDocumentSymbol(const ID: TJSONData; const Params: TJSONObject);
    procedure HandleTextDocumentFormatting(const ID: TJSONData; const Params: TJSONObject);
    procedure HandleTextDocumentSemanticTokensFull(const ID: TJSONData; const Params: TJSONObject);
    procedure HandleTextDocumentReferences(const ID: TJSONData; const Params: TJSONObject);
    procedure HandleTextDocumentFoldingRange(const ID: TJSONData; const Params: TJSONObject);
    procedure HandleTextDocumentRename(const ID: TJSONData; const Params: TJSONObject);
    procedure HandleTextDocumentTypeDefinition(const ID: TJSONData; const Params: TJSONObject);
    procedure HandleWorkspaceSymbol(const ID: TJSONData; const Params: TJSONObject);
    procedure HandleTextDocumentCodeAction(const ID: TJSONData; const Params: TJSONObject);
    procedure HandleTextDocumentInlayHint(const ID: TJSONData; const Params: TJSONObject);

    function GetDocumentContent(const URI: String): String;
    procedure SetDocumentContent(const URI: String; const Content: String);

    // Helper methods to reduce code duplication
    function CalculateCaretPosition(const Content: String; Line, Character: Integer): Integer;
    function ExtractWordAtPosition(const Content: String; CaretPos: Integer; out WordStart, WordEnd: Integer): String;
    function ParseMemberAccessExpression(const Content: String; CaretPos: Integer; out Expr: String; out DotPos: Integer): Boolean;
    function GetCompletionItemKind(Decl: TDeclaration): TLSPCompletionItemKind;
    function CreateLocationResponse(const URI, FilePath, Word: String; const DocPos: TDocPos): TJSONData;

    procedure SetupKeywords;
    procedure LoadBaseDeclarations;
    procedure RunDiagnostics(const URI: String);
    procedure HandleCodetoolsError(const Msg: String);
    function ClassifyError(const Msg: String): TDiagnosticErrorCategory;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Run;

    property SimbaPath: String read FSimbaPath write FSimbaPath;
  end;

procedure RunLSPServer;
procedure RunCheckMode(const ScriptPath: String);

implementation

uses
  Math, Process,
  simba.ide_codetools_insight,
  simba.ide_codetools_base,
  simba.initializations,
  simba.env,
  simba.simpleformatter,
  simba.lsp_utils;

const
  // Lape/Simba keywords for autocompletion
  Lape_Keywords: array[0..57] of String = (
    'and', 'div', 'in', 'is', 'mod', 'not', 'or', 'shl', 'shr', 'xor', 'at', 'array',
    'begin', 'case', 'const', 'constref', 'deprecated', 'do', 'downto', 'else', 'end',
    'enum', 'except', 'experimental', 'external', 'finally', 'for', 'forward', 'function',
    'if', 'label', 'object', 'operator', 'of', 'out', 'overload', 'override', 'packed',
    'private', 'procedure', 'program', 'property', 'record', 'repeat', 'set', 'static',
    'strict', 'then', 'to', 'try', 'type', 'union', 'unimplemented', 'until', 'var',
    'while', 'with', 'nil'
  );

var
  LSPKeywords: TDeclarationArray;
  CodetoolsInitialized: Boolean = False;

function FormatDeclaredIn(const FileName: String): String;
begin
  // Format the source name for display
  if FileName = '' then
    Result := 'Simba (internal)'
  else if FileName = '!Simba' then
    Result := 'Simba IDE (internal)'
  else if (Pos(PathDelim, FileName) = 0) and (Pos('/', FileName) = 0) and (Pos('\', FileName) = 0) then
    // Section name like "Base", "Math", "System" - no path separators
    Result := 'Simba: ' + FileName
  else
    Result := FileName;
end;

procedure InitializeCodetools;
begin
  if not CodetoolsInitialized then
  begin
    // Call initialization hooks registered by codetools units
    // This creates CodetoolsIncludes and other required global objects
    SimbaInitialization_Call(ESimbaInit.IDE_BEFORE_CREATE);
    CodetoolsInitialized := True;
  end;
end;

procedure RunLSPServer;
var
  Server: TSimbaLSPServer;
begin
  InitializeCodetools;
  Server := TSimbaLSPServer.Create;
  try
    Server.Run;
  finally
    Server.Free;
    // Cleanup
    SimbaInitialization_Call(ESimbaInit.IDE_DESTROY);
  end;
end;

type
  { Helper class to collect codetools errors for --check mode }
  TCheckModeErrorCollector = class
    Errors: TStringList;
    procedure HandleError(const Msg: String);
    constructor Create;
    destructor Destroy; override;
  end;

constructor TCheckModeErrorCollector.Create;
begin
  inherited;
  Errors := TStringList.Create;
end;

destructor TCheckModeErrorCollector.Destroy;
begin
  Errors.Free;
  inherited;
end;

procedure TCheckModeErrorCollector.HandleError(const Msg: String);
begin
  Errors.Add(Msg);
end;

procedure RunCheckMode(const ScriptPath: String);
var
  Codeinsight: TCodeinsight;
  Collector: TCheckModeErrorCollector;
  Content: String;
  FileContent: TStringList;
  I, ErrorCount: Integer;
begin
  if not FileExists(ScriptPath) then
  begin
    WriteLn(StdErr, 'Error: File not found: ' + ScriptPath);
    Halt(2);
  end;

  InitializeCodetools;
  ErrorCount := 0;

  Collector := TCheckModeErrorCollector.Create;
  try
    SetCodetoolsMessageHandler(@Collector.HandleError);

    // Read script file
    FileContent := TStringList.Create;
    try
      FileContent.LoadFromFile(ScriptPath);
      Content := FileContent.Text;
    finally
      FileContent.Free;
    end;

    // Parse the script to collect errors
    Codeinsight := TCodeinsight.Create;
    try
      Codeinsight.SetScript(Content, ExpandFileName(ScriptPath), -1);
      Codeinsight.Run;
    finally
      Codeinsight.Free;
    end;

    SetCodetoolsMessageHandler(nil);

    // Output results
    ErrorCount := Collector.Errors.Count;
    if ErrorCount > 0 then
    begin
      for I := 0 to Collector.Errors.Count - 1 do
        WriteLn(Collector.Errors[I]);
      WriteLn(IntToStr(ErrorCount) + ' error(s) in ' + ScriptPath);
    end
    else
      WriteLn(ScriptPath + ': OK');

  finally
    Collector.Free;
    SimbaInitialization_Call(ESimbaInit.IDE_DESTROY);
  end;

  if ErrorCount > 0 then
    Halt(1)
  else
    Halt(0);
end;

procedure TSimbaLSPServer.SetupKeywords;
var
  I: Integer;
begin
  SetLength(LSPKeywords, Length(Lape_Keywords));
  for I := 0 to High(Lape_Keywords) do
    LSPKeywords[I] := TDeclaration_Keyword.Create(Lape_Keywords[I]);
end;

constructor TSimbaLSPServer.Create;
begin
  inherited Create;
  FDocuments := TStringList.Create;
  FDocuments.OwnsObjects := False;
  SetLength(FDiagnosticErrors, 0);
  FDiagnosticURI := '';
  FWorkspaceIndex := TWorkspaceIndex.Create;
  FInitialized := False;
  FShutdown := False;
  FSimbaPath := '';
  FBaseDeclarations := '';
  SetupKeywords;
  SetCodetoolsMessageHandler(@HandleCodetoolsError);
end;

destructor TSimbaLSPServer.Destroy;
var
  I: Integer;
begin
  SetCodetoolsMessageHandler(nil);
  for I := 0 to FDocuments.Count - 1 do
    TStringList(FDocuments.Objects[I]).Free;
  FDocuments.Free;
  FWorkspaceIndex.Free;
  SetLength(FDiagnosticErrors, 0);
  inherited Destroy;
end;

procedure TSimbaLSPServer.LogMessage(const Msg: String);
var
  Params: TJSONObject;
begin
  Params := TJSONObject.Create;
  try
    Params.Add('type', 4); // Log
    Params.Add('message', Msg);
    SendNotification('window/logMessage', Params);
  finally
    Params.Free;
  end;
end;

function TSimbaLSPServer.ReadMessage: String;
var
  Header, Line: String;
  ContentLength: Integer;
  Buffer: array of Char;
  I: Integer;
begin
  Result := '';
  ContentLength := 0;

  // Read headers
  repeat
    ReadLn(Header);
    if Pos('Content-Length:', Header) = 1 then
    begin
      Delete(Header, 1, 15);
      Header := Trim(Header);
      ContentLength := StrToIntDef(Header, 0);
    end;
  until Header = '';

  if ContentLength > 0 then
  begin
    SetLength(Buffer, ContentLength);
    for I := 0 to ContentLength - 1 do
      Read(Buffer[I]);
    SetString(Result, PChar(@Buffer[0]), ContentLength);
  end;
end;

procedure TSimbaLSPServer.WriteMessage(const Msg: String);
var
  Header: String;
begin
  Header := 'Content-Length: ' + IntToStr(Length(Msg)) + #13#10 + #13#10;
  Write(Header);
  Write(Msg);
  Flush(Output);
end;

procedure TSimbaLSPServer.SendResponse(const ID: TJSONData; const Result: TJSONData);
var
  Response: TJSONObject;
begin
  Response := TJSONObject.Create;
  try
    Response.Add('jsonrpc', '2.0');
    if Assigned(ID) then
      Response.Add('id', ID.Clone)
    else
      Response.Add('id', TJSONNull.Create);
    if Assigned(Result) then
      Response.Add('result', Result)
    else
      Response.Add('result', TJSONNull.Create);
    WriteMessage(Response.AsJSON);
  finally
    Response.Free;
  end;
end;

procedure TSimbaLSPServer.SendError(const ID: TJSONData; Code: Integer; const Msg: String);
var
  Response, Error: TJSONObject;
begin
  Response := TJSONObject.Create;
  Error := TJSONObject.Create;
  try
    Response.Add('jsonrpc', '2.0');
    if Assigned(ID) then
      Response.Add('id', ID.Clone)
    else
      Response.Add('id', TJSONNull.Create);
    Error.Add('code', Code);
    Error.Add('message', Msg);
    Response.Add('error', Error);
    WriteMessage(Response.AsJSON);
  finally
    Response.Free;
  end;
end;

procedure TSimbaLSPServer.SendNotification(const Method: String; const Params: TJSONData);
var
  Notification: TJSONObject;
begin
  Notification := TJSONObject.Create;
  try
    Notification.Add('jsonrpc', '2.0');
    Notification.Add('method', Method);
    if Assigned(Params) then
      Notification.Add('params', Params.Clone);
    WriteMessage(Notification.AsJSON);
  finally
    Notification.Free;
  end;
end;

procedure TSimbaLSPServer.PublishDiagnostics(const URI: String; const Diagnostics: TLSPDiagnosticArray);
var
  Params: TJSONObject;
  DiagArray: TJSONArray;
  I: Integer;
begin
  Params := TJSONObject.Create;
  DiagArray := TJSONArray.Create;
  try
    for I := 0 to High(Diagnostics) do
      DiagArray.Add(DiagnosticToJSON(Diagnostics[I]));
    Params.Add('uri', URI);
    Params.Add('diagnostics', DiagArray);
    SendNotification('textDocument/publishDiagnostics', Params);
  finally
    Params.Free;
  end;
end;

procedure TSimbaLSPServer.LoadBaseDeclarations;
var
  SimbaExe, DumpFile: String;
  DumpList: TStringList;
  Parser: TCodeParser;
  I: Integer;
  AProcess: TProcess;

  function FindSimbaExecutable: String;
  const
    {$IFDEF WINDOWS}
    SimbaExeName = 'Simba.exe';
    {$ELSE}
    SimbaExeName = 'Simba';
    {$ENDIF}
  var
    ExePath, ExeName: String;
  begin
    ExePath := ParamStr(0);
    ExeName := LowerCase(ExtractFileName(ExePath));

    // Check if we ARE the full Simba (running with --lsp flag)
    // But NOT if we're SimbaLSP (standalone LSP binary)
    if (Pos('simba', ExeName) > 0) and (Pos('lsp', ExeName) = 0) then
      Exit(ExePath);

    // Check alongside this executable
    Result := ExtractFilePath(ExePath) + SimbaExeName;
    if FileExists(Result) then
      Exit;

    // Check parent directory
    Result := ExtractFilePath(ExcludeTrailingPathDelimiter(ExtractFilePath(ExePath))) + SimbaExeName;
    if FileExists(Result) then
      Exit;

    // Not found
    Result := '';
  end;

begin
  // Find the Simba executable to get built-in declarations
  SimbaExe := FindSimbaExecutable;
  if SimbaExe = '' then
  begin
    LogMessage('Simba executable not found - built-in functions will not be available');
    Exit;
  end;

  // Use the dumps path from SimbaEnv
  DumpFile := SimbaEnv.DumpsPath + 'compiler_dump.txt';

  // If dump file doesn't exist, regenerate it
  if not FileExists(DumpFile) then
  begin
    LogMessage('Generating compiler dump from: ' + SimbaExe);

    AProcess := TProcess.Create(nil);
    try
      AProcess.Executable := SimbaExe;
      AProcess.Parameters.Add('--dumpcompiler');
      AProcess.Parameters.Add(DumpFile);
      AProcess.Options := [poWaitOnExit, poUsePipes, poNoConsole];

      try
        AProcess.Execute;
      except
        on E: Exception do
        begin
          LogMessage('Failed to run Simba: ' + E.Message);
          Exit;
        end;
      end;
    finally
      AProcess.Free;
    end;
  end;

  // Load the dump file
  if not FileExists(DumpFile) then
  begin
    LogMessage('Dump file not created: ' + DumpFile);
    Exit;
  end;

  DumpList := TStringList.Create;
  try
    DumpList.LineBreak := #0;  // Simba uses null as separator
    DumpList.LoadFromFile(DumpFile);

    LogMessage('Loading ' + IntToStr(DumpList.Count) + ' declaration sections');

    for I := 0 to DumpList.Count - 1 do
    begin
      if (DumpList.Names[I] = '') then
        Continue;

      Parser := TCodeParser.Create();
      Parser.SetScript(DumpList.ValueFromIndex[I], DumpList.Names[I]);
      Parser.Run();

      TCodeinsight.AddBaseParser(Parser);
    end;

    LogMessage('Built-in declarations loaded successfully');
  except
    on E: Exception do
      LogMessage('Error loading base declarations: ' + E.Message);
  end;

  DumpList.Free;
end;

function TSimbaLSPServer.ClassifyError(const Msg: String): TDiagnosticErrorCategory;
begin
  // Match known error patterns to categories for code action generation
  if Pos('Cannot invoke property', Msg) > 0 then
    Result := ecExtraParens
  else if (Pos('Can''t assign function to', Msg) > 0) or
          (Pos('Cannot be evaluated at runtime', Msg) > 0) or
          (Pos('Operator NOT not compatible with function', Msg) > 0) or
          (Pos('not compatible with function', Msg) > 0) then
    Result := ecMissingParens
  else if Pos('Unknown declaration', Msg) > 0 then
    Result := ecUnknownDeclaration
  else if Pos('Too many parameters', Msg) > 0 then
    Result := ecTooManyParams
  else if Pos('Don''t know which overloaded method', Msg) > 0 then
    Result := ecPointerWhereVarExpected
  else if (Pos('Expected type', Msg) > 0) or
          (Pos('not compatible with', Msg) > 0) then
    Result := ecTypeMismatch
  else
    Result := ecUnknown;
end;

procedure TSimbaLSPServer.HandleCodetoolsError(const Msg: String);
var
  Info: TDiagnosticErrorInfo;
  P1, P2, SearchStart: Integer;

  function RPosFrom(const SubStr, S: String; StartPos: Integer): Integer;
  var
    J: Integer;
  begin
    Result := 0;
    for J := StartPos downto 1 do
      if Copy(S, J, Length(SubStr)) = SubStr then
      begin
        Result := J;
        Exit;
      end;
  end;

begin
  Info.RawMessage := Msg;
  Info.Message := Msg;
  Info.Category := ecUnknown;
  Info.Line := 0;
  Info.Col := 0;
  Info.FileName := '';

  // Parse structured error format: "message" at line X, column Y [in file "Z"]
  SearchStart := Length(Msg);
  P1 := Pos(' in file "', Msg);
  if P1 > 0 then
  begin
    // Extract filename between quotes after ' in file "'
    Info.FileName := Copy(Msg, P1 + 10, Length(Msg) - P1 - 10);
    SearchStart := P1 - 1;
  end;

  P1 := RPosFrom('" at line ', Msg, SearchStart);
  if P1 > 0 then
  begin
    // Extract message text (between first and last quotes)
    if (Length(Msg) > 0) and (Msg[1] = '"') then
      Info.Message := Copy(Msg, 2, P1 - 2);

    // Extract line number
    P2 := P1 + 10;
    while (P2 <= Length(Msg)) and (Msg[P2] in ['0'..'9']) do
      Inc(P2);
    Info.Line := StrToIntDef(Copy(Msg, P1 + 10, P2 - P1 - 10), 0);

    // Extract column number
    P1 := Pos(', column ', Copy(Msg, P2, Length(Msg)));
    if P1 > 0 then
    begin
      P1 := P1 + P2 - 1;
      P2 := P1 + 9;
      while (P2 <= Length(Msg)) and (Msg[P2] in ['0'..'9']) do
        Inc(P2);
      Info.Col := StrToIntDef(Copy(Msg, P1 + 9, P2 - P1 - 9), 0);
    end;
  end;

  Info.Category := ClassifyError(Info.Message);

  SetLength(FDiagnosticErrors, Length(FDiagnosticErrors) + 1);
  FDiagnosticErrors[High(FDiagnosticErrors)] := Info;
end;

procedure TSimbaLSPServer.RunDiagnostics(const URI: String);
var
  Content, FilePath: String;
  Codeinsight: TCodeinsight;
  Diagnostics: TLSPDiagnosticArray;
  I, Line, Col: Integer;
  Diag: TLSPDiagnostic;
  Info: TDiagnosticErrorInfo;
begin
  Content := GetDocumentContent(URI);
  FilePath := URIToFilePath(URI);

  // Clear previous errors and set current URI for error handler
  SetLength(FDiagnosticErrors, 0);
  FDiagnosticURI := URI;

  // Parse the document to collect errors (HandleCodetoolsError populates FDiagnosticErrors)
  Codeinsight := TCodeinsight.Create;
  try
    Codeinsight.SetScript(Content, FilePath, -1);
    Codeinsight.Run;
  finally
    Codeinsight.Free;
  end;

  // Convert structured error info to LSP diagnostics
  SetLength(Diagnostics, Length(FDiagnosticErrors));
  for I := 0 to High(FDiagnosticErrors) do
  begin
    Info := FDiagnosticErrors[I];
    Line := Info.Line;
    Col := Info.Col;

    Diag.Range := CreateRange(Max(0, Line - 1), Max(0, Col - 1),
                              Max(0, Line - 1), Max(0, Col - 1) + 10);
    Diag.Severity := DiagError;
    Diag.Message := Info.Message;
    Diag.Source := 'simba';

    Diagnostics[I] := Diag;
  end;

  // Publish diagnostics (empty array clears previous diagnostics)
  PublishDiagnostics(URI, Diagnostics);
  // Note: FDiagnosticErrors is kept until next RunDiagnostics call for code action use
end;

function TSimbaLSPServer.GetDocumentContent(const URI: String): String;
var
  Idx: Integer;
begin
  Result := '';
  Idx := FDocuments.IndexOf(URI);
  if Idx >= 0 then
    Result := TStringList(FDocuments.Objects[Idx]).Text;
end;

procedure TSimbaLSPServer.SetDocumentContent(const URI: String; const Content: String);
var
  Idx: Integer;
  DocContent: TStringList;
begin
  Idx := FDocuments.IndexOf(URI);
  if Idx >= 0 then
  begin
    TStringList(FDocuments.Objects[Idx]).Text := Content;
  end
  else
  begin
    DocContent := TStringList.Create;
    DocContent.Text := Content;
    FDocuments.AddObject(URI, DocContent);
  end;
end;

function TSimbaLSPServer.CalculateCaretPosition(const Content: String; Line, Character: Integer): Integer;
begin
  Result := LSPCalculateCaretPosition(Content, Line, Character);
end;

function TSimbaLSPServer.ExtractWordAtPosition(const Content: String; CaretPos: Integer; out WordStart, WordEnd: Integer): String;
begin
  Result := LSPExtractWordAtPosition(Content, CaretPos, WordStart, WordEnd);
end;

function TSimbaLSPServer.ParseMemberAccessExpression(const Content: String; CaretPos: Integer; out Expr: String; out DotPos: Integer): Boolean;
begin
  Result := LSPParseMemberAccessExpression(Content, CaretPos, Expr, DotPos);
end;

function TSimbaLSPServer.GetCompletionItemKind(Decl: TDeclaration): TLSPCompletionItemKind;
begin
  if Decl is TDeclaration_Method then
    Result := cikFunction
  else if Decl is TDeclaration_Type then
    Result := cikClass
  else if Decl is TDeclaration_Const then
    Result := cikConstant
  else if Decl is TDeclaration_EnumElement then
    Result := cikEnumMember
  else if Decl is TDeclaration_Field then
    Result := cikField
  else if Decl is TDeclaration_Property then
    Result := cikProperty
  else
    Result := cikVariable;
end;

function TSimbaLSPServer.CreateLocationResponse(const URI, FilePath, Word: String; const DocPos: TDocPos): TJSONData;
var
  Location: TLSPLocation;
  IsSameFile: Boolean;
begin
  // Check if we have valid file position info
  if (DocPos.FileName = '') or (DocPos.Line <= 0) then
  begin
    // Built-in declaration without file position - show info in output
    LogMessage('Declared in: ' + FormatDeclaredIn(DocPos.FileName));
    Result := TJSONNull.Create;
    Exit;
  end;

  // Check if declaration is in the same file (case-insensitive on Windows)
  {$IFDEF WINDOWS}
  IsSameFile := SameText(DocPos.FileName, FilePath);
  {$ELSE}
  IsSameFile := (DocPos.FileName = FilePath);
  {$ENDIF}

  if IsSameFile then
  begin
    Location.URI := URI;
    Location.Range := CreateRange(
      DocPos.Line - 1,
      Max(0, DocPos.Col - 1),
      DocPos.Line - 1,
      Max(0, DocPos.Col - 1) + Length(Word)
    );
    Result := LocationToJSON(Location);
  end
  else if FileExists(DocPos.FileName) then
  begin
    Location.URI := FilePathToURI(DocPos.FileName);
    Location.Range := CreateRange(
      DocPos.Line - 1,
      Max(0, DocPos.Col - 1),
      DocPos.Line - 1,
      Max(0, DocPos.Col - 1) + Length(Word)
    );
    Result := LocationToJSON(Location);
  end
  else
  begin
    // File doesn't exist (built-in declaration) - show info in output
    LogMessage('Declared in: ' + FormatDeclaredIn(DocPos.FileName));
    Result := TJSONNull.Create;
  end;
end;

procedure TSimbaLSPServer.HandleInitialize(const ID: TJSONData; const Params: TJSONObject);
var
  Result, Capabilities, CompletionProvider, SignatureProvider: TJSONObject;
  SemanticProvider, SemanticLegend: TJSONObject;
  TriggerChars, TokenTypes, TokenModifiers: TJSONArray;
  TokenType: TLSPSemanticTokenType;
  TokenMod: TLSPSemanticTokenModifier;
  RootUri, RootPath: String;
begin
  // Extract workspace root from initialize params
  RootUri := Params.Get('rootUri', '');
  if RootUri <> '' then
  begin
    RootPath := URIToFilePath(RootUri);
    FWorkspaceIndex.SetWorkspaceRoot(RootPath);
    LogMessage('Workspace root: ' + RootPath);
  end;

  Result := TJSONObject.Create;
  Capabilities := TJSONObject.Create;
  try
    // Text document sync - full sync
    Capabilities.Add('textDocumentSync', 1);

    // Completion support
    CompletionProvider := TJSONObject.Create;
    TriggerChars := TJSONArray.Create;
    TriggerChars.Add('.');
    CompletionProvider.Add('triggerCharacters', TriggerChars);
    CompletionProvider.Add('resolveProvider', False);
    Capabilities.Add('completionProvider', CompletionProvider);

    // Hover support
    Capabilities.Add('hoverProvider', True);

    // Go to definition
    Capabilities.Add('definitionProvider', True);

    // Signature help
    SignatureProvider := TJSONObject.Create;
    TriggerChars := TJSONArray.Create;
    TriggerChars.Add('(');
    TriggerChars.Add(',');
    SignatureProvider.Add('triggerCharacters', TriggerChars);
    Capabilities.Add('signatureHelpProvider', SignatureProvider);

    // Document symbols
    Capabilities.Add('documentSymbolProvider', True);

    // Formatting
    Capabilities.Add('documentFormattingProvider', True);

    // Find references
    Capabilities.Add('referencesProvider', True);

    // Code folding
    Capabilities.Add('foldingRangeProvider', True);

    // Rename
    Capabilities.Add('renameProvider', True);

    // Type definition
    Capabilities.Add('typeDefinitionProvider', True);

    // Workspace symbols
    Capabilities.Add('workspaceSymbolProvider', True);

    // Code actions (quick fixes)
    Capabilities.Add('codeActionProvider', TJSONObject.Create([
      'codeActionKinds', TJSONArray.Create(['quickfix'])
    ]));

    // Inlay hints (parameter names)
    Capabilities.Add('inlayHintProvider', TJSONObject.Create([
      'resolveProvider', False
    ]));

    // Semantic tokens support
    SemanticProvider := TJSONObject.Create;
    SemanticLegend := TJSONObject.Create;

    // Build token types array
    TokenTypes := TJSONArray.Create;
    for TokenType := Low(TLSPSemanticTokenType) to High(TLSPSemanticTokenType) do
      TokenTypes.Add(SemanticTokenTypeNames[TokenType]);
    SemanticLegend.Add('tokenTypes', TokenTypes);

    // Build token modifiers array
    TokenModifiers := TJSONArray.Create;
    for TokenMod := Low(TLSPSemanticTokenModifier) to High(TLSPSemanticTokenModifier) do
      TokenModifiers.Add(SemanticTokenModifierNames[TokenMod]);
    SemanticLegend.Add('tokenModifiers', TokenModifiers);

    SemanticProvider.Add('legend', SemanticLegend);
    SemanticProvider.Add('full', True);  // We support full document semantic tokens
    Capabilities.Add('semanticTokensProvider', SemanticProvider);

    Result.Add('capabilities', Capabilities);

    // Server info
    Result.Add('serverInfo', TJSONObject.Create(['name', 'simba-lsp', 'version', '1.0.0']));

    SendResponse(ID, Result);
  except
    on E: Exception do
      SendError(ID, -32603, 'Initialize failed: ' + E.Message);
  end;
end;

procedure TSimbaLSPServer.HandleInitialized(const Params: TJSONObject);
begin
  FInitialized := True;
  LoadBaseDeclarations;
  LogMessage('Simba LSP Server initialized');
  LogMessage('Capabilities: completion, hover, definition, signatureHelp, documentSymbol, diagnostics, semanticTokens, references, foldingRange, rename, typeDefinition, workspaceSymbol, formatting, codeAction, inlayHint');
end;

procedure TSimbaLSPServer.HandleShutdown(const ID: TJSONData);
begin
  FShutdown := True;
  SendResponse(ID, TJSONNull.Create);
end;

procedure TSimbaLSPServer.HandleExit;
begin
  if FShutdown then
    Halt(0)
  else
    Halt(1);
end;

procedure TSimbaLSPServer.HandleTextDocumentDidOpen(const Params: TJSONObject);
var
  TextDocument: TJSONObject;
  URI, Content: String;
begin
  TextDocument := Params.Get('textDocument', TJSONObject(nil));
  if Assigned(TextDocument) then
  begin
    URI := TextDocument.Get('uri', '');
    Content := TextDocument.Get('text', '');
    SetDocumentContent(URI, Content);

    // Run diagnostics on the opened document
    RunDiagnostics(URI);
  end;
end;

procedure TSimbaLSPServer.HandleTextDocumentDidChange(const Params: TJSONObject);
var
  TextDocument: TJSONObject;
  ContentChanges: TJSONArray;
  URI, Content: String;
begin
  TextDocument := Params.Get('textDocument', TJSONObject(nil));
  ContentChanges := Params.Get('contentChanges', TJSONArray(nil));

  if Assigned(TextDocument) and Assigned(ContentChanges) and (ContentChanges.Count > 0) then
  begin
    URI := TextDocument.Get('uri', '');
    // Full sync mode - get the full text from the last change
    Content := TJSONObject(ContentChanges.Items[ContentChanges.Count - 1]).Get('text', '');
    SetDocumentContent(URI, Content);

    // Run diagnostics on the changed document
    RunDiagnostics(URI);
  end;
end;

procedure TSimbaLSPServer.HandleTextDocumentDidClose(const Params: TJSONObject);
var
  TextDocument: TJSONObject;
  URI: String;
  Idx: Integer;
  EmptyDiag: TLSPDiagnosticArray;
begin
  TextDocument := Params.Get('textDocument', TJSONObject(nil));
  if Assigned(TextDocument) then
  begin
    URI := TextDocument.Get('uri', '');
    Idx := FDocuments.IndexOf(URI);
    if Idx >= 0 then
    begin
      TStringList(FDocuments.Objects[Idx]).Free;
      FDocuments.Delete(Idx);
    end;

    // Clear diagnostics for the closed document
    SetLength(EmptyDiag, 0);
    PublishDiagnostics(URI, EmptyDiag);
  end;
end;

procedure TSimbaLSPServer.HandleTextDocumentDidSave(const Params: TJSONObject);
begin
  // No action needed - document content is already synchronized via didChange events.
  // This handler exists because the LSP protocol requires acknowledging save notifications,
  // but we use full document sync mode so content is always up-to-date.
end;

procedure TSimbaLSPServer.HandleTextDocumentCompletion(const ID: TJSONData; const Params: TJSONObject);
var
  TextDocument, Position: TJSONObject;
  URI, Content, FilePath, Expr: String;
  Line, Character, CaretPos, I, DotPos: Integer;
  Codeinsight: TCodeinsight;
  Decls, Members: TDeclarationArray;
  Items: TJSONArray;
  Item: TLSPCompletionItem;
  Decl, ExprDecl: TDeclaration;
  IsMemberCompletion: Boolean;
begin
  TextDocument := Params.Get('textDocument', TJSONObject(nil));
  Position := Params.Get('position', TJSONObject(nil));

  if not Assigned(TextDocument) or not Assigned(Position) then
  begin
    SendResponse(ID, TJSONArray.Create);
    Exit;
  end;

  URI := TextDocument.Get('uri', '');
  Line := Position.Get('line', 0);
  Character := Position.Get('character', 0);
  Content := GetDocumentContent(URI);
  FilePath := URIToFilePath(URI);

  Items := TJSONArray.Create;
  try
    CaretPos := CalculateCaretPosition(Content, Line, Character);
    IsMemberCompletion := ParseMemberAccessExpression(Content, CaretPos, Expr, DotPos);

    Codeinsight := TCodeinsight.Create;
    try
      Codeinsight.SetScript(Content, FilePath, CaretPos);
      Codeinsight.Run;

      if IsMemberCompletion and (Expr <> '') then
      begin
        // Member completion - get members of the expression
        ExprDecl := Codeinsight.ParseExpr(Expr, Members);

        // If ExprDecl is a variable or method result, resolve to its type and get type members
        if Assigned(ExprDecl) then
        begin
          if ExprDecl is TDeclaration_Var then
            Members := Codeinsight.GetTypeMembers(
              Codeinsight.ResolveVarType(TDeclaration_Var(ExprDecl).VarType))
          else if (ExprDecl is TDeclaration_Method) and
                  Assigned(TDeclaration_Method(ExprDecl).ResultType) then
            Members := Codeinsight.GetTypeMembers(
              Codeinsight.ResolveVarType(TDeclaration_Method(ExprDecl).ResultType))
          else if ExprDecl is TDeclaration_Type then
            Members := Codeinsight.GetTypeMembers(ExprDecl as TDeclaration_Type);
        end;

        for I := 0 to High(Members) do
        begin
          Decl := Members[I];
          if Decl.Name <> '' then
          begin
            Item.LabelText := Decl.Name;
            Item.Detail := Decl.Header;
            Item.Documentation := '';
            Item.InsertText := Decl.Name;
            Item.Kind := GetCompletionItemKind(Decl);
            Items.Add(CompletionItemToJSON(Item));
          end;
        end;
      end
      else
      begin
        // Regular completion - show locals and globals
        Decls := Codeinsight.GetLocals;
        for I := 0 to High(Decls) do
        begin
          Decl := Decls[I];
          if Decl.Name <> '' then
          begin
            Item.LabelText := Decl.Name;
            Item.Detail := Decl.Header;
            Item.Documentation := '';
            Item.InsertText := Decl.Name;
            Item.Kind := GetCompletionItemKind(Decl);
            Items.Add(CompletionItemToJSON(Item));
          end;
        end;

        Decls := Codeinsight.GetGlobals;
        for I := 0 to High(Decls) do
        begin
          Decl := Decls[I];
          if Decl.Name <> '' then
          begin
            Item.LabelText := Decl.Name;
            Item.Detail := Decl.Header;
            Item.Documentation := '';
            Item.InsertText := Decl.Name;
            Item.Kind := GetCompletionItemKind(Decl);
            Items.Add(CompletionItemToJSON(Item));
          end;
        end;

        // Add keywords only for regular completion
        for I := 0 to High(LSPKeywords) do
        begin
          Item.LabelText := LSPKeywords[I].Name;
          Item.Kind := cikKeyword;
          Item.Detail := 'keyword';
          Item.Documentation := '';
          Item.InsertText := LSPKeywords[I].Name;
          Items.Add(CompletionItemToJSON(Item));
        end;
      end;

    finally
      Codeinsight.Free;
    end;

    SendResponse(ID, Items);
  except
    on E: Exception do
    begin
      LogMessage('Completion error: ' + E.Message);
      SendResponse(ID, TJSONArray.Create);
    end;
  end;
end;

procedure TSimbaLSPServer.HandleTextDocumentHover(const ID: TJSONData; const Params: TJSONObject);
var
  TextDocument, Position: TJSONObject;
  URI, Content, FilePath, Word: String;
  Line, Character, CaretPos, WordStart, WordEnd: Integer;
  Codeinsight: TCodeinsight;
  Decls: TDeclarationArray;
  Hover: TLSPHover;
begin
  TextDocument := Params.Get('textDocument', TJSONObject(nil));
  Position := Params.Get('position', TJSONObject(nil));

  if not Assigned(TextDocument) or not Assigned(Position) then
  begin
    SendResponse(ID, TJSONNull.Create);
    Exit;
  end;

  URI := TextDocument.Get('uri', '');
  Line := Position.Get('line', 0);
  Character := Position.Get('character', 0);
  Content := GetDocumentContent(URI);
  FilePath := URIToFilePath(URI);

  try
    CaretPos := CalculateCaretPosition(Content, Line, Character);
    Word := ExtractWordAtPosition(Content, CaretPos, WordStart, WordEnd);

    if Word = '' then
    begin
      SendResponse(ID, TJSONNull.Create);
      Exit;
    end;

    Codeinsight := TCodeinsight.Create;
    try
      Codeinsight.SetScript(Content, FilePath, CaretPos);
      Codeinsight.Run;

      Decls := Codeinsight.Get(Word);
      if Length(Decls) > 0 then
      begin
        Hover.Contents := '```simba' + LineEnding + Decls[0].Header + LineEnding + '```';
        Hover.Range := CreateRange(
          Line,
          Character - (CaretPos - WordStart),
          Line,
          Character + (WordEnd - CaretPos)
        );
        SendResponse(ID, HoverToJSON(Hover));
      end
      else
        SendResponse(ID, TJSONNull.Create);

    finally
      Codeinsight.Free;
    end;

  except
    on E: Exception do
    begin
      LogMessage('Hover error: ' + E.Message);
      SendResponse(ID, TJSONNull.Create);
    end;
  end;
end;

procedure TSimbaLSPServer.HandleTextDocumentDefinition(const ID: TJSONData; const Params: TJSONObject);
var
  TextDocument, Position: TJSONObject;
  URI, Content, FilePath, Word, Expr: String;
  Line, Character, CaretPos, I, WordStart, WordEnd, DotPos: Integer;
  Codeinsight: TCodeinsight;
  Decls, Members: TDeclarationArray;
  IsMemberAccess: Boolean;
  ExprDecl, MemberDecl, Decl: TDeclaration;
  Response: TJSONData;
begin
  TextDocument := Params.Get('textDocument', TJSONObject(nil));
  Position := Params.Get('position', TJSONObject(nil));

  if not Assigned(TextDocument) or not Assigned(Position) then
  begin
    SendResponse(ID, TJSONNull.Create);
    Exit;
  end;

  URI := TextDocument.Get('uri', '');
  Line := Position.Get('line', 0);
  Character := Position.Get('character', 0);
  Content := GetDocumentContent(URI);
  FilePath := URIToFilePath(URI);

  try
    CaretPos := CalculateCaretPosition(Content, Line, Character);
    Word := ExtractWordAtPosition(Content, CaretPos, WordStart, WordEnd);

    if Word = '' then
    begin
      SendResponse(ID, TJSONNull.Create);
      Exit;
    end;

    // Check if this is a member access (e.g., "Antiban.Zoom" with cursor on "Zoom")
    IsMemberAccess := ParseMemberAccessExpression(Content, WordStart, Expr, DotPos);

    Codeinsight := TCodeinsight.Create;
    try
      Codeinsight.SetScript(Content, FilePath, CaretPos);
      Codeinsight.Run;

      MemberDecl := nil;

      if IsMemberAccess and (Expr <> '') then
      begin
        // Member access - resolve the expression and find the member
        ExprDecl := Codeinsight.ParseExpr(Expr, Members);

        if Assigned(ExprDecl) then
        begin
          // Resolve the type and get its members
          if ExprDecl is TDeclaration_Var then
            Members := Codeinsight.GetTypeMembers(
              Codeinsight.ResolveVarType(TDeclaration_Var(ExprDecl).VarType))
          else if (ExprDecl is TDeclaration_Method) and
                  Assigned(TDeclaration_Method(ExprDecl).ResultType) then
            Members := Codeinsight.GetTypeMembers(
              Codeinsight.ResolveVarType(TDeclaration_Method(ExprDecl).ResultType))
          else if ExprDecl is TDeclaration_Type then
            Members := Codeinsight.GetTypeMembers(ExprDecl as TDeclaration_Type);

          // Find the specific member by name
          for Decl in Members do
          begin
            if SameText(Decl.Name, Word) then
            begin
              MemberDecl := Decl;
              Break;
            end;
          end;
        end;

        // If we found the member, return its location
        if Assigned(MemberDecl) then
        begin
          Response := CreateLocationResponse(URI, FilePath, Word, MemberDecl.DocPos);
          if not (Response is TJSONNull) then
          begin
            SendResponse(ID, Response);
            Exit;
          end;
          Response.Free;
          LogMessage('Declaration: ' + MemberDecl.Header);
          SendResponse(ID, TJSONNull.Create);
          Exit;
        end;
      end;

      // Fall back to regular lookup (either not member access or member not found)
      Decls := Codeinsight.Get(Word);
      if Length(Decls) > 0 then
      begin
        // Check if any result is a local enum element - prefer it over globals
        Decl := Decls[0];
        for I := 0 to High(Decls) do
        begin
          if (Decls[I] is TDeclaration_EnumElement) and
             (Decls[I].DocPos.FileName = FilePath) then
          begin
            Decl := Decls[I];
            Break;
          end;
        end;
        // Also check ScriptParser for local enum elements by name
        Members := Codeinsight.ScriptParser.Items.GetByClass(TDeclaration_EnumElement, False, True);
        for I := 0 to High(Members) do
        begin
          if (Members[I].DocPos.FileName = FilePath) and
             SameText(Members[I].Name, Word) then
          begin
            Decl := Members[I];
            Break;
          end;
        end;

        Response := CreateLocationResponse(URI, FilePath, Word, Decl.DocPos);
        if not (Response is TJSONNull) then
          SendResponse(ID, Response)
        else
        begin
          Response.Free;
          LogMessage('Declaration: ' + Decl.Header);
          SendResponse(ID, TJSONNull.Create);
        end;
      end
      else
        SendResponse(ID, TJSONNull.Create);

    finally
      Codeinsight.Free;
    end;

  except
    on E: Exception do
    begin
      LogMessage('Definition error: ' + E.Message);
      SendResponse(ID, TJSONNull.Create);
    end;
  end;
end;

procedure TSimbaLSPServer.HandleTextDocumentSignatureHelp(const ID: TJSONData; const Params: TJSONObject);
var
  TextDocument, Position: TJSONObject;
  URI, Content, FilePath, FuncName, Expr: String;
  Line, Character, CaretPos, I, ParenPos, ParamIndex: Integer;
  DotPos, ExprStart, FuncNameStart, FuncNameEnd: Integer;
  IsMemberAccess: Boolean;
  Ch: Char;
  Codeinsight: TCodeinsight;
  Decls, Members, MethodParams: TDeclarationArray;
  SigHelp: TLSPSignatureHelp;
  Method: TDeclaration_Method;
  ExprDecl, Decl: TDeclaration;
begin
  TextDocument := Params.Get('textDocument', TJSONObject(nil));
  Position := Params.Get('position', TJSONObject(nil));

  if not Assigned(TextDocument) or not Assigned(Position) then
  begin
    SendResponse(ID, TJSONNull.Create);
    Exit;
  end;

  URI := TextDocument.Get('uri', '');
  Line := Position.Get('line', 0);
  Character := Position.Get('character', 0);
  Content := GetDocumentContent(URI);
  FilePath := URIToFilePath(URI);

  try
    CaretPos := CalculateCaretPosition(Content, Line, Character);

    // Find the function name by looking backwards for '('
    ParenPos := CaretPos;
    ParamIndex := 0;
    while (ParenPos > 1) and (Content[ParenPos] <> '(') do
    begin
      if Content[ParenPos] = ',' then
        Inc(ParamIndex);
      Dec(ParenPos);
    end;

    if ParenPos <= 1 then
    begin
      SendResponse(ID, TJSONNull.Create);
      Exit;
    end;

    // Extract function name before '('
    FuncNameEnd := ParenPos - 1;
    while (FuncNameEnd > 0) and (Content[FuncNameEnd] in [' ', #9, #10, #13]) do
      Dec(FuncNameEnd);

    FuncNameStart := FuncNameEnd;
    while (FuncNameStart > 0) and (Content[FuncNameStart] in ['a'..'z', 'A'..'Z', '0'..'9', '_']) do
      Dec(FuncNameStart);
    Inc(FuncNameStart);
    FuncName := Copy(Content, FuncNameStart, FuncNameEnd - FuncNameStart + 1);

    if FuncName = '' then
    begin
      SendResponse(ID, TJSONNull.Create);
      Exit;
    end;

    // Check if this is a member access (e.g., "Self.FindButton(")
    IsMemberAccess := False;
    DotPos := 0;
    Expr := '';
    I := FuncNameStart - 1;

    // Skip whitespace before the function name
    while (I >= 1) and (Content[I] in [' ', #9]) do
      Dec(I);

    // Check if there's a dot
    if (I >= 1) and (Content[I] = '.') then
    begin
      IsMemberAccess := True;
      DotPos := I;

      // Extract the expression before the dot
      Dec(I);
      // Skip whitespace
      while (I >= 1) and (Content[I] in [' ', #9]) do
        Dec(I);

      // Find the start of the expression (handle chained access like a.b.c)
      ExprStart := I;
      while (ExprStart >= 1) do
      begin
        Ch := Content[ExprStart];
        if Ch in ['a'..'z', 'A'..'Z', '0'..'9', '_', '.', ')', ']'] then
        begin
          // Handle parentheses for function calls like Func().Method
          if Ch = ')' then
          begin
            I := 1;
            Dec(ExprStart);
            while (ExprStart >= 1) and (I > 0) do
            begin
              if Content[ExprStart] = ')' then Inc(I)
              else if Content[ExprStart] = '(' then Dec(I);
              Dec(ExprStart);
            end;
          end
          // Handle brackets for array access like Arr[0].Member
          else if Ch = ']' then
          begin
            I := 1;
            Dec(ExprStart);
            while (ExprStart >= 1) and (I > 0) do
            begin
              if Content[ExprStart] = ']' then Inc(I)
              else if Content[ExprStart] = '[' then Dec(I);
              Dec(ExprStart);
            end;
          end
          else
            Dec(ExprStart);
        end
        else
          Break;
      end;
      Inc(ExprStart);

      Expr := Trim(Copy(Content, ExprStart, DotPos - ExprStart));
    end;

    Codeinsight := TCodeinsight.Create;
    try
      Codeinsight.SetScript(Content, FilePath, CaretPos);
      Codeinsight.Run;

      Method := nil;

      if IsMemberAccess and (Expr <> '') then
      begin
        // Member access - resolve the expression and find the method
        ExprDecl := Codeinsight.ParseExpr(Expr, Members);

        if Assigned(ExprDecl) then
        begin
          // Resolve the type and get its members
          if ExprDecl is TDeclaration_Var then
            Members := Codeinsight.GetTypeMembers(
              Codeinsight.ResolveVarType(TDeclaration_Var(ExprDecl).VarType))
          else if (ExprDecl is TDeclaration_Method) and
                  Assigned(TDeclaration_Method(ExprDecl).ResultType) then
            Members := Codeinsight.GetTypeMembers(
              Codeinsight.ResolveVarType(TDeclaration_Method(ExprDecl).ResultType))
          else if ExprDecl is TDeclaration_Type then
            Members := Codeinsight.GetTypeMembers(ExprDecl as TDeclaration_Type);

          // Find the method by name in the type members
          for Decl in Members do
          begin
            if (Decl is TDeclaration_Method) and SameText(Decl.Name, FuncName) then
            begin
              Method := TDeclaration_Method(Decl);
              Break;
            end;
          end;
        end;
      end
      else
      begin
        // Regular function call - look up directly
        Decls := Codeinsight.Get(FuncName);
        if (Length(Decls) > 0) and (Decls[0] is TDeclaration_Method) then
          Method := TDeclaration_Method(Decls[0]);
      end;

      if Assigned(Method) then
      begin
        SetLength(SigHelp.Signatures, 1);
        SigHelp.Signatures[0].LabelText := Method.Header;
        SigHelp.Signatures[0].Documentation := '';

        // Get parameters using Method.Params property
        MethodParams := Method.Params;
        SetLength(SigHelp.Signatures[0].Parameters, Length(MethodParams));
        for I := 0 to High(MethodParams) do
        begin
          SigHelp.Signatures[0].Parameters[I].LabelText := MethodParams[I].Name;
          SigHelp.Signatures[0].Parameters[I].Documentation := '';
        end;

        SigHelp.ActiveSignature := 0;
        SigHelp.ActiveParameter := ParamIndex;

        SendResponse(ID, SignatureHelpToJSON(SigHelp));
      end
      else
        SendResponse(ID, TJSONNull.Create);

    finally
      Codeinsight.Free;
    end;

  except
    on E: Exception do
    begin
      LogMessage('Signature help error: ' + E.Message);
      SendResponse(ID, TJSONNull.Create);
    end;
  end;
end;

procedure TSimbaLSPServer.HandleTextDocumentDocumentSymbol(const ID: TJSONData; const Params: TJSONObject);
var
  TextDocument: TJSONObject;
  URI, Content, FilePath: String;
  Codeinsight: TCodeinsight;
  Decls: TDeclarationArray;
  Symbols: TJSONArray;
  Symbol: TLSPDocumentSymbol;
  I, SymLine, SymCol: Integer;
  Decl: TDeclaration;
begin
  TextDocument := Params.Get('textDocument', TJSONObject(nil));

  if not Assigned(TextDocument) then
  begin
    SendResponse(ID, TJSONArray.Create);
    Exit;
  end;

  URI := TextDocument.Get('uri', '');
  Content := GetDocumentContent(URI);
  FilePath := URIToFilePath(URI);

  Symbols := TJSONArray.Create;
  try
    Codeinsight := TCodeinsight.Create;
    try
      Codeinsight.SetScript(Content, FilePath, -1);
      Codeinsight.Run;

      // Get all declarations from the script parser
      Decls := Codeinsight.ScriptParser.Items.ToArray;
      for I := 0 to High(Decls) do
      begin
        Decl := Decls[I];
        if (Decl.Name <> '') and (Decl.DocPos.FileName = FilePath) then
        begin
          // Ensure line and column are valid (LSP uses 0-based, DocPos uses 1-based)
          // If DocPos values are 0 or negative, use 0 for LSP
          SymLine := Decl.DocPos.Line - 1;
          SymCol := Decl.DocPos.Col - 1;
          if SymLine < 0 then SymLine := 0;
          if SymCol < 0 then SymCol := 0;

          Symbol.Name := Decl.Name;
          Symbol.SelectionRange := CreateRange(
            SymLine, SymCol,
            SymLine, SymCol + Length(Decl.Name)
          );
          Symbol.Range := CreateRange(
            SymLine, 0,
            SymLine, SymCol + Length(Decl.Name)
          );

          if Decl is TDeclaration_Method then
            Symbol.Kind := skFunction
          else if Decl is TDeclaration_Type then
            Symbol.Kind := skClass
          else if Decl is TDeclaration_Const then
            Symbol.Kind := skConstant
          else if Decl is TDeclaration_Var then
            Symbol.Kind := skVariable
          else if Decl is TDeclaration_EnumElement then
            Symbol.Kind := skEnumMember
          else
            Continue;

          Symbols.Add(DocumentSymbolToJSON(Symbol));
        end;
      end;

    finally
      Codeinsight.Free;
    end;

    SendResponse(ID, Symbols);
  except
    on E: Exception do
    begin
      LogMessage('Document symbol error: ' + E.Message);
      SendResponse(ID, TJSONArray.Create);
    end;
  end;
end;

procedure TSimbaLSPServer.HandleTextDocumentFormatting(const ID: TJSONData; const Params: TJSONObject);
var
  TextDocument: TJSONObject;
  URI, Content, Formatted: String;
  EditArray: TJSONArray;
  Edit, Range: TJSONObject;
  LineCount, I: Integer;
begin
  TextDocument := Params.Get('textDocument', TJSONObject(nil));

  if not Assigned(TextDocument) then
  begin
    SendResponse(ID, TJSONArray.Create);
    Exit;
  end;

  URI := TextDocument.Get('uri', '');
  Content := GetDocumentContent(URI);

  try
    // Format the script
    Formatted := FormatScript(Content);

    // Count lines in original content
    LineCount := 1;
    for I := 1 to Length(Content) do
      if Content[I] = #10 then
        Inc(LineCount);

    // Create a single text edit that replaces the entire document
    EditArray := TJSONArray.Create;
    Edit := TJSONObject.Create;
    Range := TJSONObject.Create;

    // Range covering the entire document
    Range.Add('start', TJSONObject.Create(['line', 0, 'character', 0]));
    Range.Add('end', TJSONObject.Create(['line', LineCount, 'character', 0]));

    Edit.Add('range', Range);
    Edit.Add('newText', Formatted);
    EditArray.Add(Edit);

    SendResponse(ID, EditArray);
  except
    on E: Exception do
    begin
      LogMessage('Formatting error: ' + E.Message);
      SendResponse(ID, TJSONArray.Create);
    end;
  end;
end;

procedure TSimbaLSPServer.HandleTextDocumentSemanticTokensFull(const ID: TJSONData; const Params: TJSONObject);
var
  TextDocument: TJSONObject;
  URI, Content, FilePath: String;
  Codeinsight: TCodeinsight;
  Tokens: TLSPSemanticTokenArray;
  TokenCount: Integer;
  Lexer: TPasLexer;
  Decls, LocalDecls: TDeclarationArray;
  Decl, LocalDecl: TDeclaration;
  TokenType: TLSPSemanticTokenType;
  Modifiers: Integer;
  TokenLine, TokenCol, TokenLen, I: Integer;
  FoundLocal: Boolean;

  procedure AddToken(Line, StartChar, Len: Integer; ATokenType: TLSPSemanticTokenType; AModifiers: Integer);
  begin
    if (Len > 0) and (Line >= 0) and (StartChar >= 0) then
    begin
      if TokenCount >= Length(Tokens) then
        SetLength(Tokens, TokenCount + 256);
      Tokens[TokenCount].Line := Line;
      Tokens[TokenCount].StartChar := StartChar;
      Tokens[TokenCount].Length := Len;
      Tokens[TokenCount].TokenType := ATokenType;
      Tokens[TokenCount].Modifiers := AModifiers;
      Inc(TokenCount);
    end;
  end;

  procedure SortTokens;
  var
    K, L: Integer;
    Temp: TLSPSemanticToken;
  begin
    // Simple bubble sort - tokens should already be mostly sorted
    for K := 0 to TokenCount - 2 do
      for L := K + 1 to TokenCount - 1 do
        if (Tokens[L].Line < Tokens[K].Line) or
           ((Tokens[L].Line = Tokens[K].Line) and (Tokens[L].StartChar < Tokens[K].StartChar)) then
        begin
          Temp := Tokens[K];
          Tokens[K] := Tokens[L];
          Tokens[L] := Temp;
        end;
  end;

begin
  TextDocument := Params.Get('textDocument', TJSONObject(nil));

  if not Assigned(TextDocument) then
  begin
    SendResponse(ID, TJSONNull.Create);
    Exit;
  end;

  URI := TextDocument.Get('uri', '');
  Content := GetDocumentContent(URI);
  FilePath := URIToFilePath(URI);

  TokenCount := 0;
  SetLength(Tokens, 256);

  try
    Codeinsight := TCodeinsight.Create;
    try
      Codeinsight.SetScript(Content, FilePath, -1);
      Codeinsight.Run;

      // Get all local declarations from the script parser recursively
      // This includes enum elements, local vars, types defined in this file
      // We specifically get enum elements with SubSearch=True to find nested ones
      LocalDecls := Codeinsight.ScriptParser.Items.ToArray;
      // Add all enum elements (which are nested inside enum types)
      LocalDecls.Add(Codeinsight.ScriptParser.Items.GetByClass(TDeclaration_EnumElement, False, True));

      // Scan all tokens in the document using a lexer
      Lexer := TPasLexer.Create(Content, FilePath);
      try
        while Lexer.TokenID <> tokNull do
        begin
          // Only process identifiers
          if Lexer.TokenID = tokIdentifier then
          begin
            // Note: Lexer.DocPos.Line appears to already be in the right offset for LSP
            TokenLine := Lexer.DocPos.Line;
            TokenCol := Lexer.DocPos.Col;
            TokenLen := Lexer.TokenLen;

            // First, check local declarations for a definition at this position
            // This handles enum elements, local types, vars, etc. that might shadow globals
            FoundLocal := False;
            Decl := nil;
            for I := 0 to High(LocalDecls) do
            begin
              LocalDecl := LocalDecls[I];
              if (LocalDecl.DocPos.FileName = FilePath) then
              begin
                // Try exact position match first
                if (LocalDecl.DocPos.Line = TokenLine + 1) and
                   (LocalDecl.DocPos.Col = TokenCol + 1) then
                begin
                  Decl := LocalDecl;
                  FoundLocal := True;
                  Break;
                end
                // For enum elements, match by name only - enum element names are unique
                // and inside an enum declaration, identifiers can ONLY be enum elements
                else if (LocalDecl is TDeclaration_EnumElement) and
                        SameText(LocalDecl.Name, Lexer.Token) then
                begin
                  Decl := LocalDecl;
                  FoundLocal := True;
                  Break;
                end;
              end;
            end;

            // If not a local definition, look up this identifier globally
            if not FoundLocal then
            begin
              Decls := Codeinsight.Get(Lexer.Token);
              if Length(Decls) > 0 then
              begin
                Decl := Decls[0];
                // Check if any result is a local enum element - prefer it over globals
                // (enum elements defined in this file should take precedence)
                for I := 0 to High(Decls) do
                begin
                  if (Decls[I] is TDeclaration_EnumElement) and
                     (Decls[I].DocPos.FileName = FilePath) then
                  begin
                    Decl := Decls[I];
                    FoundLocal := True;
                    Break;
                  end;
                end;
              end;
            end;

            if Decl <> nil then
            begin
              Modifiers := 0;

              // Determine token type based on what it resolves to
              if Decl is TDeclaration_Method then
                TokenType := sttFunction
              else if Decl is TDeclaration_Type then
              begin
                if Decl is TDeclaration_TypeRecord then
                  TokenType := sttStruct
                else if Decl is TDeclaration_TypeEnum then
                  TokenType := sttEnum
                else
                  TokenType := sttType;
              end
              else if Decl is TDeclaration_Const then
              begin
                TokenType := sttVariable;
                Modifiers := 1 shl Ord(stmReadonly);
              end
              else if Decl is TDeclaration_EnumElement then
                TokenType := sttEnumMember
              else if Decl is TDeclaration_Parameter then
                TokenType := sttParameter
              else if Decl is TDeclaration_Var then
                TokenType := sttVariable
              else if Decl is TDeclaration_Field then
                TokenType := sttProperty
              else
                TokenType := sttVariable;  // Default fallback

              // Check if this is a definition site
              if FoundLocal then
                Modifiers := Modifiers or (1 shl Ord(stmDefinition));

              AddToken(TokenLine, TokenCol, TokenLen, TokenType, Modifiers);
            end;
          end;

          Lexer.Next;
        end;
      finally
        Lexer.Free;
      end;

    finally
      Codeinsight.Free;
    end;

    // Trim tokens array to actual size
    SetLength(Tokens, TokenCount);

    // Sort tokens by position (required for delta encoding)
    if TokenCount > 0 then
      SortTokens;

    SendResponse(ID, SemanticTokensToJSON(Tokens));

  except
    on E: Exception do
    begin
      LogMessage('Semantic tokens error: ' + E.Message);
      SendResponse(ID, TJSONNull.Create);
    end;
  end;
end;

procedure TSimbaLSPServer.HandleTextDocumentReferences(const ID: TJSONData; const Params: TJSONObject);
var
  TextDocument, Position: TJSONObject;
  URI, Content, FilePath, Word: String;
  Line, Character, CaretPos, WordStart, WordEnd: Integer;
  Codeinsight: TCodeinsight;
  Decls: TDeclarationArray;
  Locations: TJSONArray;
  Lexer: TPasLexer;
  Location: TJSONObject;
  LocRange: TJSONObject;
begin
  TextDocument := Params.Get('textDocument', TJSONObject(nil));
  Position := Params.Get('position', TJSONObject(nil));

  if not Assigned(TextDocument) or not Assigned(Position) then
  begin
    SendResponse(ID, TJSONArray.Create);
    Exit;
  end;

  URI := TextDocument.Get('uri', '');
  Line := Position.Get('line', 0);
  Character := Position.Get('character', 0);
  Content := GetDocumentContent(URI);
  FilePath := URIToFilePath(URI);

  Locations := TJSONArray.Create;
  try
    CaretPos := CalculateCaretPosition(Content, Line, Character);
    Word := ExtractWordAtPosition(Content, CaretPos, WordStart, WordEnd);

    if Word = '' then
    begin
      SendResponse(ID, Locations);
      Exit;
    end;

    Codeinsight := TCodeinsight.Create;
    try
      Codeinsight.SetScript(Content, FilePath, CaretPos);
      Codeinsight.Run;

      // Check if the word resolves to a known symbol
      Decls := Codeinsight.Get(Word);
      if Length(Decls) = 0 then
      begin
        SendResponse(ID, Locations);
        Exit;
      end;

      // Scan all tokens in the document to find references
      Lexer := TPasLexer.Create(Content, FilePath);
      try
        while Lexer.TokenID <> tokNull do
        begin
          if (Lexer.TokenID = tokIdentifier) and SameText(Lexer.Token, Word) then
          begin
            // Found a reference
            Location := TJSONObject.Create;
            LocRange := TJSONObject.Create;
            LocRange.Add('start', TJSONObject.Create(['line', Lexer.DocPos.Line, 'character', Lexer.DocPos.Col]));
            LocRange.Add('end', TJSONObject.Create(['line', Lexer.DocPos.Line, 'character', Lexer.DocPos.Col + Length(Word)]));
            Location.Add('uri', URI);
            Location.Add('range', LocRange);
            Locations.Add(Location);
          end;
          Lexer.Next;
        end;
      finally
        Lexer.Free;
      end;

    finally
      Codeinsight.Free;
    end;

    SendResponse(ID, Locations);
  except
    on E: Exception do
    begin
      LogMessage('References error: ' + E.Message);
      SendResponse(ID, TJSONArray.Create);
    end;
  end;
end;

procedure TSimbaLSPServer.HandleTextDocumentFoldingRange(const ID: TJSONData; const Params: TJSONObject);
var
  TextDocument: TJSONObject;
  URI, Content, FilePath: String;
  Codeinsight: TCodeinsight;
  Decls: TDeclarationArray;
  Decl: TDeclaration;
  Ranges: TJSONArray;
  FoldRange: TJSONObject;
  I, J, StartLine, EndLine: Integer;
begin
  TextDocument := Params.Get('textDocument', TJSONObject(nil));

  if not Assigned(TextDocument) then
  begin
    SendResponse(ID, TJSONArray.Create);
    Exit;
  end;

  URI := TextDocument.Get('uri', '');
  Content := GetDocumentContent(URI);
  FilePath := URIToFilePath(URI);

  Ranges := TJSONArray.Create;
  try
    Codeinsight := TCodeinsight.Create;
    try
      Codeinsight.SetScript(Content, FilePath, -1);
      Codeinsight.Run;

      // Get all declarations and create fold ranges for methods and types
      Decls := Codeinsight.ScriptParser.Items.ToArray;
      for I := 0 to High(Decls) do
      begin
        Decl := Decls[I];
        if (Decl.DocPos.FileName = FilePath) and (Decl.StartPos > 0) and (Decl.EndPos > Decl.StartPos) then
        begin
          // Only fold methods and compound types (record, class)
          if (Decl is TDeclaration_Method) or (Decl is TDeclaration_TypeRecord) then
          begin
            StartLine := Decl.DocPos.Line - 1;
            // Calculate end line from EndPos
            EndLine := StartLine;
            // Simple approximation - count newlines between start and end
            for J := Decl.StartPos to Min(Decl.EndPos, Length(Content)) do
              if Content[J] = #10 then
                Inc(EndLine);

            if EndLine > StartLine then
            begin
              FoldRange := TJSONObject.Create;
              FoldRange.Add('startLine', StartLine);
              FoldRange.Add('endLine', EndLine);
              FoldRange.Add('kind', 'region');
              Ranges.Add(FoldRange);
            end;
          end;
        end;
      end;

    finally
      Codeinsight.Free;
    end;

    SendResponse(ID, Ranges);
  except
    on E: Exception do
    begin
      LogMessage('Folding range error: ' + E.Message);
      SendResponse(ID, TJSONArray.Create);
    end;
  end;
end;

procedure TSimbaLSPServer.HandleTextDocumentRename(const ID: TJSONData; const Params: TJSONObject);
var
  TextDocument, Position: TJSONObject;
  URI, Content, FilePath, Word, NewName: String;
  Line, Character, CaretPos, WordStart, WordEnd: Integer;
  Codeinsight: TCodeinsight;
  Decls: TDeclarationArray;
  Lexer: TPasLexer;
  WorkspaceEdit, Changes: TJSONObject;
  Edits: TJSONArray;
  Edit, EditRange: TJSONObject;
begin
  TextDocument := Params.Get('textDocument', TJSONObject(nil));
  Position := Params.Get('position', TJSONObject(nil));
  NewName := Params.Get('newName', '');

  if not Assigned(TextDocument) or not Assigned(Position) or (NewName = '') then
  begin
    SendError(ID, -32602, 'Invalid params');
    Exit;
  end;

  URI := TextDocument.Get('uri', '');
  Line := Position.Get('line', 0);
  Character := Position.Get('character', 0);
  Content := GetDocumentContent(URI);
  FilePath := URIToFilePath(URI);

  try
    CaretPos := CalculateCaretPosition(Content, Line, Character);
    Word := ExtractWordAtPosition(Content, CaretPos, WordStart, WordEnd);

    if Word = '' then
    begin
      SendError(ID, -32602, 'No symbol at position');
      Exit;
    end;

    Codeinsight := TCodeinsight.Create;
    try
      Codeinsight.SetScript(Content, FilePath, CaretPos);
      Codeinsight.Run;

      // Check if the word resolves to a known symbol
      Decls := Codeinsight.Get(Word);
      if Length(Decls) = 0 then
      begin
        SendError(ID, -32602, 'Symbol not found: ' + Word);
        Exit;
      end;

      // Build workspace edit with all occurrences
      WorkspaceEdit := TJSONObject.Create;
      Changes := TJSONObject.Create;
      Edits := TJSONArray.Create;

      // Scan all tokens to find occurrences
      Lexer := TPasLexer.Create(Content, FilePath);
      try
        while Lexer.TokenID <> tokNull do
        begin
          if (Lexer.TokenID = tokIdentifier) and SameText(Lexer.Token, Word) then
          begin
            Edit := TJSONObject.Create;
            EditRange := TJSONObject.Create;
            EditRange.Add('start', TJSONObject.Create(['line', Lexer.DocPos.Line, 'character', Lexer.DocPos.Col]));
            EditRange.Add('end', TJSONObject.Create(['line', Lexer.DocPos.Line, 'character', Lexer.DocPos.Col + Length(Word)]));
            Edit.Add('range', EditRange);
            Edit.Add('newText', NewName);
            Edits.Add(Edit);
          end;
          Lexer.Next;
        end;
      finally
        Lexer.Free;
      end;

      Changes.Add(URI, Edits);
      WorkspaceEdit.Add('changes', Changes);

      SendResponse(ID, WorkspaceEdit);

    finally
      Codeinsight.Free;
    end;

  except
    on E: Exception do
    begin
      LogMessage('Rename error: ' + E.Message);
      SendError(ID, -32603, 'Rename failed: ' + E.Message);
    end;
  end;
end;

procedure TSimbaLSPServer.HandleTextDocumentTypeDefinition(const ID: TJSONData; const Params: TJSONObject);
var
  TextDocument, Position: TJSONObject;
  URI, Content, FilePath, Word: String;
  Line, Character, CaretPos, WordStart, WordEnd: Integer;
  Codeinsight: TCodeinsight;
  Decls: TDeclarationArray;
  Decl: TDeclaration;
  TypeDecl: TDeclaration_Type;
  Location: TLSPLocation;
begin
  TextDocument := Params.Get('textDocument', TJSONObject(nil));
  Position := Params.Get('position', TJSONObject(nil));

  if not Assigned(TextDocument) or not Assigned(Position) then
  begin
    SendResponse(ID, TJSONNull.Create);
    Exit;
  end;

  URI := TextDocument.Get('uri', '');
  Line := Position.Get('line', 0);
  Character := Position.Get('character', 0);
  Content := GetDocumentContent(URI);
  FilePath := URIToFilePath(URI);

  try
    CaretPos := CalculateCaretPosition(Content, Line, Character);
    Word := ExtractWordAtPosition(Content, CaretPos, WordStart, WordEnd);

    if Word = '' then
    begin
      SendResponse(ID, TJSONNull.Create);
      Exit;
    end;

    Codeinsight := TCodeinsight.Create;
    try
      Codeinsight.SetScript(Content, FilePath, CaretPos);
      Codeinsight.Run;

      Decls := Codeinsight.Get(Word);
      if Length(Decls) > 0 then
      begin
        Decl := Decls[0];
        TypeDecl := nil;

        // If it's a variable, get its type
        if Decl is TDeclaration_Var then
          TypeDecl := Codeinsight.ResolveVarType(TDeclaration_Var(Decl).VarType)
        else if Decl is TDeclaration_Type then
          TypeDecl := Decl as TDeclaration_Type;

        if Assigned(TypeDecl) and (TypeDecl.DocPos.FileName <> '') and
           (TypeDecl.DocPos.Line > 0) and FileExists(TypeDecl.DocPos.FileName) then
        begin
          Location.URI := FilePathToURI(TypeDecl.DocPos.FileName);
          Location.Range := CreateRange(
            TypeDecl.DocPos.Line - 1,
            Max(0, TypeDecl.DocPos.Col - 1),
            TypeDecl.DocPos.Line - 1,
            Max(0, TypeDecl.DocPos.Col - 1) + Length(TypeDecl.Name)
          );
          SendResponse(ID, LocationToJSON(Location));
          Exit;
        end;
      end;

      SendResponse(ID, TJSONNull.Create);

    finally
      Codeinsight.Free;
    end;

  except
    on E: Exception do
    begin
      LogMessage('Type definition error: ' + E.Message);
      SendResponse(ID, TJSONNull.Create);
    end;
  end;
end;

procedure TSimbaLSPServer.HandleWorkspaceSymbol(const ID: TJSONData; const Params: TJSONObject);
var
  Query: String;
  Symbols: TJSONArray;
  Symbol: TJSONObject;
  SymLoc, SymRange: TJSONObject;
  Decl: TDeclaration;
  Decls: TDeclarationArray;
  I: Integer;
  DocIdx: Integer;
  URI, FilePath, Content: String;
  Codeinsight: TCodeinsight;
  OpenDocPaths: TStringList;
  WorkspaceResults: TWorkspaceCachedDeclArray;
  WDecl: TWorkspaceCachedDecl;
begin
  Query := Params.Get('query', '');

  Symbols := TJSONArray.Create;
  OpenDocPaths := TStringList.Create;
  try
    // 1. Search through all open documents (existing behavior)
    for DocIdx := 0 to FDocuments.Count - 1 do
    begin
      URI := FDocuments[DocIdx];
      FilePath := URIToFilePath(URI);
      OpenDocPaths.Add(FilePath);  // Track open docs
      Content := TStringList(FDocuments.Objects[DocIdx]).Text;

      Codeinsight := TCodeinsight.Create;
      try
        Codeinsight.SetScript(Content, FilePath, -1);
        Codeinsight.Run;

        Decls := Codeinsight.ScriptParser.Items.ToArray;
        for I := 0 to High(Decls) do
        begin
          Decl := Decls[I];
          if (Query = '') or (Pos(LowerCase(Query), LowerCase(Decl.Name)) > 0) then
          begin
            if (Decl.Name <> '') and (Decl.DocPos.FileName = FilePath) then
            begin
              Symbol := TJSONObject.Create;
              Symbol.Add('name', Decl.Name);

              if Decl is TDeclaration_Method then
                Symbol.Add('kind', Ord(skFunction) + 1)
              else if Decl is TDeclaration_Type then
                Symbol.Add('kind', Ord(skClass) + 1)
              else if Decl is TDeclaration_Const then
                Symbol.Add('kind', Ord(skConstant) + 1)
              else if Decl is TDeclaration_Var then
                Symbol.Add('kind', Ord(skVariable) + 1)
              else
                Symbol.Add('kind', Ord(skVariable) + 1);

              SymLoc := TJSONObject.Create;
              SymLoc.Add('uri', URI);
              SymRange := TJSONObject.Create;
              SymRange.Add('start', TJSONObject.Create(['line', Max(0, Decl.DocPos.Line - 1), 'character', Max(0, Decl.DocPos.Col - 1)]));
              SymRange.Add('end', TJSONObject.Create(['line', Max(0, Decl.DocPos.Line - 1), 'character', Max(0, Decl.DocPos.Col - 1) + Length(Decl.Name)]));
              SymLoc.Add('range', SymRange);
              Symbol.Add('location', SymLoc);

              Symbols.Add(Symbol);

              if Symbols.Count >= 100 then
                Break;
            end;
          end;
        end;

      finally
        Codeinsight.Free;
      end;

      if Symbols.Count >= 100 then
        Break;
    end;

    // 2. Search workspace files not already open
    if (Symbols.Count < 100) and (FWorkspaceIndex.WorkspaceRoot <> '') then
    begin
      WorkspaceResults := FWorkspaceIndex.Search(Query);

      for I := 0 to High(WorkspaceResults) do
      begin
        WDecl := WorkspaceResults[I];

        // Skip if file is already open (already searched above)
        if OpenDocPaths.IndexOf(WDecl.FilePath) >= 0 then
          Continue;

        Symbol := TJSONObject.Create;
        Symbol.Add('name', WDecl.Name);
        Symbol.Add('kind', WDecl.Kind);

        SymLoc := TJSONObject.Create;
        SymLoc.Add('uri', FilePathToURI(WDecl.FilePath));
        SymRange := TJSONObject.Create;
        SymRange.Add('start', TJSONObject.Create(['line', Max(0, WDecl.Line - 1), 'character', Max(0, WDecl.Col - 1)]));
        SymRange.Add('end', TJSONObject.Create(['line', Max(0, WDecl.Line - 1), 'character', Max(0, WDecl.Col - 1) + Length(WDecl.Name)]));
        SymLoc.Add('range', SymRange);
        Symbol.Add('location', SymLoc);

        Symbols.Add(Symbol);

        if Symbols.Count >= 100 then
          Break;
      end;
    end;

    SendResponse(ID, Symbols);
  except
    on E: Exception do
    begin
      LogMessage('Workspace symbol error: ' + E.Message);
      SendResponse(ID, TJSONArray.Create);
    end;
  end;

  OpenDocPaths.Free;
end;

procedure TSimbaLSPServer.HandleTextDocumentCodeAction(const ID: TJSONData; const Params: TJSONObject);
var
  TextDocument, Context: TJSONObject;
  URI, Content: String;
  DiagArray: TJSONArray;
  DiagObj: TJSONObject;
  DiagMsg: String;
  DiagLine: Integer;
  Actions: TJSONArray;
  Action: TLSPCodeAction;
  ActionDiag: TLSPDiagnostic;
  I, J: Integer;
  Info: TDiagnosticErrorInfo;
  Matched: Boolean;

  // Find the end of an identifier starting at Pos (1-based in Content)
  function FindIdentEnd(StartPos: Integer): Integer;
  begin
    Result := StartPos;
    while (Result <= Length(Content)) and
          (Content[Result] in ['a'..'z', 'A'..'Z', '0'..'9', '_']) do
      Inc(Result);
  end;

  // Find the start of an identifier ending before Pos (1-based in Content)
  function FindIdentStart(EndPos: Integer): Integer;
  begin
    Result := EndPos;
    while (Result > 1) and
          (Content[Result - 1] in ['a'..'z', 'A'..'Z', '0'..'9', '_']) do
      Dec(Result);
  end;

  // Convert 1-based line/col to 0-based LSP position
  function ToLSPLine(L: Integer): Integer;
  begin
    Result := Max(0, L - 1);
  end;
  function ToLSPCol(C: Integer): Integer;
  begin
    Result := Max(0, C - 1);
  end;

  // Find the position of '(' after an identifier, skipping whitespace
  function FindOpenParen(FromPos: Integer): Integer;
  begin
    Result := FromPos;
    // Skip whitespace
    while (Result <= Length(Content)) and (Content[Result] in [' ', #9]) do
      Inc(Result);
    if (Result <= Length(Content)) and (Content[Result] = '(') then
      Exit;
    Result := 0; // Not found
  end;

  // Find matching close paren for an open paren at Pos
  function FindCloseParen(OpenPos: Integer): Integer;
  var
    Depth: Integer;
  begin
    Depth := 1;
    Result := OpenPos + 1;
    while (Result <= Length(Content)) and (Depth > 0) do
    begin
      if Content[Result] = '(' then Inc(Depth)
      else if Content[Result] = ')' then Dec(Depth);
      if Depth > 0 then Inc(Result);
    end;
    if Depth <> 0 then Result := 0;
  end;

  // Create a code action and add it to the Actions array
  procedure AddAction(const Title: String; EditLine, EditStartCol, EditEndCol: Integer;
                      const NewText: String; Preferred: Boolean);
  begin
    Action.Title := Title;
    Action.Kind := 'quickfix';
    Action.IsPreferred := Preferred;

    // Set up the edit
    Action.Edit.URI := URI;
    SetLength(Action.Edit.Edits, 1);
    Action.Edit.Edits[0].Range := CreateRange(
      ToLSPLine(EditLine), ToLSPCol(EditStartCol),
      ToLSPLine(EditLine), ToLSPCol(EditEndCol));
    Action.Edit.Edits[0].NewText := NewText;

    // Attach the diagnostic
    SetLength(Action.Diagnostics, 1);
    ActionDiag.Range := CreateRange(
      ToLSPLine(Info.Line), ToLSPCol(Info.Col),
      ToLSPLine(Info.Line), ToLSPCol(Info.Col) + 10);
    ActionDiag.Severity := DiagError;
    ActionDiag.Message := Info.Message;
    ActionDiag.Source := 'simba';
    Action.Diagnostics[0] := ActionDiag;

    Actions.Add(CodeActionToJSON(Action));
  end;

  // Extract identifier name from "Unknown declaration" message
  function ExtractUnknownName(const Msg: String): String;
  var
    P: Integer;
  begin
    Result := '';
    P := Pos('Unknown declaration "', Msg);
    if P > 0 then
    begin
      Result := Copy(Msg, P + 21, Length(Msg));
      P := Pos('"', Result);
      if P > 0 then
        Result := Copy(Result, 1, P - 1);
    end;
  end;

  // Simple Levenshtein distance for fuzzy matching
  function LevenshteinDistance(const S1, S2: String): Integer;
  var
    D: array of array of Integer;
    Len1, Len2, Cost, X, Y: Integer;
  begin
    Len1 := Length(S1);
    Len2 := Length(S2);
    SetLength(D, Len1 + 1, Len2 + 1);
    for X := 0 to Len1 do D[X][0] := X;
    for Y := 0 to Len2 do D[0][Y] := Y;

    for X := 1 to Len1 do
      for Y := 1 to Len2 do
      begin
        if UpCase(S1[X]) = UpCase(S2[Y]) then
          Cost := 0
        else
          Cost := 1;
        D[X][Y] := D[X-1][Y] + 1;         // Deletion
        if D[X][Y-1] + 1 < D[X][Y] then
          D[X][Y] := D[X][Y-1] + 1;        // Insertion
        if D[X-1][Y-1] + Cost < D[X][Y] then
          D[X][Y] := D[X-1][Y-1] + Cost;   // Substitution
      end;

    Result := D[Len1][Len2];
  end;

var
  CaretPos, IdentEnd, ParenOpen, ParenClose: Integer;
  UnknownName, CandidateName: String;
  Codeinsight: TCodeinsight;
  Decls: TDeclarationArray;
  BestDist, Dist: Integer;
  BestName: String;
begin
  TextDocument := Params.Get('textDocument', TJSONObject(nil));
  Context := Params.Get('context', TJSONObject(nil));

  if not Assigned(TextDocument) or not Assigned(Context) then
  begin
    SendResponse(ID, TJSONArray.Create);
    Exit;
  end;

  URI := TextDocument.Get('uri', '');
  Content := GetDocumentContent(URI);
  Actions := TJSONArray.Create;

  // Get diagnostics from the request context
  DiagArray := Context.Get('diagnostics', TJSONArray(nil));
  if not Assigned(DiagArray) or (DiagArray.Count = 0) then
  begin
    SendResponse(ID, Actions);
    Exit;
  end;

  try
    // For each diagnostic in the request, find matching stored error info
    for I := 0 to DiagArray.Count - 1 do
    begin
      DiagObj := TJSONObject(DiagArray[I]);
      DiagMsg := DiagObj.Get('message', '');
      DiagLine := TJSONObject(TJSONObject(DiagObj.Get('range', TJSONObject(nil))).Get('start', TJSONObject(nil))).Get('line', -1);

      // Find matching error in our stored structured errors
      Matched := False;
      for J := 0 to High(FDiagnosticErrors) do
      begin
        Info := FDiagnosticErrors[J];
        // Match by message and line (0-based LSP line = Info.Line - 1)
        if (Info.Message = DiagMsg) and (ToLSPLine(Info.Line) = DiagLine) then
        begin
          Matched := True;
          Break;
        end;
      end;

      if not Matched then
        Continue;

      // Generate quick fixes based on error category
      case Info.Category of
        ecMissingParens:
        begin
          // Add "()" after the identifier at the error position
          if (Info.Line > 0) and (Info.Col > 0) then
          begin
            CaretPos := LSPCalculateCaretPosition(Content, ToLSPLine(Info.Line), ToLSPCol(Info.Col));
            IdentEnd := FindIdentEnd(CaretPos);
            // Insert "()" at end of identifier
            AddAction('Add ''()'' to function call',
                      Info.Line, Info.Col + (IdentEnd - CaretPos), Info.Col + (IdentEnd - CaretPos),
                      '()', True);
          end;
        end;

        ecExtraParens:
        begin
          // Remove "()" after the property identifier
          if (Info.Line > 0) and (Info.Col > 0) then
          begin
            CaretPos := LSPCalculateCaretPosition(Content, ToLSPLine(Info.Line), ToLSPCol(Info.Col));
            IdentEnd := FindIdentEnd(CaretPos);
            ParenOpen := FindOpenParen(IdentEnd);
            if ParenOpen > 0 then
            begin
              ParenClose := FindCloseParen(ParenOpen);
              if ParenClose > 0 then
              begin
                // Remove from paren open through paren close (inclusive)
                AddAction('Remove ''()'' from property access',
                          Info.Line, Info.Col + (ParenOpen - CaretPos), Info.Col + (ParenClose - CaretPos) + 1,
                          '', True);
              end;
            end;
          end;
        end;

        ecPointerWhereVarExpected:
        begin
          // Remove "@" before the identifier
          if (Info.Line > 0) and (Info.Col > 0) then
          begin
            CaretPos := LSPCalculateCaretPosition(Content, ToLSPLine(Info.Line), ToLSPCol(Info.Col));
            // Check if '@' is just before the identifier
            if (CaretPos > 1) and (Content[CaretPos - 1] = '@') then
              AddAction('Remove ''@'' (pass by reference instead)',
                        Info.Line, Info.Col - 1, Info.Col,
                        '', True)
            else if (CaretPos >= 1) and (Content[CaretPos] = '@') then
              AddAction('Remove ''@'' (pass by reference instead)',
                        Info.Line, Info.Col, Info.Col + 1,
                        '', True);
          end;
        end;

        ecUnknownDeclaration:
        begin
          // Fuzzy-match against known declarations
          UnknownName := ExtractUnknownName(Info.Message);
          if (UnknownName <> '') and (Info.Line > 0) and (Info.Col > 0) then
          begin
            CaretPos := LSPCalculateCaretPosition(Content, ToLSPLine(Info.Line), ToLSPCol(Info.Col));
            IdentEnd := FindIdentEnd(CaretPos);

            Codeinsight := TCodeinsight.Create;
            try
              Codeinsight.SetScript(Content, URIToFilePath(URI), CaretPos);
              Codeinsight.Run;

              // Search locals + globals for fuzzy matches
              BestDist := MaxInt;
              BestName := '';

              Decls := Codeinsight.GetLocals;
              for J := 0 to High(Decls) do
              begin
                CandidateName := Decls[J].Name;
                if (CandidateName <> '') and (CandidateName <> UnknownName) then
                begin
                  Dist := LevenshteinDistance(UnknownName, CandidateName);
                  // Only suggest if distance is reasonable (max 2 edits, or ~40% of length)
                  if (Dist < BestDist) and (Dist <= Max(2, Length(UnknownName) div 3)) then
                  begin
                    BestDist := Dist;
                    BestName := CandidateName;
                  end;
                end;
              end;

              Decls := Codeinsight.GetGlobals;
              for J := 0 to High(Decls) do
              begin
                CandidateName := Decls[J].Name;
                if (CandidateName <> '') and (CandidateName <> UnknownName) then
                begin
                  Dist := LevenshteinDistance(UnknownName, CandidateName);
                  if (Dist < BestDist) and (Dist <= Max(2, Length(UnknownName) div 3)) then
                  begin
                    BestDist := Dist;
                    BestName := CandidateName;
                  end;
                end;
              end;

              if BestName <> '' then
                AddAction('Replace with ''' + BestName + '''',
                          Info.Line, Info.Col, Info.Col + (IdentEnd - CaretPos),
                          BestName, False);
            finally
              Codeinsight.Free;
            end;
          end;
        end;
      end; // case
    end; // for each diagnostic

    SendResponse(ID, Actions);
  except
    on E: Exception do
    begin
      Actions.Free;
      SendError(ID, -32603, 'Code action failed: ' + E.Message);
    end;
  end;
end;

procedure TSimbaLSPServer.HandleTextDocumentInlayHint(const ID: TJSONData; const Params: TJSONObject);
var
  TextDocument, RangeObj, StartPos, EndPos: TJSONObject;
  URI, Content, FilePath, FuncName, Expr: String;
  StartLine, EndLine: Integer;
  RangeStart, RangeEnd: Integer;
  Hints: TJSONArray;
  Hint: TLSPInlayHint;
  Codeinsight: TCodeinsight;
  Decls, Members, MethodParams: TDeclarationArray;
  Method: TDeclaration_Method;
  ExprDecl, Decl: TDeclaration;
  I, Pos_, Depth, ArgStart, ArgIndex: Integer;
  FuncNameStart, FuncNameEnd, DotPos_, ExprStart_: Integer;
  ParenOpenPos: Integer;
  IsMemberAccess: Boolean;
  InString: Boolean;
  StringChar: Char;
  Ch: Char;
  ArgPositions: array of Integer; // content positions where each argument starts

  // Convert a 1-based content position to 0-based LSP line and character
  procedure ContentPosToLSP(ContentPos: Integer; out LSPLine, LSPChar: Integer);
  var
    J, LineStart: Integer;
  begin
    LSPLine := 0;
    LineStart := 1;
    for J := 1 to ContentPos - 1 do
    begin
      if Content[J] = #10 then
      begin
        Inc(LSPLine);
        LineStart := J + 1;
      end;
    end;
    LSPChar := ContentPos - LineStart;
  end;

  // Skip whitespace forward from a position
  function SkipWhitespace(FromPos: Integer): Integer;
  begin
    Result := FromPos;
    while (Result <= Length(Content)) and (Content[Result] in [' ', #9, #10, #13]) do
      Inc(Result);
  end;

begin
  TextDocument := Params.Get('textDocument', TJSONObject(nil));
  RangeObj := Params.Get('range', TJSONObject(nil));

  if not Assigned(TextDocument) or not Assigned(RangeObj) then
  begin
    SendResponse(ID, TJSONArray.Create);
    Exit;
  end;

  URI := TextDocument.Get('uri', '');
  Content := GetDocumentContent(URI);
  FilePath := URIToFilePath(URI);
  Hints := TJSONArray.Create;

  StartPos := TJSONObject(RangeObj.Get('start', TJSONObject(nil)));
  EndPos := TJSONObject(RangeObj.Get('end', TJSONObject(nil)));
  if not Assigned(StartPos) or not Assigned(EndPos) then
  begin
    SendResponse(ID, Hints);
    Exit;
  end;

  StartLine := StartPos.Get('line', 0);
  EndLine := EndPos.Get('line', 0);

  // Convert LSP line range to content positions
  RangeStart := LSPCalculateCaretPosition(Content, StartLine, 0);
  RangeEnd := LSPCalculateCaretPosition(Content, EndLine + 1, 0);
  if RangeEnd > Length(Content) then
    RangeEnd := Length(Content);

  try
    // Create a single Codeinsight for resolving declarations
    Codeinsight := TCodeinsight.Create;
    try
      Codeinsight.SetScript(Content, FilePath, RangeStart);
      Codeinsight.Run;

      // Scan for function calls: identifier followed by '('
      Pos_ := RangeStart;
      while Pos_ <= RangeEnd do
      begin
        Ch := Content[Pos_];

        // Skip string literals
        if Ch in ['''', '"'] then
        begin
          StringChar := Ch;
          Inc(Pos_);
          while (Pos_ <= Length(Content)) and (Content[Pos_] <> StringChar) do
            Inc(Pos_);
          Inc(Pos_);
          Continue;
        end;

        // Skip line comments
        if (Ch = '/') and (Pos_ < Length(Content)) and (Content[Pos_ + 1] = '/') then
        begin
          while (Pos_ <= Length(Content)) and not (Content[Pos_] in [#10, #13]) do
            Inc(Pos_);
          Continue;
        end;

        // Skip block comments { ... }
        if Ch = '{' then
        begin
          Inc(Pos_);
          while (Pos_ <= Length(Content)) and (Content[Pos_] <> '}') do
            Inc(Pos_);
          Inc(Pos_);
          Continue;
        end;

        // Look for '(' preceded by an identifier
        if Ch = '(' then
        begin
          // Find function name before '('
          FuncNameEnd := Pos_ - 1;
          while (FuncNameEnd > 0) and (Content[FuncNameEnd] in [' ', #9]) do
            Dec(FuncNameEnd);

          if (FuncNameEnd > 0) and (Content[FuncNameEnd] in ['a'..'z', 'A'..'Z', '0'..'9', '_']) then
          begin
            FuncNameStart := FuncNameEnd;
            while (FuncNameStart > 1) and (Content[FuncNameStart - 1] in ['a'..'z', 'A'..'Z', '0'..'9', '_']) do
              Dec(FuncNameStart);
            FuncName := Copy(Content, FuncNameStart, FuncNameEnd - FuncNameStart + 1);
            ParenOpenPos := Pos_;

            // Skip keywords that use parens but aren't function calls
            if (LowerCase(FuncName) = 'if') or (LowerCase(FuncName) = 'while') or
               (LowerCase(FuncName) = 'for') or (LowerCase(FuncName) = 'case') or
               (LowerCase(FuncName) = 'until') or (LowerCase(FuncName) = 'enum') or
               (LowerCase(FuncName) = 'array') or (LowerCase(FuncName) = 'set') then
            begin
              Inc(Pos_);
              Continue;
            end;

            // Find argument positions at depth 0 within the parens
            SetLength(ArgPositions, 0);
            Depth := 1;
            I := ParenOpenPos + 1;
            InString := False;
            StringChar := #0;

            // First arg starts after '(' (skip whitespace)
            ArgStart := SkipWhitespace(I);
            // Check it's not an empty call ()
            if (ArgStart <= Length(Content)) and (Content[ArgStart] <> ')') then
            begin
              SetLength(ArgPositions, 1);
              ArgPositions[0] := ArgStart;
            end;

            while (I <= Length(Content)) and (Depth > 0) do
            begin
              if InString then
              begin
                if Content[I] = StringChar then
                  InString := False;
              end
              else
              begin
                case Content[I] of
                  '''', '"':
                  begin
                    InString := True;
                    StringChar := Content[I];
                  end;
                  '(', '[': Inc(Depth);
                  ')', ']':
                  begin
                    Dec(Depth);
                    if Depth = 0 then Break;
                  end;
                  ',':
                    if Depth = 1 then
                    begin
                      // New argument starts after comma (skip whitespace)
                      ArgStart := SkipWhitespace(I + 1);
                      SetLength(ArgPositions, Length(ArgPositions) + 1);
                      ArgPositions[High(ArgPositions)] := ArgStart;
                    end;
                end;
              end;
              Inc(I);
            end;

            // Only generate hints if there are arguments
            if Length(ArgPositions) > 0 then
            begin
              // Resolve the function declaration
              Method := nil;

              // Check for member access: expr.FuncName(
              IsMemberAccess := False;
              DotPos_ := FuncNameStart - 1;
              while (DotPos_ > 0) and (Content[DotPos_] in [' ', #9]) do
                Dec(DotPos_);

              if (DotPos_ > 0) and (Content[DotPos_] = '.') then
              begin
                IsMemberAccess := True;
                ExprStart_ := DotPos_ - 1;
                while (ExprStart_ > 0) and (Content[ExprStart_] in [' ', #9]) do
                  Dec(ExprStart_);

                // Walk backwards through expression (identifiers, dots, parens, brackets)
                while (ExprStart_ > 0) do
                begin
                  Ch := Content[ExprStart_];
                  if Ch in ['a'..'z', 'A'..'Z', '0'..'9', '_', '.'] then
                    Dec(ExprStart_)
                  else if Ch = ')' then
                  begin
                    Depth := 1;
                    Dec(ExprStart_);
                    while (ExprStart_ > 0) and (Depth > 0) do
                    begin
                      if Content[ExprStart_] = ')' then Inc(Depth)
                      else if Content[ExprStart_] = '(' then Dec(Depth);
                      Dec(ExprStart_);
                    end;
                  end
                  else if Ch = ']' then
                  begin
                    Depth := 1;
                    Dec(ExprStart_);
                    while (ExprStart_ > 0) and (Depth > 0) do
                    begin
                      if Content[ExprStart_] = ']' then Inc(Depth)
                      else if Content[ExprStart_] = '[' then Dec(Depth);
                      Dec(ExprStart_);
                    end;
                  end
                  else
                    Break;
                end;
                Inc(ExprStart_);

                Expr := Trim(Copy(Content, ExprStart_, DotPos_ - ExprStart_));
                if Expr <> '' then
                begin
                  try
                    ExprDecl := Codeinsight.ParseExpr(Expr, Members);
                    if Assigned(ExprDecl) then
                    begin
                      if ExprDecl is TDeclaration_Var then
                        Members := Codeinsight.GetTypeMembers(
                          Codeinsight.ResolveVarType(TDeclaration_Var(ExprDecl).VarType))
                      else if (ExprDecl is TDeclaration_Method) and
                              Assigned(TDeclaration_Method(ExprDecl).ResultType) then
                        Members := Codeinsight.GetTypeMembers(
                          Codeinsight.ResolveVarType(TDeclaration_Method(ExprDecl).ResultType))
                      else if ExprDecl is TDeclaration_Type then
                        Members := Codeinsight.GetTypeMembers(ExprDecl as TDeclaration_Type);

                      for Decl in Members do
                        if (Decl is TDeclaration_Method) and SameText(Decl.Name, FuncName) then
                        begin
                          Method := TDeclaration_Method(Decl);
                          Break;
                        end;
                    end;
                  except
                    Method := nil;
                  end;
                end;
              end;

              if not IsMemberAccess then
              begin
                try
                  Decls := Codeinsight.Get(FuncName);
                  if (Length(Decls) > 0) and (Decls[0] is TDeclaration_Method) then
                    Method := TDeclaration_Method(Decls[0]);
                except
                  Method := nil;
                end;
              end;

              // Generate hints for resolved method
              if Assigned(Method) then
              begin
                MethodParams := Method.Params;
                for ArgIndex := 0 to Min(High(ArgPositions), High(MethodParams)) do
                begin
                  if MethodParams[ArgIndex].Name <> '' then
                  begin
                    ContentPosToLSP(ArgPositions[ArgIndex], Hint.Position.Line, Hint.Position.Character);
                    Hint.LabelText := MethodParams[ArgIndex].Name + ':';
                    Hint.Kind := ihkParameter;
                    Hint.PaddingLeft := False;
                    Hint.PaddingRight := True;
                    Hints.Add(InlayHintToJSON(Hint));
                  end;
                end;
              end;
            end; // if ArgPositions > 0
          end; // if identifier before '('
        end; // if Ch = '('

        Inc(Pos_);
      end; // while scanning

    finally
      Codeinsight.Free;
    end;

    SendResponse(ID, Hints);
  except
    on E: Exception do
    begin
      LogMessage('Inlay hint error: ' + E.Message);
      Hints.Free;
      SendResponse(ID, TJSONArray.Create);
    end;
  end;
end;

procedure TSimbaLSPServer.Run;
var
  Message: String;
  JSON, Params: TJSONObject;
  Method: String;
  ID: TJSONData;
begin
  while True do
  begin
    try
      Message := ReadMessage;
      if Message = '' then
        Continue;

      JSON := TJSONObject(GetJSON(Message));
      try
        Method := JSON.Get('method', '');
        ID := JSON.Find('id');
        Params := JSON.Get('params', TJSONObject(nil));

        if Method = 'initialize' then
          HandleInitialize(ID, Params)
        else if Method = 'initialized' then
          HandleInitialized(Params)
        else if Method = 'shutdown' then
          HandleShutdown(ID)
        else if Method = 'exit' then
          HandleExit
        else if Method = 'textDocument/didOpen' then
          HandleTextDocumentDidOpen(Params)
        else if Method = 'textDocument/didChange' then
          HandleTextDocumentDidChange(Params)
        else if Method = 'textDocument/didClose' then
          HandleTextDocumentDidClose(Params)
        else if Method = 'textDocument/didSave' then
          HandleTextDocumentDidSave(Params)
        else if Method = 'textDocument/completion' then
          HandleTextDocumentCompletion(ID, Params)
        else if Method = 'textDocument/hover' then
          HandleTextDocumentHover(ID, Params)
        else if Method = 'textDocument/definition' then
          HandleTextDocumentDefinition(ID, Params)
        else if Method = 'textDocument/signatureHelp' then
          HandleTextDocumentSignatureHelp(ID, Params)
        else if Method = 'textDocument/documentSymbol' then
          HandleTextDocumentDocumentSymbol(ID, Params)
        else if Method = 'textDocument/formatting' then
          HandleTextDocumentFormatting(ID, Params)
        else if Method = 'textDocument/semanticTokens/full' then
          HandleTextDocumentSemanticTokensFull(ID, Params)
        else if Method = 'textDocument/references' then
          HandleTextDocumentReferences(ID, Params)
        else if Method = 'textDocument/foldingRange' then
          HandleTextDocumentFoldingRange(ID, Params)
        else if Method = 'textDocument/rename' then
          HandleTextDocumentRename(ID, Params)
        else if Method = 'textDocument/typeDefinition' then
          HandleTextDocumentTypeDefinition(ID, Params)
        else if Method = 'workspace/symbol' then
          HandleWorkspaceSymbol(ID, Params)
        else if Method = 'textDocument/codeAction' then
          HandleTextDocumentCodeAction(ID, Params)
        else if Method = 'textDocument/inlayHint' then
          HandleTextDocumentInlayHint(ID, Params)
        else if Assigned(ID) then
          SendError(ID, -32601, 'Method not found: ' + Method);

      finally
        JSON.Free;
      end;

    except
      on E: Exception do
        LogMessage('Error processing message: ' + E.Message);
    end;
  end;
end;

end.

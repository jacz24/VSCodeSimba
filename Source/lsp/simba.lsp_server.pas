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
  simba.lsp_types;

type
  TSimbaLSPServer = class
  private
    FDocuments: TStringList;
    FInitialized: Boolean;
    FShutdown: Boolean;
    FSimbaPath: String;
    FBaseDeclarations: String;
    FDiagnosticErrors: TStringList;
    FDiagnosticURI: String;

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

    function GetDocumentContent(const URI: String): String;
    procedure SetDocumentContent(const URI: String; const Content: String);

    procedure SetupKeywords;
    procedure LoadBaseDeclarations;
    procedure RunDiagnostics(const URI: String);
    procedure HandleCodetoolsError(const Msg: String);
  public
    constructor Create;
    destructor Destroy; override;

    procedure Run;

    property SimbaPath: String read FSimbaPath write FSimbaPath;
  end;

procedure RunLSPServer;

implementation

uses
  Math, Process,
  simba.ide_codetools_insight,
  simba.ide_codetools_parser,
  simba.ide_codetools_paslexer,
  simba.ide_codetools_base,
  simba.initializations,
  simba.env,
  simba.simpleformatter;

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
  FDiagnosticErrors := TStringList.Create;
  FDiagnosticURI := '';
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
  FDiagnosticErrors.Free;
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
    ExePath: String;
  begin
    // Check if we ARE Simba (running with --lsp flag)
    ExePath := ParamStr(0);
    if Pos('simba', LowerCase(ExtractFileName(ExePath))) > 0 then
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

procedure TSimbaLSPServer.HandleCodetoolsError(const Msg: String);
begin
  // Collect error messages during parsing
  FDiagnosticErrors.Add(Msg);
end;

procedure TSimbaLSPServer.RunDiagnostics(const URI: String);
var
  Content, FilePath, ErrorMsg, OriginalMsg: String;
  Codeinsight: TCodeinsight;
  Diagnostics: TLSPDiagnosticArray;
  I, Line, Col, P1, P2, SearchStart: Integer;
  Diag: TLSPDiagnostic;

  // Find last occurrence of substring (search backwards)
  function RPosFrom(const SubStr, S: String; StartPos: Integer): Integer;
  var
    J: Integer;
  begin
    Result := 0;
    for J := StartPos downto 1 do
    begin
      if Copy(S, J, Length(SubStr)) = SubStr then
      begin
        Result := J;
        Exit;
      end;
    end;
  end;

begin
  Content := GetDocumentContent(URI);
  FilePath := URIToFilePath(URI);

  // Clear previous errors and set current URI for error handler
  FDiagnosticErrors.Clear;
  FDiagnosticURI := URI;

  // Parse the document to collect errors
  Codeinsight := TCodeinsight.Create;
  try
    Codeinsight.SetScript(Content, FilePath, -1);
    Codeinsight.Run;
  finally
    Codeinsight.Free;
  end;

  // Convert collected errors to diagnostics
  SetLength(Diagnostics, 0);
  for I := 0 to FDiagnosticErrors.Count - 1 do
  begin
    OriginalMsg := FDiagnosticErrors[I];
    ErrorMsg := OriginalMsg;
    Line := 0;
    Col := 0;

    // Parse error message format: "message" at line X, column Y [in file "Z"]
    // Important: We need to find the LAST occurrence of '" at line ' because
    // the error message itself might contain quotes or similar patterns.

    // First, check if there's ' in file "' at the end and find search boundary
    SearchStart := Length(OriginalMsg);
    P1 := Pos(' in file "', OriginalMsg);
    if P1 > 0 then
      SearchStart := P1 - 1;

    // Find the last '" at line ' before any file info
    P1 := RPosFrom('" at line ', OriginalMsg, SearchStart);
    if P1 > 0 then
    begin
      // Extract message (between first and last quotes before " at line")
      // The message starts after position 1 (first quote) and ends before P1
      if (Length(OriginalMsg) > 0) and (OriginalMsg[1] = '"') then
        ErrorMsg := Copy(OriginalMsg, 2, P1 - 2);

      // Extract line number
      P2 := P1 + 10; // After '" at line '
      while (P2 <= Length(OriginalMsg)) and (OriginalMsg[P2] in ['0'..'9']) do
        Inc(P2);
      Line := StrToIntDef(Copy(OriginalMsg, P1 + 10, P2 - P1 - 10), 1);

      // Extract column number - find ', column ' after line number
      P1 := Pos(', column ', Copy(OriginalMsg, P2, Length(OriginalMsg)));
      if P1 > 0 then
      begin
        P1 := P1 + P2 - 1; // Adjust to absolute position
        P2 := P1 + 9; // After ', column '
        while (P2 <= Length(OriginalMsg)) and (OriginalMsg[P2] in ['0'..'9']) do
          Inc(P2);
        Col := StrToIntDef(Copy(OriginalMsg, P1 + 9, P2 - P1 - 9), 1);
      end;
    end;

    // Create diagnostic
    Diag.Range := CreateRange(Max(0, Line - 1), Max(0, Col - 1),
                              Max(0, Line - 1), Max(0, Col - 1) + 10);
    Diag.Severity := DiagError;
    Diag.Message := ErrorMsg;
    Diag.Source := 'simba';

    SetLength(Diagnostics, Length(Diagnostics) + 1);
    Diagnostics[High(Diagnostics)] := Diag;
  end;

  // Publish diagnostics (empty array clears previous diagnostics)
  PublishDiagnostics(URI, Diagnostics);
  FDiagnosticErrors.Clear;
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

procedure TSimbaLSPServer.HandleInitialize(const ID: TJSONData; const Params: TJSONObject);
var
  Result, Capabilities, CompletionProvider, SignatureProvider: TJSONObject;
  SemanticProvider, SemanticLegend: TJSONObject;
  TriggerChars, TokenTypes, TokenModifiers: TJSONArray;
  TokenType: TLSPSemanticTokenType;
  TokenMod: TLSPSemanticTokenModifier;
begin
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
  LogMessage('Capabilities: completion, hover, definition, signatureHelp, documentSymbol, diagnostics, semanticTokens, references, foldingRange, rename, typeDefinition, workspaceSymbol, formatting');
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
  // Nothing to do - we already have the content from didChange
end;

procedure TSimbaLSPServer.HandleTextDocumentCompletion(const ID: TJSONData; const Params: TJSONObject);
var
  TextDocument, Position: TJSONObject;
  URI, Content, FilePath, Expr: String;
  Line, Character, CaretPos, I, LineStart, ExprStart, DotPos: Integer;
  Codeinsight: TCodeinsight;
  Decls, Members: TDeclarationArray;
  Items: TJSONArray;
  Item: TLSPCompletionItem;
  Decl, ExprDecl: TDeclaration;
  IsMemberCompletion: Boolean;
  Ch: Char;
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
    // Calculate caret position in the content
    CaretPos := 0;
    LineStart := 1;
    for I := 1 to Length(Content) do
    begin
      if Line = 0 then
      begin
        CaretPos := LineStart + Character;
        Break;
      end;
      if Content[I] = #10 then
      begin
        Dec(Line);
        LineStart := I + 1;
      end;
    end;
    if CaretPos = 0 then
      CaretPos := LineStart + Character;

    // Check if this is member completion (e.g., "Antiban." or "Antiban.Do")
    // Look backwards from cursor to find a dot
    IsMemberCompletion := False;
    DotPos := 0;
    I := CaretPos - 1;

    // Skip any partial identifier being typed
    while (I >= 1) and (Content[I] in ['a'..'z', 'A'..'Z', '0'..'9', '_']) do
      Dec(I);

    // Check if there's a dot
    if (I >= 1) and (Content[I] = '.') then
    begin
      IsMemberCompletion := True;
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
          // Handle parentheses for function calls like Func().Member
          if Ch = ')' then
          begin
            // Skip back to matching '('
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

    // Create codeinsight and get completions
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

            if Decl is TDeclaration_Method then
              Item.Kind := cikFunction
            else if Decl is TDeclaration_Type then
              Item.Kind := cikClass
            else if Decl is TDeclaration_Const then
              Item.Kind := cikConstant
            else if Decl is TDeclaration_EnumElement then
              Item.Kind := cikEnumMember
            else if Decl is TDeclaration_Field then
              Item.Kind := cikField
            else if Decl is TDeclaration_Property then
              Item.Kind := cikProperty
            else
              Item.Kind := cikVariable;

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

            if Decl is TDeclaration_Method then
              Item.Kind := cikFunction
            else if Decl is TDeclaration_Type then
              Item.Kind := cikClass
            else if Decl is TDeclaration_Const then
              Item.Kind := cikConstant
            else if Decl is TDeclaration_EnumElement then
              Item.Kind := cikEnumMember
            else
              Item.Kind := cikVariable;

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

            if Decl is TDeclaration_Method then
              Item.Kind := cikFunction
            else if Decl is TDeclaration_Type then
              Item.Kind := cikClass
            else if Decl is TDeclaration_Const then
              Item.Kind := cikConstant
            else if Decl is TDeclaration_EnumElement then
              Item.Kind := cikEnumMember
            else
              Item.Kind := cikVariable;

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
  Line, Character, CaretPos, I, LineStart, WordStart, WordEnd: Integer;
  Codeinsight: TCodeinsight;
  Decls: TDeclarationArray;
  Hover: TLSPHover;
  HoverResult: TJSONObject;
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
    // Calculate caret position
    CaretPos := 0;
    LineStart := 1;
    for I := 1 to Length(Content) do
    begin
      if Line = 0 then
      begin
        CaretPos := LineStart + Character;
        Break;
      end;
      if Content[I] = #10 then
      begin
        Dec(Line);
        LineStart := I + 1;
      end;
    end;
    if CaretPos = 0 then
      CaretPos := LineStart + Character;

    // Extract word at position
    WordStart := CaretPos;
    WordEnd := CaretPos;
    while (WordStart > 1) and (Content[WordStart - 1] in ['a'..'z', 'A'..'Z', '0'..'9', '_']) do
      Dec(WordStart);
    while (WordEnd <= Length(Content)) and (Content[WordEnd] in ['a'..'z', 'A'..'Z', '0'..'9', '_']) do
      Inc(WordEnd);
    Word := Copy(Content, WordStart, WordEnd - WordStart);

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
          Position.Get('line', 0),
          Character - (CaretPos - WordStart),
          Position.Get('line', 0),
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
  Line, Character, CaretPos, I, LineStart, WordStart, WordEnd, DotPos, ExprStart: Integer;
  Codeinsight: TCodeinsight;
  Decls, Members: TDeclarationArray;
  Location: TLSPLocation;
  IsMemberAccess: Boolean;
  ExprDecl, MemberDecl, Decl: TDeclaration;
  Ch: Char;
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
    // Calculate caret position
    CaretPos := 0;
    LineStart := 1;
    for I := 1 to Length(Content) do
    begin
      if Line = 0 then
      begin
        CaretPos := LineStart + Character;
        Break;
      end;
      if Content[I] = #10 then
      begin
        Dec(Line);
        LineStart := I + 1;
      end;
    end;
    if CaretPos = 0 then
      CaretPos := LineStart + Character;

    // Extract word at position
    WordStart := CaretPos;
    WordEnd := CaretPos;
    while (WordStart > 1) and (Content[WordStart - 1] in ['a'..'z', 'A'..'Z', '0'..'9', '_']) do
      Dec(WordStart);
    while (WordEnd <= Length(Content)) and (Content[WordEnd] in ['a'..'z', 'A'..'Z', '0'..'9', '_']) do
      Inc(WordEnd);
    Word := Copy(Content, WordStart, WordEnd - WordStart);

    if Word = '' then
    begin
      SendResponse(ID, TJSONNull.Create);
      Exit;
    end;

    // Check if this is a member access (e.g., "Antiban.Zoom" with cursor on "Zoom")
    // Look backwards from the word start to find a dot
    IsMemberAccess := False;
    DotPos := 0;
    I := WordStart - 1;

    // Skip whitespace before the word
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
          // Handle parentheses for function calls like Func().Member
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

        // If we found the member, return its location (only if file exists)
        if Assigned(MemberDecl) and (MemberDecl.DocPos.FileName <> '') and
           (MemberDecl.DocPos.Line > 0) then
        begin
          // Check if file exists (built-in declarations have section names like "Base" which aren't real files)
          {$IFDEF WINDOWS}
          if SameText(MemberDecl.DocPos.FileName, FilePath) then
          begin
            Location.URI := URI;
            Location.Range := CreateRange(
              MemberDecl.DocPos.Line - 1,
              Max(0, MemberDecl.DocPos.Col - 1),
              MemberDecl.DocPos.Line - 1,
              Max(0, MemberDecl.DocPos.Col - 1) + Length(Word)
            );
            SendResponse(ID, LocationToJSON(Location));
            Exit;
          end
          else if FileExists(MemberDecl.DocPos.FileName) then
          begin
            Location.URI := FilePathToURI(MemberDecl.DocPos.FileName);
            Location.Range := CreateRange(
              MemberDecl.DocPos.Line - 1,
              Max(0, MemberDecl.DocPos.Col - 1),
              MemberDecl.DocPos.Line - 1,
              Max(0, MemberDecl.DocPos.Col - 1) + Length(Word)
            );
            SendResponse(ID, LocationToJSON(Location));
            Exit;
          end;
          {$ELSE}
          if MemberDecl.DocPos.FileName = FilePath then
          begin
            Location.URI := URI;
            Location.Range := CreateRange(
              MemberDecl.DocPos.Line - 1,
              Max(0, MemberDecl.DocPos.Col - 1),
              MemberDecl.DocPos.Line - 1,
              Max(0, MemberDecl.DocPos.Col - 1) + Length(Word)
            );
            SendResponse(ID, LocationToJSON(Location));
            Exit;
          end
          else if FileExists(MemberDecl.DocPos.FileName) then
          begin
            Location.URI := FilePathToURI(MemberDecl.DocPos.FileName);
            Location.Range := CreateRange(
              MemberDecl.DocPos.Line - 1,
              Max(0, MemberDecl.DocPos.Col - 1),
              MemberDecl.DocPos.Line - 1,
              Max(0, MemberDecl.DocPos.Col - 1) + Length(Word)
            );
            SendResponse(ID, LocationToJSON(Location));
            Exit;
          end;
          {$ENDIF}
          // File doesn't exist (built-in declaration) - show info in output
          LogMessage('Declared in: ' + FormatDeclaredIn(MemberDecl.DocPos.FileName));
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

        // Check if we have valid file position info
        if (Decl.DocPos.FileName <> '') and (Decl.DocPos.Line > 0) then
        begin
          // Check if declaration is in the same file (case-insensitive on Windows)
          {$IFDEF WINDOWS}
          if SameText(Decl.DocPos.FileName, FilePath) then
          begin
            Location.URI := URI;  // Use original URI to preserve exact path
            Location.Range := CreateRange(
              Decl.DocPos.Line - 1,
              Max(0, Decl.DocPos.Col - 1),
              Decl.DocPos.Line - 1,
              Max(0, Decl.DocPos.Col - 1) + Length(Word)
            );
            SendResponse(ID, LocationToJSON(Location));
          end
          else if FileExists(Decl.DocPos.FileName) then
          begin
            Location.URI := FilePathToURI(Decl.DocPos.FileName);
            Location.Range := CreateRange(
              Decl.DocPos.Line - 1,
              Max(0, Decl.DocPos.Col - 1),
              Decl.DocPos.Line - 1,
              Max(0, Decl.DocPos.Col - 1) + Length(Word)
            );
            SendResponse(ID, LocationToJSON(Location));
          end
          else
          begin
            // File doesn't exist (built-in declaration) - show info in output
            LogMessage('Declared in: ' + FormatDeclaredIn(Decl.DocPos.FileName));
            LogMessage('Declaration: ' + Decl.Header);
            SendResponse(ID, TJSONNull.Create);
          end;
          {$ELSE}
          if Decl.DocPos.FileName = FilePath then
          begin
            Location.URI := URI;
            Location.Range := CreateRange(
              Decl.DocPos.Line - 1,
              Max(0, Decl.DocPos.Col - 1),
              Decl.DocPos.Line - 1,
              Max(0, Decl.DocPos.Col - 1) + Length(Word)
            );
            SendResponse(ID, LocationToJSON(Location));
          end
          else if FileExists(Decl.DocPos.FileName) then
          begin
            Location.URI := FilePathToURI(Decl.DocPos.FileName);
            Location.Range := CreateRange(
              Decl.DocPos.Line - 1,
              Max(0, Decl.DocPos.Col - 1),
              Decl.DocPos.Line - 1,
              Max(0, Decl.DocPos.Col - 1) + Length(Word)
            );
            SendResponse(ID, LocationToJSON(Location));
          end
          else
          begin
            // File doesn't exist (built-in declaration) - show info in output
            LogMessage('Declared in: ' + FormatDeclaredIn(Decl.DocPos.FileName));
            LogMessage('Declaration: ' + Decl.Header);
            SendResponse(ID, TJSONNull.Create);
          end;
          {$ENDIF}
        end
        else
        begin
          // Built-in declaration without file position - show info in output
          LogMessage('Declared in: ' + FormatDeclaredIn(Decl.DocPos.FileName));
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
  URI, Content, FilePath, FuncName: String;
  Line, Character, CaretPos, I, LineStart, ParenPos, ParamIndex: Integer;
  Codeinsight: TCodeinsight;
  Decls: TDeclarationArray;
  SigHelp: TLSPSignatureHelp;
  Method: TDeclaration_Method;
  MethodParams: TDeclarationArray;
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
    // Calculate caret position
    CaretPos := 0;
    LineStart := 1;
    for I := 1 to Length(Content) do
    begin
      if Line = 0 then
      begin
        CaretPos := LineStart + Character;
        Break;
      end;
      if Content[I] = #10 then
      begin
        Dec(Line);
        LineStart := I + 1;
      end;
    end;
    if CaretPos = 0 then
      CaretPos := LineStart + Character;

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
    Dec(ParenPos);
    while (ParenPos > 0) and (Content[ParenPos] in [' ', #9, #10, #13]) do
      Dec(ParenPos);

    I := ParenPos;
    while (I > 0) and (Content[I] in ['a'..'z', 'A'..'Z', '0'..'9', '_']) do
      Dec(I);
    FuncName := Copy(Content, I + 1, ParenPos - I);

    if FuncName = '' then
    begin
      SendResponse(ID, TJSONNull.Create);
      Exit;
    end;

    Codeinsight := TCodeinsight.Create;
    try
      Codeinsight.SetScript(Content, FilePath, CaretPos);
      Codeinsight.Run;

      Decls := Codeinsight.Get(FuncName);
      if (Length(Decls) > 0) and (Decls[0] is TDeclaration_Method) then
      begin
        Method := TDeclaration_Method(Decls[0]);

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
  Line, Character, CaretPos, I, LineStart, WordStart, WordEnd: Integer;
  Codeinsight: TCodeinsight;
  Decls: TDeclarationArray;
  Decl: TDeclaration;
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
    // Calculate caret position
    CaretPos := 0;
    LineStart := 1;
    for I := 1 to Length(Content) do
    begin
      if Line = 0 then
      begin
        CaretPos := LineStart + Character;
        Break;
      end;
      if Content[I] = #10 then
      begin
        Dec(Line);
        LineStart := I + 1;
      end;
    end;
    if CaretPos = 0 then
      CaretPos := LineStart + Character;

    // Extract word at position
    WordStart := CaretPos;
    WordEnd := CaretPos;
    while (WordStart > 1) and (Content[WordStart - 1] in ['a'..'z', 'A'..'Z', '0'..'9', '_']) do
      Dec(WordStart);
    while (WordEnd <= Length(Content)) and (Content[WordEnd] in ['a'..'z', 'A'..'Z', '0'..'9', '_']) do
      Inc(WordEnd);
    Word := Copy(Content, WordStart, WordEnd - WordStart);

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
              if Decl is TDeclaration_Method then
                FoldRange.Add('kind', 'region')
              else
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
  Line, Character, CaretPos, I, LineStart, WordStart, WordEnd: Integer;
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
    // Calculate caret position
    CaretPos := 0;
    LineStart := 1;
    for I := 1 to Length(Content) do
    begin
      if Line = 0 then
      begin
        CaretPos := LineStart + Character;
        Break;
      end;
      if Content[I] = #10 then
      begin
        Dec(Line);
        LineStart := I + 1;
      end;
    end;
    if CaretPos = 0 then
      CaretPos := LineStart + Character;

    // Extract word at position
    WordStart := CaretPos;
    WordEnd := CaretPos;
    while (WordStart > 1) and (Content[WordStart - 1] in ['a'..'z', 'A'..'Z', '0'..'9', '_']) do
      Dec(WordStart);
    while (WordEnd <= Length(Content)) and (Content[WordEnd] in ['a'..'z', 'A'..'Z', '0'..'9', '_']) do
      Inc(WordEnd);
    Word := Copy(Content, WordStart, WordEnd - WordStart);

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
  Line, Character, CaretPos, I, LineStart, WordStart, WordEnd: Integer;
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
    // Calculate caret position
    CaretPos := 0;
    LineStart := 1;
    for I := 1 to Length(Content) do
    begin
      if Line = 0 then
      begin
        CaretPos := LineStart + Character;
        Break;
      end;
      if Content[I] = #10 then
      begin
        Dec(Line);
        LineStart := I + 1;
      end;
    end;
    if CaretPos = 0 then
      CaretPos := LineStart + Character;

    // Extract word at position
    WordStart := CaretPos;
    WordEnd := CaretPos;
    while (WordStart > 1) and (Content[WordStart - 1] in ['a'..'z', 'A'..'Z', '0'..'9', '_']) do
      Dec(WordStart);
    while (WordEnd <= Length(Content)) and (Content[WordEnd] in ['a'..'z', 'A'..'Z', '0'..'9', '_']) do
      Inc(WordEnd);
    Word := Copy(Content, WordStart, WordEnd - WordStart);

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
begin
  Query := Params.Get('query', '');

  Symbols := TJSONArray.Create;
  try
    // Search through all open documents
    for DocIdx := 0 to FDocuments.Count - 1 do
    begin
      URI := FDocuments[DocIdx];
      FilePath := URIToFilePath(URI);
      Content := TStringList(FDocuments.Objects[DocIdx]).Text;

      Codeinsight := TCodeinsight.Create;
      try
        Codeinsight.SetScript(Content, FilePath, -1);
        Codeinsight.Run;

        Decls := Codeinsight.ScriptParser.Items.ToArray;
        for I := 0 to High(Decls) do
        begin
          Decl := Decls[I];
          // Filter by query if provided
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
            end;
          end;
        end;

      finally
        Codeinsight.Free;
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

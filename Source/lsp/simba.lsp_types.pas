{
  Author: Raymond van Venetië and Merlijn Wajer
  Project: Simba (https://github.com/MerlijnWajer/Simba)
  License: GNU General Public License (https://www.gnu.org/licenses/gpl-3.0)

  LSP (Language Server Protocol) type definitions for Simba IDE integration.
}
unit simba.lsp_types;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson;

type
  // Position in a text document (0-based line and character)
  TLSPPosition = record
    Line: Integer;
    Character: Integer;
  end;

  // A range in a text document
  TLSPRange = record
    StartPos: TLSPPosition;
    EndPos: TLSPPosition;
  end;

  // Location in a document
  TLSPLocation = record
    URI: String;
    Range: TLSPRange;
  end;

  // Represents a diagnostic (error, warning, info, hint)
  TLSPDiagnosticSeverity = (
    DiagError = 1,
    DiagWarning = 2,
    DiagInformation = 3,
    DiagHint = 4
  );

  TLSPDiagnostic = record
    Range: TLSPRange;
    Severity: TLSPDiagnosticSeverity;
    Source: String;
    Message: String;
  end;
  TLSPDiagnosticArray = array of TLSPDiagnostic;

  // Completion item kinds
  TLSPCompletionItemKind = (
    cikText = 1,
    cikMethod = 2,
    cikFunction = 3,
    cikConstructor = 4,
    cikField = 5,
    cikVariable = 6,
    cikClass = 7,
    cikInterface = 8,
    cikModule = 9,
    cikProperty = 10,
    cikUnit = 11,
    cikValue = 12,
    cikEnum = 13,
    cikKeyword = 14,
    cikSnippet = 15,
    cikColor = 16,
    cikFile = 17,
    cikReference = 18,
    cikFolder = 19,
    cikEnumMember = 20,
    cikConstant = 21,
    cikStruct = 22,
    cikEvent = 23,
    cikOperator = 24,
    cikTypeParameter = 25
  );

  // Completion item
  TLSPCompletionItem = record
    LabelText: String;
    Kind: TLSPCompletionItemKind;
    Detail: String;
    Documentation: String;
    InsertText: String;
  end;
  TLSPCompletionItemArray = array of TLSPCompletionItem;

  // Symbol kinds for document symbols
  TLSPSymbolKind = (
    skFile = 1,
    skModule = 2,
    skNamespace = 3,
    skPackage = 4,
    skClass = 5,
    skMethod = 6,
    skProperty = 7,
    skField = 8,
    skConstructor = 9,
    skEnum = 10,
    skInterface = 11,
    skFunction = 12,
    skVariable = 13,
    skConstant = 14,
    skString = 15,
    skNumber = 16,
    skBoolean = 17,
    skArray = 18,
    skObject = 19,
    skKey = 20,
    skNull = 21,
    skEnumMember = 22,
    skStruct = 23,
    skEvent = 24,
    skOperator = 25,
    skTypeParameter = 26
  );

  // Document symbol
  TLSPDocumentSymbol = record
    Name: String;
    Kind: TLSPSymbolKind;
    Range: TLSPRange;
    SelectionRange: TLSPRange;
  end;
  TLSPDocumentSymbolArray = array of TLSPDocumentSymbol;

  // Hover result
  TLSPHover = record
    Contents: String;
    Range: TLSPRange;
  end;

  // Signature help
  TLSPParameterInformation = record
    LabelText: String;
    Documentation: String;
  end;
  TLSPParameterInformationArray = array of TLSPParameterInformation;

  TLSPSignatureInformation = record
    LabelText: String;
    Documentation: String;
    Parameters: TLSPParameterInformationArray;
  end;
  TLSPSignatureInformationArray = array of TLSPSignatureInformation;

  TLSPSignatureHelp = record
    Signatures: TLSPSignatureInformationArray;
    ActiveSignature: Integer;
    ActiveParameter: Integer;
  end;

  // Semantic token types - indices into the legend
  // These must match the order declared in the server capabilities
  TLSPSemanticTokenType = (
    sttNamespace = 0,
    sttType = 1,
    sttClass = 2,
    sttEnum = 3,
    sttInterface = 4,
    sttStruct = 5,
    sttTypeParameter = 6,
    sttParameter = 7,
    sttVariable = 8,
    sttProperty = 9,
    sttEnumMember = 10,
    sttEvent = 11,
    sttFunction = 12,
    sttMethod = 13,
    sttMacro = 14,
    sttKeyword = 15,
    sttModifier = 16,
    sttComment = 17,
    sttString = 18,
    sttNumber = 19,
    sttRegexp = 20,
    sttOperator = 21
  );

  // Semantic token modifiers - bit flags
  TLSPSemanticTokenModifier = (
    stmDeclaration = 0,
    stmDefinition = 1,
    stmReadonly = 2,
    stmStatic = 3,
    stmDeprecated = 4,
    stmAbstract = 5,
    stmAsync = 6,
    stmModification = 7,
    stmDocumentation = 8,
    stmDefaultLibrary = 9
  );

  // Semantic token data (before encoding)
  TLSPSemanticToken = record
    Line: Integer;       // 0-based line number
    StartChar: Integer;  // 0-based character position
    Length: Integer;     // Token length
    TokenType: TLSPSemanticTokenType;
    Modifiers: Integer;  // Bit flags of TLSPSemanticTokenModifier
  end;
  TLSPSemanticTokenArray = array of TLSPSemanticToken;

const
  // Token type names for the legend
  SemanticTokenTypeNames: array[TLSPSemanticTokenType] of String = (
    'namespace', 'type', 'class', 'enum', 'interface', 'struct',
    'typeParameter', 'parameter', 'variable', 'property', 'enumMember',
    'event', 'function', 'method', 'macro', 'keyword', 'modifier',
    'comment', 'string', 'number', 'regexp', 'operator'
  );

  // Token modifier names for the legend
  SemanticTokenModifierNames: array[TLSPSemanticTokenModifier] of String = (
    'declaration', 'definition', 'readonly', 'static', 'deprecated',
    'abstract', 'async', 'modification', 'documentation', 'defaultLibrary'
  );

// Helper functions
function CreatePosition(Line, Character: Integer): TLSPPosition;
function CreateRange(StartLine, StartChar, EndLine, EndChar: Integer): TLSPRange;
function PositionToJSON(const Pos: TLSPPosition): TJSONObject;
function RangeToJSON(const Range: TLSPRange): TJSONObject;
function LocationToJSON(const Loc: TLSPLocation): TJSONObject;
function DiagnosticToJSON(const Diag: TLSPDiagnostic): TJSONObject;
function CompletionItemToJSON(const Item: TLSPCompletionItem): TJSONObject;
function DocumentSymbolToJSON(const Symbol: TLSPDocumentSymbol): TJSONObject;
function HoverToJSON(const Hover: TLSPHover): TJSONObject;
function SignatureHelpToJSON(const SigHelp: TLSPSignatureHelp): TJSONObject;

function FilePathToURI(const FilePath: String): String;
function URIToFilePath(const URI: String): String;
function SemanticTokensToJSON(const Tokens: TLSPSemanticTokenArray): TJSONObject;

implementation

function CreatePosition(Line, Character: Integer): TLSPPosition;
begin
  Result.Line := Line;
  Result.Character := Character;
end;

function CreateRange(StartLine, StartChar, EndLine, EndChar: Integer): TLSPRange;
begin
  Result.StartPos := CreatePosition(StartLine, StartChar);
  Result.EndPos := CreatePosition(EndLine, EndChar);
end;

function PositionToJSON(const Pos: TLSPPosition): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('line', Pos.Line);
  Result.Add('character', Pos.Character);
end;

function RangeToJSON(const Range: TLSPRange): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('start', PositionToJSON(Range.StartPos));
  Result.Add('end', PositionToJSON(Range.EndPos));
end;

function LocationToJSON(const Loc: TLSPLocation): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('uri', Loc.URI);
  Result.Add('range', RangeToJSON(Loc.Range));
end;

function DiagnosticToJSON(const Diag: TLSPDiagnostic): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('range', RangeToJSON(Diag.Range));
  Result.Add('severity', Ord(Diag.Severity));
  Result.Add('source', Diag.Source);
  Result.Add('message', Diag.Message);
end;

function CompletionItemToJSON(const Item: TLSPCompletionItem): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('label', Item.LabelText);
  Result.Add('kind', Ord(Item.Kind));
  if Item.Detail <> '' then
    Result.Add('detail', Item.Detail);
  if Item.Documentation <> '' then
    Result.Add('documentation', Item.Documentation);
  if Item.InsertText <> '' then
    Result.Add('insertText', Item.InsertText);
end;

function DocumentSymbolToJSON(const Symbol: TLSPDocumentSymbol): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('name', Symbol.Name);
  Result.Add('kind', Ord(Symbol.Kind));
  Result.Add('range', RangeToJSON(Symbol.Range));
  Result.Add('selectionRange', RangeToJSON(Symbol.SelectionRange));
end;

function HoverToJSON(const Hover: TLSPHover): TJSONObject;
var
  Contents: TJSONObject;
begin
  Result := TJSONObject.Create;
  Contents := TJSONObject.Create;
  Contents.Add('kind', 'markdown');
  Contents.Add('value', Hover.Contents);
  Result.Add('contents', Contents);
  Result.Add('range', RangeToJSON(Hover.Range));
end;

function SignatureHelpToJSON(const SigHelp: TLSPSignatureHelp): TJSONObject;
var
  Signatures, Parameters: TJSONArray;
  SigObj, ParamObj: TJSONObject;
  I, J: Integer;
begin
  Result := TJSONObject.Create;
  Signatures := TJSONArray.Create;

  for I := 0 to High(SigHelp.Signatures) do
  begin
    SigObj := TJSONObject.Create;
    SigObj.Add('label', SigHelp.Signatures[I].LabelText);
    if SigHelp.Signatures[I].Documentation <> '' then
      SigObj.Add('documentation', SigHelp.Signatures[I].Documentation);

    Parameters := TJSONArray.Create;
    for J := 0 to High(SigHelp.Signatures[I].Parameters) do
    begin
      ParamObj := TJSONObject.Create;
      ParamObj.Add('label', SigHelp.Signatures[I].Parameters[J].LabelText);
      if SigHelp.Signatures[I].Parameters[J].Documentation <> '' then
        ParamObj.Add('documentation', SigHelp.Signatures[I].Parameters[J].Documentation);
      Parameters.Add(ParamObj);
    end;
    SigObj.Add('parameters', Parameters);
    Signatures.Add(SigObj);
  end;

  Result.Add('signatures', Signatures);
  Result.Add('activeSignature', SigHelp.ActiveSignature);
  Result.Add('activeParameter', SigHelp.ActiveParameter);
end;

function FilePathToURI(const FilePath: String): String;
var
  Path: String;
begin
  // Expand relative paths to absolute
  Path := ExpandFileName(FilePath);
  {$IFDEF WINDOWS}
  Path := StringReplace(Path, '\', '/', [rfReplaceAll]);
  if (Length(Path) > 1) and (Path[2] = ':') then
    Path := '/' + Path;
  {$ENDIF}
  // Encode spaces and other special characters
  Path := StringReplace(Path, ' ', '%20', [rfReplaceAll]);
  Result := 'file://' + Path;
end;

function URIToFilePath(const URI: String): String;
begin
  Result := URI;
  if Pos('file://', Result) = 1 then
    Delete(Result, 1, 7);
  {$IFDEF WINDOWS}
  if (Length(Result) > 2) and (Result[1] = '/') and (Result[3] = ':') then
    Delete(Result, 1, 1);
  Result := StringReplace(Result, '/', '\', [rfReplaceAll]);
  {$ENDIF}
  // Decode percent-encoded characters
  Result := StringReplace(Result, '%20', ' ', [rfReplaceAll]);
  Result := StringReplace(Result, '%3A', ':', [rfReplaceAll]);
end;

function SemanticTokensToJSON(const Tokens: TLSPSemanticTokenArray): TJSONObject;
var
  Data: TJSONArray;
  I: Integer;
  PrevLine, PrevStartChar: Integer;
  DeltaLine, DeltaStartChar: Integer;
begin
  // LSP semantic tokens use a delta-encoded format:
  // Each token is encoded as 5 integers:
  //   deltaLine, deltaStartChar, length, tokenType, tokenModifiers
  // deltaLine is relative to the previous token's line
  // deltaStartChar is relative to the previous token's start char (or 0 if on new line)

  Result := TJSONObject.Create;
  Data := TJSONArray.Create;

  PrevLine := 0;
  PrevStartChar := 0;

  for I := 0 to High(Tokens) do
  begin
    DeltaLine := Tokens[I].Line - PrevLine;

    if DeltaLine = 0 then
      DeltaStartChar := Tokens[I].StartChar - PrevStartChar
    else
      DeltaStartChar := Tokens[I].StartChar;  // Reset to absolute on new line

    Data.Add(DeltaLine);
    Data.Add(DeltaStartChar);
    Data.Add(Tokens[I].Length);
    Data.Add(Ord(Tokens[I].TokenType));
    Data.Add(Tokens[I].Modifiers);

    PrevLine := Tokens[I].Line;
    PrevStartChar := Tokens[I].StartChar;
  end;

  Result.Add('data', Data);
end;

end.

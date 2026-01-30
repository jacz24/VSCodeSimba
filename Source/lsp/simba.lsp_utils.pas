{
  Author: Raymond van Venetië and Merlijn Wajer
  Project: Simba (https://github.com/MerlijnWajer/Simba)
  License: GNU General Public License (https://www.gnu.org/licenses/gpl-3.0)

  Utility functions for LSP server - extracted for testability.
}
unit simba.lsp_utils;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

{ Converts LSP line/character position to a 1-based caret position in content.
  Line and Character are 0-based (per LSP spec). }
function LSPCalculateCaretPosition(const Content: String; Line, Character: Integer): Integer;

{ Extracts the identifier at the given caret position.
  Returns the word and sets WordStart/WordEnd to the bounds (1-based). }
function LSPExtractWordAtPosition(const Content: String; CaretPos: Integer; out WordStart, WordEnd: Integer): String;

{ Parses a member access expression (e.g., "obj.member" or "a.b.c").
  Returns True if a dot was found before CaretPos.
  Expr contains the expression before the dot, DotPos is the position of the dot. }
function LSPParseMemberAccessExpression(const Content: String; CaretPos: Integer; out Expr: String; out DotPos: Integer): Boolean;

implementation

function LSPCalculateCaretPosition(const Content: String; Line, Character: Integer): Integer;
var
  I, LineStart, LineNum: Integer;
begin
  Result := 0;
  LineStart := 1;
  LineNum := Line;
  for I := 1 to Length(Content) do
  begin
    if LineNum = 0 then
    begin
      Result := LineStart + Character;
      Break;
    end;
    if Content[I] = #10 then
    begin
      Dec(LineNum);
      LineStart := I + 1;
    end;
  end;
  if Result = 0 then
    Result := LineStart + Character;
end;

function LSPExtractWordAtPosition(const Content: String; CaretPos: Integer; out WordStart, WordEnd: Integer): String;
begin
  WordStart := CaretPos;
  WordEnd := CaretPos;
  while (WordStart > 1) and (Content[WordStart - 1] in ['a'..'z', 'A'..'Z', '0'..'9', '_']) do
    Dec(WordStart);
  while (WordEnd <= Length(Content)) and (Content[WordEnd] in ['a'..'z', 'A'..'Z', '0'..'9', '_']) do
    Inc(WordEnd);
  Result := Copy(Content, WordStart, WordEnd - WordStart);
end;

function LSPParseMemberAccessExpression(const Content: String; CaretPos: Integer; out Expr: String; out DotPos: Integer): Boolean;
var
  I, ExprStart, ParenDepth: Integer;
  Ch: Char;
begin
  Result := False;
  Expr := '';
  DotPos := 0;
  I := CaretPos - 1;

  // Skip any partial identifier being typed
  while (I >= 1) and (Content[I] in ['a'..'z', 'A'..'Z', '0'..'9', '_']) do
    Dec(I);

  // Check if there's a dot
  if (I >= 1) and (Content[I] = '.') then
  begin
    Result := True;
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
          ParenDepth := 1;
          Dec(ExprStart);
          while (ExprStart >= 1) and (ParenDepth > 0) do
          begin
            if Content[ExprStart] = ')' then Inc(ParenDepth)
            else if Content[ExprStart] = '(' then Dec(ParenDepth);
            Dec(ExprStart);
          end;
        end
        // Handle brackets for array access like Arr[0].Member
        else if Ch = ']' then
        begin
          ParenDepth := 1;
          Dec(ExprStart);
          while (ExprStart >= 1) and (ParenDepth > 0) do
          begin
            if Content[ExprStart] = ']' then Inc(ParenDepth)
            else if Content[ExprStart] = '[' then Dec(ParenDepth);
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
end;

end.

{
  Unit tests for LSP utility functions.
  Run with: lazbuild lsp_utils_test.lpi && ./lsp_utils_test
  Exit code 0 = all tests pass, non-zero = failure
}
program lsp_utils_test;

{$mode objfpc}{$H+}

uses
  SysUtils,
  simba.lsp_utils;

var
  TestsPassed: Integer = 0;
  TestsFailed: Integer = 0;

procedure Check(Condition: Boolean; const TestName: String);
begin
  if Condition then
  begin
    Inc(TestsPassed);
    WriteLn('  PASS: ', TestName);
  end
  else
  begin
    Inc(TestsFailed);
    WriteLn('  FAIL: ', TestName);
  end;
end;

procedure CheckEqual(Expected, Actual: Integer; const TestName: String);
begin
  Check(Expected = Actual, TestName + Format(' (expected %d, got %d)', [Expected, Actual]));
end;

procedure CheckEqual(const Expected, Actual: String; const TestName: String);
begin
  Check(Expected = Actual, TestName + Format(' (expected "%s", got "%s")', [Expected, Actual]));
end;

{ ============================================================================ }
{ LSPCalculateCaretPosition tests }
{ ============================================================================ }

procedure TestCalculateCaretPosition;
var
  Content: String;
begin
  WriteLn('Testing LSPCalculateCaretPosition:');

  // Single line
  Content := 'Hello World';
  CheckEqual(1, LSPCalculateCaretPosition(Content, 0, 0), 'Line 0, Char 0 -> position 1');
  CheckEqual(6, LSPCalculateCaretPosition(Content, 0, 5), 'Line 0, Char 5 -> position 6');
  CheckEqual(12, LSPCalculateCaretPosition(Content, 0, 11), 'Line 0, Char 11 -> position 12 (end)');

  // Multiple lines (LF only)
  Content := 'Line1' + #10 + 'Line2' + #10 + 'Line3';
  CheckEqual(1, LSPCalculateCaretPosition(Content, 0, 0), 'Multi-line: Line 0, Char 0');
  CheckEqual(5, LSPCalculateCaretPosition(Content, 0, 4), 'Multi-line: Line 0, Char 4 (end of Line1)');
  CheckEqual(7, LSPCalculateCaretPosition(Content, 1, 0), 'Multi-line: Line 1, Char 0 (start of Line2)');
  CheckEqual(10, LSPCalculateCaretPosition(Content, 1, 3), 'Multi-line: Line 1, Char 3');
  CheckEqual(13, LSPCalculateCaretPosition(Content, 2, 0), 'Multi-line: Line 2, Char 0 (start of Line3)');

  // Empty content
  Content := '';
  CheckEqual(1, LSPCalculateCaretPosition(Content, 0, 0), 'Empty content: Line 0, Char 0');

  // Single newline
  Content := #10;
  CheckEqual(1, LSPCalculateCaretPosition(Content, 0, 0), 'Single newline: Line 0, Char 0');
  CheckEqual(2, LSPCalculateCaretPosition(Content, 1, 0), 'Single newline: Line 1, Char 0');

  // Real code example
  Content := 'program Test;' + #10 + 'begin' + #10 + '  WriteLn(''Hello'');' + #10 + 'end.';
  CheckEqual(1, LSPCalculateCaretPosition(Content, 0, 0), 'Code: start of program');
  CheckEqual(15, LSPCalculateCaretPosition(Content, 1, 0), 'Code: start of begin');
  CheckEqual(21, LSPCalculateCaretPosition(Content, 2, 0), 'Code: start of WriteLn line');
  CheckEqual(23, LSPCalculateCaretPosition(Content, 2, 2), 'Code: at WriteLn');

  WriteLn;
end;

{ ============================================================================ }
{ LSPExtractWordAtPosition tests }
{ ============================================================================ }

procedure TestExtractWordAtPosition;
var
  Content, Word: String;
  WordStart, WordEnd: Integer;
begin
  WriteLn('Testing LSPExtractWordAtPosition:');

  // Simple word
  Content := 'Hello World';
  Word := LSPExtractWordAtPosition(Content, 3, WordStart, WordEnd);
  CheckEqual('Hello', Word, 'Extract "Hello" from middle');
  CheckEqual(1, WordStart, '"Hello" starts at 1');
  CheckEqual(6, WordEnd, '"Hello" ends at 6');

  Word := LSPExtractWordAtPosition(Content, 8, WordStart, WordEnd);
  CheckEqual('World', Word, 'Extract "World" from middle');
  CheckEqual(7, WordStart, '"World" starts at 7');
  CheckEqual(12, WordEnd, '"World" ends at 12');

  // At word boundaries
  Word := LSPExtractWordAtPosition(Content, 1, WordStart, WordEnd);
  CheckEqual('Hello', Word, 'Extract word at start position');

  // Position 6 is the space, but cursor is right after "Hello" so it returns "Hello"
  // This is correct LSP behavior - cursor after word should still identify the word
  Word := LSPExtractWordAtPosition(Content, 6, WordStart, WordEnd);
  CheckEqual('Hello', Word, 'Position 6 (after Hello) still returns Hello');

  // Identifiers with underscores and numbers
  Content := 'my_var123 + other_var';
  Word := LSPExtractWordAtPosition(Content, 5, WordStart, WordEnd);
  CheckEqual('my_var123', Word, 'Extract identifier with underscore and numbers');
  CheckEqual(1, WordStart, 'my_var123 starts at 1');
  CheckEqual(10, WordEnd, 'my_var123 ends at 10');

  // Cursor at different parts of word
  Content := 'SomeIdentifier';
  Word := LSPExtractWordAtPosition(Content, 1, WordStart, WordEnd);
  CheckEqual('SomeIdentifier', Word, 'Extract from position 1');
  Word := LSPExtractWordAtPosition(Content, 7, WordStart, WordEnd);
  CheckEqual('SomeIdentifier', Word, 'Extract from position 7 (middle)');
  Word := LSPExtractWordAtPosition(Content, 14, WordStart, WordEnd);
  CheckEqual('SomeIdentifier', Word, 'Extract from position 14 (end)');

  // Special characters break words
  Content := 'func(arg)';
  Word := LSPExtractWordAtPosition(Content, 2, WordStart, WordEnd);
  CheckEqual('func', Word, 'Extract "func" before paren');
  Word := LSPExtractWordAtPosition(Content, 6, WordStart, WordEnd);
  CheckEqual('arg', Word, 'Extract "arg" inside parens');

  // Empty/whitespace
  Content := '   ';
  Word := LSPExtractWordAtPosition(Content, 2, WordStart, WordEnd);
  CheckEqual('', Word, 'Whitespace only returns empty');

  WriteLn;
end;

{ ============================================================================ }
{ LSPParseMemberAccessExpression tests }
{ ============================================================================ }

procedure TestParseMemberAccessExpression;
var
  Content, Expr: String;
  DotPos: Integer;
  IsMember: Boolean;
begin
  WriteLn('Testing LSPParseMemberAccessExpression:');

  // Simple member access: obj.member
  Content := 'obj.member';
  IsMember := LSPParseMemberAccessExpression(Content, 10, Expr, DotPos);
  Check(IsMember, 'obj.member is member access');
  CheckEqual('obj', Expr, 'Expression is "obj"');
  CheckEqual(4, DotPos, 'Dot at position 4');

  // Cursor in middle of member name
  Content := 'obj.memb';
  IsMember := LSPParseMemberAccessExpression(Content, 8, Expr, DotPos);
  Check(IsMember, 'obj.memb (partial) is member access');
  CheckEqual('obj', Expr, 'Expression is "obj"');

  // Just after the dot
  Content := 'obj.';
  IsMember := LSPParseMemberAccessExpression(Content, 5, Expr, DotPos);
  Check(IsMember, 'obj. is member access');
  CheckEqual('obj', Expr, 'Expression is "obj"');

  // No member access
  Content := 'standalone';
  IsMember := LSPParseMemberAccessExpression(Content, 5, Expr, DotPos);
  Check(not IsMember, 'standalone is not member access');

  // Chained access: a.b.c
  Content := 'a.b.c';
  IsMember := LSPParseMemberAccessExpression(Content, 5, Expr, DotPos);
  Check(IsMember, 'a.b.c is member access');
  CheckEqual('a.b', Expr, 'Expression is "a.b"');
  CheckEqual(4, DotPos, 'Dot at position 4');

  // Function call then member: Func().Member
  Content := 'Func().Member';
  IsMember := LSPParseMemberAccessExpression(Content, 13, Expr, DotPos);
  Check(IsMember, 'Func().Member is member access');
  CheckEqual('Func()', Expr, 'Expression is "Func()"');
  CheckEqual(7, DotPos, 'Dot at position 7');

  // Function with args: Func(a, b).Member
  Content := 'Func(a, b).Member';
  IsMember := LSPParseMemberAccessExpression(Content, 17, Expr, DotPos);
  Check(IsMember, 'Func(a, b).Member is member access');
  CheckEqual('Func(a, b)', Expr, 'Expression is "Func(a, b)"');

  // Array access: Arr[0].Member
  Content := 'Arr[0].Member';
  IsMember := LSPParseMemberAccessExpression(Content, 13, Expr, DotPos);
  Check(IsMember, 'Arr[0].Member is member access');
  CheckEqual('Arr[0]', Expr, 'Expression is "Arr[0]"');

  // Nested brackets: Arr[i[0]].Member
  Content := 'Arr[i[0]].Member';
  IsMember := LSPParseMemberAccessExpression(Content, 16, Expr, DotPos);
  Check(IsMember, 'Arr[i[0]].Member is member access');
  CheckEqual('Arr[i[0]]', Expr, 'Expression is "Arr[i[0]]"');

  // Whitespace before dot: obj .member
  Content := 'obj .member';
  IsMember := LSPParseMemberAccessExpression(Content, 11, Expr, DotPos);
  Check(IsMember, 'obj .member (space before dot) is member access');
  CheckEqual('obj', Expr, 'Expression is "obj"');

  // Complex: GetList()[0].Items[1].Name
  Content := 'GetList()[0].Items[1].Name';
  IsMember := LSPParseMemberAccessExpression(Content, 26, Expr, DotPos);
  Check(IsMember, 'Complex chained access is member access');
  CheckEqual('GetList()[0].Items[1]', Expr, 'Expression is "GetList()[0].Items[1]"');

  // At start of content (no member access possible)
  Content := '.member';
  IsMember := LSPParseMemberAccessExpression(Content, 7, Expr, DotPos);
  Check(IsMember, '.member technically has a dot');
  CheckEqual('', Expr, 'Expression before dot is empty');

  WriteLn;
end;

{ ============================================================================ }
{ Main }
{ ============================================================================ }

begin
  WriteLn('========================================');
  WriteLn('LSP Utils Unit Tests');
  WriteLn('========================================');
  WriteLn;

  TestCalculateCaretPosition;
  TestExtractWordAtPosition;
  TestParseMemberAccessExpression;

  WriteLn('========================================');
  WriteLn(Format('Results: %d passed, %d failed', [TestsPassed, TestsFailed]));
  WriteLn('========================================');

  if TestsFailed > 0 then
    Halt(1)
  else
    Halt(0);
end.

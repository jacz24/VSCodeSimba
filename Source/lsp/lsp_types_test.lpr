{
  Unit tests for LSP type functions (URI handling, etc.).
  Run with: lazbuild lsp_types_test.lpi && ./lsp_types_test
  Exit code 0 = all tests pass, non-zero = failure
}
program lsp_types_test;

{$mode objfpc}{$H+}

uses
  SysUtils,
  simba.lsp_types;

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

procedure CheckEqual(const Expected, Actual: String; const TestName: String);
begin
  if Expected = Actual then
  begin
    Inc(TestsPassed);
    WriteLn('  PASS: ', TestName);
  end
  else
  begin
    Inc(TestsFailed);
    WriteLn('  FAIL: ', TestName);
    WriteLn('        Expected: "', Expected, '"');
    WriteLn('        Actual:   "', Actual, '"');
  end;
end;

{ ============================================================================ }
{ FilePathToURI tests }
{ ============================================================================ }

procedure TestFilePathToURI;
begin
  WriteLn('Testing FilePathToURI:');

  {$IFDEF WINDOWS}
  // Windows absolute paths
  CheckEqual('file:///C:/Users/test.simba',
             FilePathToURI('C:\Users\test.simba'),
             'Windows absolute path');

  CheckEqual('file:///D:/Projects/Simba/script.simba',
             FilePathToURI('D:\Projects\Simba\script.simba'),
             'Windows path with different drive');

  // Spaces in path
  CheckEqual('file:///C:/My%20Documents/test.simba',
             FilePathToURI('C:\My Documents\test.simba'),
             'Windows path with spaces');

  // Multiple spaces
  CheckEqual('file:///C:/Users/My%20User%20Name/test.simba',
             FilePathToURI('C:\Users\My User Name\test.simba'),
             'Windows path with multiple spaces');

  // Deep nested path
  CheckEqual('file:///C:/a/b/c/d/e/f.simba',
             FilePathToURI('C:\a\b\c\d\e\f.simba'),
             'Windows deeply nested path');
  {$ELSE}
  // Unix absolute paths
  CheckEqual('file:///home/user/test.simba',
             FilePathToURI('/home/user/test.simba'),
             'Unix absolute path');

  CheckEqual('file:///usr/local/simba/scripts/test.simba',
             FilePathToURI('/usr/local/simba/scripts/test.simba'),
             'Unix path with multiple directories');

  // Spaces in path
  CheckEqual('file:///home/user/My%20Documents/test.simba',
             FilePathToURI('/home/user/My Documents/test.simba'),
             'Unix path with spaces');
  {$ENDIF}

  WriteLn;
end;

{ ============================================================================ }
{ URIToFilePath tests }
{ ============================================================================ }

procedure TestURIToFilePath;
begin
  WriteLn('Testing URIToFilePath:');

  {$IFDEF WINDOWS}
  // Windows URIs
  CheckEqual('C:\Users\test.simba',
             URIToFilePath('file:///C:/Users/test.simba'),
             'Windows URI to path');

  CheckEqual('D:\Projects\Simba\script.simba',
             URIToFilePath('file:///D:/Projects/Simba/script.simba'),
             'Windows URI with different drive');

  // Spaces (percent-encoded)
  CheckEqual('C:\My Documents\test.simba',
             URIToFilePath('file:///C:/My%20Documents/test.simba'),
             'Windows URI with encoded spaces');

  // Multiple spaces
  CheckEqual('C:\Users\My User Name\test.simba',
             URIToFilePath('file:///C:/Users/My%20User%20Name/test.simba'),
             'Windows URI with multiple encoded spaces');

  // Colons in path (encoded)
  CheckEqual('C:\test:file.simba',
             URIToFilePath('file:///C:/test%3Afile.simba'),
             'Windows URI with encoded colon');

  // Already has backslashes (shouldn't happen but handle gracefully)
  CheckEqual('C:\Users\test.simba',
             URIToFilePath('file:///C:\Users\test.simba'),
             'Windows URI with backslashes');
  {$ELSE}
  // Unix URIs
  CheckEqual('/home/user/test.simba',
             URIToFilePath('file:///home/user/test.simba'),
             'Unix URI to path');

  CheckEqual('/usr/local/simba/scripts/test.simba',
             URIToFilePath('file:///usr/local/simba/scripts/test.simba'),
             'Unix URI with multiple directories');

  // Spaces (percent-encoded)
  CheckEqual('/home/user/My Documents/test.simba',
             URIToFilePath('file:///home/user/My%20Documents/test.simba'),
             'Unix URI with encoded spaces');
  {$ENDIF}

  WriteLn;
end;

{ ============================================================================ }
{ Round-trip tests (FilePathToURI -> URIToFilePath) }
{ ============================================================================ }

procedure TestURIRoundTrip;
var
  OriginalPath, ConvertedBack: String;
begin
  WriteLn('Testing URI round-trip conversion:');

  {$IFDEF WINDOWS}
  OriginalPath := 'C:\Users\test.simba';
  ConvertedBack := URIToFilePath(FilePathToURI(OriginalPath));
  CheckEqual(OriginalPath, ConvertedBack, 'Round-trip: simple Windows path');

  OriginalPath := 'C:\My Documents\Scripts\test.simba';
  ConvertedBack := URIToFilePath(FilePathToURI(OriginalPath));
  CheckEqual(OriginalPath, ConvertedBack, 'Round-trip: Windows path with spaces');

  OriginalPath := 'D:\Projects\Simba\Includes\SRL\SRL.simba';
  ConvertedBack := URIToFilePath(FilePathToURI(OriginalPath));
  CheckEqual(OriginalPath, ConvertedBack, 'Round-trip: deep Windows path');
  {$ELSE}
  OriginalPath := '/home/user/test.simba';
  ConvertedBack := URIToFilePath(FilePathToURI(OriginalPath));
  CheckEqual(OriginalPath, ConvertedBack, 'Round-trip: simple Unix path');

  OriginalPath := '/home/user/My Documents/Scripts/test.simba';
  ConvertedBack := URIToFilePath(FilePathToURI(OriginalPath));
  CheckEqual(OriginalPath, ConvertedBack, 'Round-trip: Unix path with spaces');
  {$ENDIF}

  WriteLn;
end;

{ ============================================================================ }
{ Main }
{ ============================================================================ }

begin
  WriteLn('========================================');
  WriteLn('LSP Types Unit Tests');
  WriteLn('========================================');
  WriteLn;

  TestFilePathToURI;
  TestURIToFilePath;
  TestURIRoundTrip;

  WriteLn('========================================');
  WriteLn(Format('Results: %d passed, %d failed', [TestsPassed, TestsFailed]));
  WriteLn('========================================');

  if TestsFailed > 0 then
    Halt(1)
  else
    Halt(0);
end.

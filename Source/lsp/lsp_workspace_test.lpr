{
  Unit tests for workspace file discovery and caching.
  Run with: lazbuild lsp_workspace_test.lpi && ./lsp_workspace_test
  Exit code 0 = all tests pass, non-zero = failure
}
program lsp_workspace_test;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes,
  simba.initializations,
  simba.lsp_workspace;

var
  TestsPassed: Integer = 0;
  TestsFailed: Integer = 0;
  TempDir: String;

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

procedure CreateTestWorkspace;
var
  F: TextFile;
begin
  TempDir := GetTempDir + 'simba_workspace_test' + PathDelim;
  ForceDirectories(TempDir);
  ForceDirectories(TempDir + 'subdir');
  ForceDirectories(TempDir + '.git');

  AssignFile(F, TempDir + 'main.simba');
  Rewrite(F);
  WriteLn(F, 'program Test;');
  WriteLn(F, 'procedure MyProc;');
  WriteLn(F, 'begin');
  WriteLn(F, 'end;');
  WriteLn(F, 'begin');
  WriteLn(F, 'end.');
  CloseFile(F);

  AssignFile(F, TempDir + 'subdir' + PathDelim + 'helper.simba');
  Rewrite(F);
  WriteLn(F, 'function HelperFunc: Integer;');
  WriteLn(F, 'begin');
  WriteLn(F, '  Result := 42;');
  WriteLn(F, 'end;');
  CloseFile(F);

  AssignFile(F, TempDir + '.git' + PathDelim + 'hooks.simba');
  Rewrite(F);
  WriteLn(F, 'procedure GitHook; begin end;');
  CloseFile(F);

  AssignFile(F, TempDir + 'readme.txt');
  Rewrite(F);
  WriteLn(F, 'This is a readme');
  CloseFile(F);
end;

procedure CleanupTestWorkspace;
  procedure DeleteDir(const Dir: String);
  var
    SR: TSearchRec;
  begin
    if FindFirst(Dir + '*', faAnyFile, SR) = 0 then
    begin
      repeat
        if (SR.Name <> '.') and (SR.Name <> '..') then
        begin
          if (SR.Attr and faDirectory) <> 0 then
            DeleteDir(Dir + SR.Name + PathDelim)
          else
            DeleteFile(Dir + SR.Name);
        end;
      until FindNext(SR) <> 0;
      FindClose(SR);
    end;
    RemoveDir(Dir);
  end;
begin
  DeleteDir(TempDir);
end;

procedure TestFindSimbaFiles;
var
  Files: TStringList;
begin
  WriteLn('Testing FindSimbaFiles:');

  Files := FindSimbaFiles(TempDir);
  try
    CheckEqual(2, Files.Count, 'Should find 2 .simba files (excluding .git)');
    Check(Files.IndexOf(TempDir + 'main.simba') >= 0, 'Should find main.simba');
    Check(Files.IndexOf(TempDir + 'subdir' + PathDelim + 'helper.simba') >= 0, 'Should find subdir/helper.simba');
    Check(Files.IndexOf(TempDir + '.git' + PathDelim + 'hooks.simba') < 0, 'Should exclude .git/hooks.simba');
  finally
    Files.Free;
  end;

  Files := FindSimbaFiles('C:\nonexistent\path');
  try
    CheckEqual(0, Files.Count, 'Non-existent directory returns empty list');
  finally
    Files.Free;
  end;

  Files := FindSimbaFiles('');
  try
    CheckEqual(0, Files.Count, 'Empty path returns empty list');
  finally
    Files.Free;
  end;

  WriteLn;
end;

{ ============================================================================ }
{ TWorkspaceIndex cache tests }
{ ============================================================================ }

procedure TestWorkspaceIndexCache;
var
  Index: TWorkspaceIndex;
  Results: TWorkspaceCachedDeclArray;
  F: TextFile;
begin
  WriteLn('Testing TWorkspaceIndex cache:');

  Index := TWorkspaceIndex.Create;
  try
    Index.SetWorkspaceRoot(TempDir);

    // First search - should parse files
    Results := Index.Search('');
    Check(Length(Results) >= 2, 'Should find at least 2 declarations (MyProc, HelperFunc)');

    // Search for specific symbol
    Results := Index.Search('MyProc');
    CheckEqual(1, Length(Results), 'Should find exactly 1 match for MyProc');
    Check(Results[0].Name = 'MyProc', 'Found declaration should be MyProc');

    // Search for partial match
    Results := Index.Search('helper');
    CheckEqual(1, Length(Results), 'Should find 1 match for "helper" (case insensitive)');

    // Modify a file and verify cache invalidation
    // FileAge on Windows uses DOS timestamp with 2-second resolution
    Sleep(2100);
    AssignFile(F, TempDir + 'main.simba');
    Rewrite(F);
    WriteLn(F, 'program Test;');
    WriteLn(F, 'procedure NewProc;');
    WriteLn(F, 'begin end;');
    WriteLn(F, 'begin end.');
    CloseFile(F);

    // Search again - should re-parse modified file
    Results := Index.Search('NewProc');
    CheckEqual(1, Length(Results), 'Should find NewProc after file modification');

    Results := Index.Search('MyProc');
    CheckEqual(0, Length(Results), 'Should NOT find MyProc after file modification');

  finally
    Index.Free;
  end;

  WriteLn;
end;

begin
  WriteLn('========================================');
  WriteLn('LSP Workspace Unit Tests');
  WriteLn('========================================');
  WriteLn;

  // Initialize codetools (required for parser to work)
  SimbaInitialization_Call(ESimbaInit.IDE_BEFORE_CREATE);

  CreateTestWorkspace;
  try
    TestFindSimbaFiles;
    TestWorkspaceIndexCache;
  finally
    CleanupTestWorkspace;
    SimbaInitialization_Call(ESimbaInit.IDE_DESTROY);
  end;

  WriteLn('========================================');
  WriteLn(Format('Results: %d passed, %d failed', [TestsPassed, TestsFailed]));
  WriteLn('========================================');

  if TestsFailed > 0 then
    Halt(1)
  else
    Halt(0);
end.

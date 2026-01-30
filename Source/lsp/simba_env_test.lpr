{
  Unit tests for simba.env (SimbaEnv class).
  Run with: lazbuild simba_env_test.lpi && ./simba_env_test
  Exit code 0 = all tests pass, non-zero = failure
}
program simba_env_test;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils,
  simba.base,
  simba.env;

var
  TestsPassed: Integer = 0;
  TestsFailed: Integer = 0;
  TestDir: String;

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

procedure CheckNotEmpty(const Value: String; const TestName: String);
begin
  if Value <> '' then
  begin
    Inc(TestsPassed);
    WriteLn('  PASS: ', TestName, ' (got "', Value, '")');
  end
  else
  begin
    Inc(TestsFailed);
    WriteLn('  FAIL: ', TestName, ' (expected non-empty, got empty)');
  end;
end;

{ ============================================================================ }
{ Setup / Teardown helpers }
{ ============================================================================ }

procedure CreateTestFile(const FileName: String; const Content: String = 'test');
var
  F: TextFile;
  Dir: String;
begin
  Dir := ExtractFileDir(FileName);
  if (Dir <> '') and not DirectoryExists(Dir) then
    ForceDirectories(Dir);
  AssignFile(F, FileName);
  Rewrite(F);
  WriteLn(F, Content);
  CloseFile(F);
end;

procedure SetupTestEnvironment;
begin
  TestDir := IncludeTrailingPathDelimiter(GetTempDir) + 'simba_env_test_' + IntToStr(GetTickCount64) + PathDelim;
  ForceDirectories(TestDir);
  ForceDirectories(TestDir + 'Includes');
  ForceDirectories(TestDir + 'Plugins');
  ForceDirectories(TestDir + 'CustomIncludes');
  ForceDirectories(TestDir + 'Scripts');

  // Create some test files
  CreateTestFile(TestDir + 'Includes' + PathDelim + 'srl.simba');
  CreateTestFile(TestDir + 'Includes' + PathDelim + 'utils.simba');
  CreateTestFile(TestDir + 'Includes' + PathDelim + 'SubDir' + PathDelim + 'nested.simba');
  CreateTestFile(TestDir + 'CustomIncludes' + PathDelim + 'mylib.simba');
  CreateTestFile(TestDir + 'Scripts' + PathDelim + 'main.simba');

  // Create a fake plugin file
  {$IFDEF WINDOWS}
  CreateTestFile(TestDir + 'Plugins' + PathDelim + 'myplugin64.dll');
  {$ELSE}
  CreateTestFile(TestDir + 'Plugins' + PathDelim + 'myplugin64.so');
  {$ENDIF}

  // Configure SimbaEnv to use our test directory
  SimbaEnv.SetSimbaPath(TestDir);
end;

procedure CleanupTestEnvironment;

  procedure DeleteDirRecursive(const Dir: String);
  var
    SearchRec: TSearchRec;
    Path: String;
  begin
    Path := IncludeTrailingPathDelimiter(Dir);
    if FindFirst(Path + '*', faAnyFile, SearchRec) = 0 then
    begin
      repeat
        if (SearchRec.Name <> '.') and (SearchRec.Name <> '..') then
        begin
          if (SearchRec.Attr and faDirectory) <> 0 then
            DeleteDirRecursive(Path + SearchRec.Name)
          else
            DeleteFile(Path + SearchRec.Name);
        end;
      until FindNext(SearchRec) <> 0;
      FindClose(SearchRec);
    end;
    RemoveDir(Dir);
  end;

begin
  if (TestDir <> '') and DirectoryExists(TestDir) then
    DeleteDirRecursive(TestDir);
end;

{ ============================================================================ }
{ SimbaEnv.SimbaPath tests }
{ ============================================================================ }

procedure TestSimbaPath;
begin
  WriteLn('Testing SimbaEnv.SimbaPath:');

  CheckNotEmpty(SimbaEnv.SimbaPath, 'SimbaPath is set');
  Check(DirectoryExists(SimbaEnv.SimbaPath), 'SimbaPath directory exists');
  CheckEqual(TestDir, SimbaEnv.SimbaPath, 'SimbaPath matches test directory');

  WriteLn;
end;

{ ============================================================================ }
{ SimbaEnv.IncludesPath tests }
{ ============================================================================ }

procedure TestIncludesPath;
begin
  WriteLn('Testing SimbaEnv.IncludesPath:');

  CheckNotEmpty(SimbaEnv.IncludesPath, 'IncludesPath is set');
  Check(DirectoryExists(SimbaEnv.IncludesPath), 'IncludesPath directory exists');
  CheckEqual(TestDir + 'Includes' + PathDelim, SimbaEnv.IncludesPath, 'IncludesPath is correct');

  WriteLn;
end;

{ ============================================================================ }
{ SimbaEnv.PluginsPath tests }
{ ============================================================================ }

procedure TestPluginsPath;
begin
  WriteLn('Testing SimbaEnv.PluginsPath:');

  CheckNotEmpty(SimbaEnv.PluginsPath, 'PluginsPath is set');
  Check(DirectoryExists(SimbaEnv.PluginsPath), 'PluginsPath directory exists');
  CheckEqual(TestDir + 'Plugins' + PathDelim, SimbaEnv.PluginsPath, 'PluginsPath is correct');

  WriteLn;
end;

{ ============================================================================ }
{ SimbaEnv.FindInclude tests }
{ ============================================================================ }

procedure TestFindInclude;
var
  Result: String;
begin
  WriteLn('Testing SimbaEnv.FindInclude:');

  // Find file in default Includes directory
  Result := SimbaEnv.FindInclude('srl.simba', []);
  CheckEqual(TestDir + 'Includes' + PathDelim + 'srl.simba', Result, 'Find srl.simba in Includes');

  // Find file without extension (should add .simba)
  Result := SimbaEnv.FindInclude('utils', []);
  CheckEqual(TestDir + 'Includes' + PathDelim + 'utils.simba', Result, 'Find utils without extension');

  // Find file in subdirectory
  Result := SimbaEnv.FindInclude('SubDir' + PathDelim + 'nested.simba', []);
  CheckEqual(TestDir + 'Includes' + PathDelim + 'SubDir' + PathDelim + 'nested.simba', Result, 'Find nested include');

  // File not found
  Result := SimbaEnv.FindInclude('nonexistent.simba', []);
  CheckEqual('', Result, 'Non-existent file returns empty');

  // Find file in extra search directory
  Result := SimbaEnv.FindInclude('main.simba', [TestDir + 'Scripts']);
  CheckEqual(TestDir + 'Scripts' + PathDelim + 'main.simba', Result, 'Find in extra search dir');

  // Extra search dir takes precedence
  CreateTestFile(TestDir + 'Scripts' + PathDelim + 'srl.simba', 'local copy');
  Result := SimbaEnv.FindInclude('srl.simba', [TestDir + 'Scripts']);
  CheckEqual(TestDir + 'Scripts' + PathDelim + 'srl.simba', Result, 'Extra search dir takes precedence');

  WriteLn;
end;

{ ============================================================================ }
{ SimbaEnv.HasInclude tests }
{ ============================================================================ }

procedure TestHasInclude;
begin
  WriteLn('Testing SimbaEnv.HasInclude:');

  Check(SimbaEnv.HasInclude('srl.simba', []), 'HasInclude returns true for existing file');
  Check(SimbaEnv.HasInclude('utils', []), 'HasInclude works without extension');
  Check(not SimbaEnv.HasInclude('nonexistent.simba', []), 'HasInclude returns false for missing file');

  WriteLn;
end;

{ ============================================================================ }
{ SimbaEnv.FindPlugin tests }
{ ============================================================================ }

procedure TestFindPlugin;
var
  Result: String;
  ExpectedPlugin: String;
begin
  WriteLn('Testing SimbaEnv.FindPlugin:');

  {$IFDEF WINDOWS}
  ExpectedPlugin := TestDir + 'Plugins' + PathDelim + 'myplugin64.dll';
  {$ELSE}
  ExpectedPlugin := TestDir + 'Plugins' + PathDelim + 'myplugin64.so';
  {$ENDIF}

  // Find plugin with full name
  Result := SimbaEnv.FindPlugin('myplugin64.dll', []);
  {$IFDEF WINDOWS}
  CheckEqual(ExpectedPlugin, Result, 'Find plugin with full name');
  {$ELSE}
  // On non-Windows, looking for .dll won't find .so
  Check(True, 'Skip Windows-specific plugin test on Unix');
  {$ENDIF}

  // Find plugin by base name (adds platform suffix)
  Result := SimbaEnv.FindPlugin('myplugin', []);
  CheckEqual(ExpectedPlugin, Result, 'Find plugin by base name');

  // Plugin not found
  Result := SimbaEnv.FindPlugin('nonexistent', []);
  CheckEqual('', Result, 'Non-existent plugin returns empty');

  WriteLn;
end;

{ ============================================================================ }
{ SimbaEnv.HasPlugin tests }
{ ============================================================================ }

procedure TestHasPlugin;
begin
  WriteLn('Testing SimbaEnv.HasPlugin:');

  Check(SimbaEnv.HasPlugin('myplugin', []), 'HasPlugin returns true for existing plugin');
  Check(not SimbaEnv.HasPlugin('nonexistent', []), 'HasPlugin returns false for missing plugin');

  WriteLn;
end;

{ ============================================================================ }
{ SimbaEnv.AddIncludePath tests }
{ ============================================================================ }

procedure TestAddIncludePath;
var
  Result: String;
begin
  WriteLn('Testing SimbaEnv.AddIncludePath:');

  // Add custom include path
  SimbaEnv.AddIncludePath(TestDir + 'CustomIncludes');

  // Now we should be able to find files in the custom path
  Result := SimbaEnv.FindInclude('mylib.simba', []);
  CheckEqual(TestDir + 'CustomIncludes' + PathDelim + 'mylib.simba', Result, 'Find file in added include path');

  WriteLn;
end;

{ ============================================================================ }
{ SimbaEnv.SetSimbaPath tests }
{ ============================================================================ }

procedure TestSetSimbaPath;
var
  NewTestDir: String;
begin
  WriteLn('Testing SimbaEnv.SetSimbaPath:');

  // Create another test directory
  NewTestDir := IncludeTrailingPathDelimiter(GetTempDir) + 'simba_env_test2_' + IntToStr(GetTickCount64) + PathDelim;
  ForceDirectories(NewTestDir);
  ForceDirectories(NewTestDir + 'Includes');

  // Create a test file in the new location
  CreateTestFile(NewTestDir + 'Includes' + PathDelim + 'newfile.simba');

  // Change SimbaPath
  SimbaEnv.SetSimbaPath(NewTestDir);

  // Verify paths updated
  CheckEqual(NewTestDir, SimbaEnv.SimbaPath, 'SimbaPath updated');
  CheckEqual(NewTestDir + 'Includes' + PathDelim, SimbaEnv.IncludesPath, 'IncludesPath updated');
  CheckEqual(NewTestDir + 'Plugins' + PathDelim, SimbaEnv.PluginsPath, 'PluginsPath updated');

  // Verify we can find files in new location
  Check(SimbaEnv.HasInclude('newfile.simba', []), 'Can find files in new SimbaPath');

  // Cleanup
  DeleteFile(NewTestDir + 'Includes' + PathDelim + 'newfile.simba');
  RemoveDir(NewTestDir + 'Includes');
  RemoveDir(NewTestDir);

  // Restore original test directory
  SimbaEnv.SetSimbaPath(TestDir);

  WriteLn;
end;

{ ============================================================================ }
{ Main }
{ ============================================================================ }

begin
  WriteLn('========================================');
  WriteLn('Simba Env Unit Tests');
  WriteLn('========================================');
  WriteLn;

  try
    SetupTestEnvironment;
    WriteLn('Test directory: ', TestDir);
    WriteLn;

    TestSimbaPath;
    TestIncludesPath;
    TestPluginsPath;
    TestFindInclude;
    TestHasInclude;
    TestFindPlugin;
    TestHasPlugin;
    TestAddIncludePath;
    TestSetSimbaPath;

  finally
    CleanupTestEnvironment;
  end;

  WriteLn('========================================');
  WriteLn(Format('Results: %d passed, %d failed', [TestsPassed, TestsFailed]));
  WriteLn('========================================');

  if TestsFailed > 0 then
    Halt(1)
  else
    Halt(0);
end.

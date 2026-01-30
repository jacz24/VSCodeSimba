{
  Unit tests for simba.fs path utilities.
  Run with: lazbuild simba_fs_test.lpi && ./simba_fs_test
  Exit code 0 = all tests pass, non-zero = failure
}
program simba_fs_test;

{$mode objfpc}{$H+}

uses
  SysUtils,
  simba.fs;

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
{ PathJoin tests }
{ ============================================================================ }

procedure TestPathJoin;
begin
  WriteLn('Testing TSimbaPath.PathJoin:');

  {$IFDEF WINDOWS}
  // Basic joining
  CheckEqual('C:\Simba\Includes',
             TSimbaPath.PathJoin(['C:\Simba', 'Includes']),
             'Join two path components');

  CheckEqual('C:\Simba\Includes\SRL',
             TSimbaPath.PathJoin(['C:\Simba', 'Includes', 'SRL']),
             'Join three path components');

  // Already has trailing separator
  CheckEqual('C:\Simba\Includes',
             TSimbaPath.PathJoin(['C:\Simba\', 'Includes']),
             'First component has trailing separator');

  // Empty components should be skipped
  CheckEqual('C:\Simba\Includes',
             TSimbaPath.PathJoin(['C:\Simba', '', 'Includes']),
             'Empty middle component is skipped');

  CheckEqual('C:\Simba\Includes',
             TSimbaPath.PathJoin(['', 'C:\Simba', 'Includes']),
             'Empty first component is skipped');

  CheckEqual('C:\Simba',
             TSimbaPath.PathJoin(['C:\Simba', '']),
             'Empty last component is skipped');

  // Single component
  CheckEqual('C:\Simba',
             TSimbaPath.PathJoin(['C:\Simba']),
             'Single component');

  // All empty
  CheckEqual('',
             TSimbaPath.PathJoin(['', '', '']),
             'All empty components');

  // Deep nesting
  CheckEqual('C:\a\b\c\d\e\f',
             TSimbaPath.PathJoin(['C:\a', 'b', 'c', 'd', 'e', 'f']),
             'Many path components');
  {$ELSE}
  // Unix paths
  CheckEqual('/home/user/Simba',
             TSimbaPath.PathJoin(['/home/user', 'Simba']),
             'Join two Unix path components');

  CheckEqual('/home/user/Simba/Includes',
             TSimbaPath.PathJoin(['/home/user', 'Simba', 'Includes']),
             'Join three Unix path components');

  // Empty components
  CheckEqual('/home/user/Simba',
             TSimbaPath.PathJoin(['/home/user', '', 'Simba']),
             'Empty middle component is skipped');
  {$ENDIF}

  WriteLn;
end;

{ ============================================================================ }
{ PathExtractDir tests }
{ ============================================================================ }

procedure TestPathExtractDir;
begin
  WriteLn('Testing TSimbaPath.PathExtractDir:');

  {$IFDEF WINDOWS}
  CheckEqual('C:\Users\Documents',
             TSimbaPath.PathExtractDir('C:\Users\Documents\test.simba'),
             'Extract directory from file path');

  CheckEqual('C:\Users',
             TSimbaPath.PathExtractDir('C:\Users\Documents'),
             'Extract directory from directory path');

  CheckEqual('C:\',
             TSimbaPath.PathExtractDir('C:\test.simba'),
             'Extract directory from root file');
  {$ELSE}
  CheckEqual('/home/user',
             TSimbaPath.PathExtractDir('/home/user/test.simba'),
             'Extract directory from Unix file path');

  CheckEqual('/home',
             TSimbaPath.PathExtractDir('/home/user'),
             'Extract directory from Unix directory path');
  {$ENDIF}

  WriteLn;
end;

{ ============================================================================ }
{ PathExtractName tests }
{ ============================================================================ }

procedure TestPathExtractName;
begin
  WriteLn('Testing TSimbaPath.PathExtractName:');

  {$IFDEF WINDOWS}
  CheckEqual('test.simba',
             TSimbaPath.PathExtractName('C:\Users\Documents\test.simba'),
             'Extract filename from path');

  CheckEqual('script.pas',
             TSimbaPath.PathExtractName('D:\Projects\script.pas'),
             'Extract filename with different extension');

  CheckEqual('noextension',
             TSimbaPath.PathExtractName('C:\Users\noextension'),
             'Extract filename without extension');
  {$ELSE}
  CheckEqual('test.simba',
             TSimbaPath.PathExtractName('/home/user/test.simba'),
             'Extract filename from Unix path');

  CheckEqual('script.pas',
             TSimbaPath.PathExtractName('/usr/local/script.pas'),
             'Extract filename from Unix path');
  {$ENDIF}

  WriteLn;
end;

{ ============================================================================ }
{ PathExtractNameWithoutExt tests }
{ ============================================================================ }

procedure TestPathExtractNameWithoutExt;
begin
  WriteLn('Testing TSimbaPath.PathExtractNameWithoutExt:');

  {$IFDEF WINDOWS}
  CheckEqual('test',
             TSimbaPath.PathExtractNameWithoutExt('C:\Users\test.simba'),
             'Extract name without .simba extension');

  CheckEqual('script',
             TSimbaPath.PathExtractNameWithoutExt('D:\Projects\script.pas'),
             'Extract name without .pas extension');

  CheckEqual('noextension',
             TSimbaPath.PathExtractNameWithoutExt('C:\Users\noextension'),
             'File without extension');

  CheckEqual('file.tar',
             TSimbaPath.PathExtractNameWithoutExt('C:\Users\file.tar.gz'),
             'File with multiple dots (removes last extension only)');
  {$ELSE}
  CheckEqual('test',
             TSimbaPath.PathExtractNameWithoutExt('/home/user/test.simba'),
             'Extract name without extension (Unix)');
  {$ENDIF}

  WriteLn;
end;

{ ============================================================================ }
{ PathExtractExt tests }
{ ============================================================================ }

procedure TestPathExtractExt;
begin
  WriteLn('Testing TSimbaPath.PathExtractExt:');

  CheckEqual('.simba',
             TSimbaPath.PathExtractExt('test.simba'),
             'Extract .simba extension');

  CheckEqual('.pas',
             TSimbaPath.PathExtractExt('script.pas'),
             'Extract .pas extension');

  CheckEqual('',
             TSimbaPath.PathExtractExt('noextension'),
             'No extension returns empty');

  CheckEqual('.gz',
             TSimbaPath.PathExtractExt('file.tar.gz'),
             'Multiple dots - returns last extension');

  {$IFDEF WINDOWS}
  CheckEqual('.simba',
             TSimbaPath.PathExtractExt('C:\Users\test.simba'),
             'Full Windows path');
  {$ELSE}
  CheckEqual('.simba',
             TSimbaPath.PathExtractExt('/home/user/test.simba'),
             'Full Unix path');
  {$ENDIF}

  WriteLn;
end;

{ ============================================================================ }
{ PathIncludeTrailingSep / PathExcludeTrailingSep tests }
{ ============================================================================ }

procedure TestPathTrailingSeparator;
begin
  WriteLn('Testing TSimbaPath.PathIncludeTrailingSep / PathExcludeTrailingSep:');

  {$IFDEF WINDOWS}
  CheckEqual('C:\Users\',
             TSimbaPath.PathIncludeTrailingSep('C:\Users'),
             'Include trailing separator (none present)');

  CheckEqual('C:\Users\',
             TSimbaPath.PathIncludeTrailingSep('C:\Users\'),
             'Include trailing separator (already present)');

  CheckEqual('C:\Users',
             TSimbaPath.PathExcludeTrailingSep('C:\Users\'),
             'Exclude trailing separator (present)');

  CheckEqual('C:\Users',
             TSimbaPath.PathExcludeTrailingSep('C:\Users'),
             'Exclude trailing separator (not present)');
  {$ELSE}
  CheckEqual('/home/user/',
             TSimbaPath.PathIncludeTrailingSep('/home/user'),
             'Include trailing separator Unix');

  CheckEqual('/home/user',
             TSimbaPath.PathExcludeTrailingSep('/home/user/'),
             'Exclude trailing separator Unix');
  {$ENDIF}

  WriteLn;
end;

{ ============================================================================ }
{ TSimbaFile.FileExists tests }
{ ============================================================================ }

procedure TestFileExists;
var
  TestFile: String;
  F: TextFile;
begin
  WriteLn('Testing TSimbaFile.FileExists:');

  // Test with a file that definitely exists (the test program itself)
  TestFile := ParamStr(0);
  Check(TSimbaFile.FileExists(TestFile), 'Test executable exists');

  // Test with a file that definitely doesn't exist
  Check(not TSimbaFile.FileExists('this_file_definitely_does_not_exist_12345.xyz'),
        'Non-existent file returns false');

  // Test with empty string
  Check(not TSimbaFile.FileExists(''), 'Empty path returns false');

  // Create a temp file and test
  TestFile := GetTempDir + 'simba_fs_test_temp.txt';
  AssignFile(F, TestFile);
  Rewrite(F);
  WriteLn(F, 'test');
  CloseFile(F);

  Check(TSimbaFile.FileExists(TestFile), 'Temp file exists after creation');

  // Clean up
  DeleteFile(TestFile);
  Check(not TSimbaFile.FileExists(TestFile), 'Temp file gone after deletion');

  WriteLn;
end;

{ ============================================================================ }
{ TSimbaFile.FileRead tests }
{ ============================================================================ }

procedure TestFileRead;
var
  TestFile, Content: String;
  F: TextFile;
begin
  WriteLn('Testing TSimbaFile.FileRead:');

  // Create a temp file with known content
  TestFile := GetTempDir + 'simba_fs_test_read.txt';
  AssignFile(F, TestFile);
  Rewrite(F);
  Write(F, 'Hello, World!');
  CloseFile(F);

  Content := TSimbaFile.FileRead(TestFile);
  CheckEqual('Hello, World!', Content, 'Read file content');

  // Clean up
  DeleteFile(TestFile);

  // Test reading non-existent file
  Content := TSimbaFile.FileRead('this_file_does_not_exist.txt');
  CheckEqual('', Content, 'Non-existent file returns empty string');

  WriteLn;
end;

{ ============================================================================ }
{ Main }
{ ============================================================================ }

begin
  WriteLn('========================================');
  WriteLn('Simba FS Unit Tests');
  WriteLn('========================================');
  WriteLn;

  TestPathJoin;
  TestPathExtractDir;
  TestPathExtractName;
  TestPathExtractNameWithoutExt;
  TestPathExtractExt;
  TestPathTrailingSeparator;
  TestFileExists;
  TestFileRead;

  WriteLn('========================================');
  WriteLn(Format('Results: %d passed, %d failed', [TestsPassed, TestsFailed]));
  WriteLn('========================================');

  if TestsFailed > 0 then
    Halt(1)
  else
    Halt(0);
end.

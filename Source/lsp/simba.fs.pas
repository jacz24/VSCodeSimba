{
  Author: Raymond van Venetië and Merlijn Wajer
  Project: Simba (https://github.com/MerlijnWajer/Simba)
  License: GNU General Public License (https://www.gnu.org/licenses/gpl-3.0)

  Stub simba.fs for standalone LSP server.
  Provides minimal file system operations needed by codetools.
}
unit simba.fs;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  TSimbaPath = class
  public
    class function PathExtractDir(Path: String): String;
    class function PathExtractName(Path: String): String;
    class function PathExtractNameWithoutExt(Path: String): String;
    class function PathExtractExt(Path: String): String;
  end;

  TSimbaFile = class
  public
    class function FileExists(FileName: String): Boolean;
    class function FileRead(FileName: String): String;
  end;

implementation

class function TSimbaPath.PathExtractDir(Path: String): String;
begin
  Result := ExtractFileDir(Path);
end;

class function TSimbaPath.PathExtractName(Path: String): String;
begin
  Result := ExtractFileName(Path);
end;

class function TSimbaPath.PathExtractNameWithoutExt(Path: String): String;
begin
  Result := ChangeFileExt(ExtractFileName(Path), '');
end;

class function TSimbaPath.PathExtractExt(Path: String): String;
begin
  Result := ExtractFileExt(Path);
end;

class function TSimbaFile.FileExists(FileName: String): Boolean;
begin
  Result := SysUtils.FileExists(FileName);
end;

class function TSimbaFile.FileRead(FileName: String): String;
var
  Stream: TFileStream;
begin
  Result := '';
  if not SysUtils.FileExists(FileName) then
    Exit;

  Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then
      Stream.ReadBuffer(Result[1], Stream.Size);
  finally
    Stream.Free;
  end;
end;

end.

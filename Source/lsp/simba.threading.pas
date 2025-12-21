{
  Author: Raymond van Venetië and Merlijn Wajer
  Project: Simba (https://github.com/MerlijnWajer/Simba)
  License: GNU General Public License (https://www.gnu.org/licenses/gpl-3.0)

  Minimal simba.threading stub for standalone LSP server.
  Provides basic threading types without LCL/Forms dependencies.
}
unit simba.threading;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  Classes, SysUtils, SyncObjs;

type
  TEnterableLock = record
  private
    FLock: TCriticalSection;
  public
    function TryEnter: Boolean; inline;
    procedure Enter; inline;
    procedure Leave; inline;

    class operator Initialize(var Self: TEnterableLock);
    class operator Finalize(var Self: TEnterableLock);
  end;

  TWaitableLock = record
  private
    FLock: TSimpleEvent;
  public
    procedure Lock;
    procedure Unlock;
    procedure WaitLocked; overload;
    function WaitLocked(Timeout: Integer): Boolean; overload;
    function IsLocked: Boolean;

    class operator Initialize(var Self: TWaitableLock);
    class operator Finalize(var Self: TWaitableLock);
  end;

function IsMainThread: Boolean;

implementation

function IsMainThread: Boolean;
begin
  Result := GetCurrentThreadId = MainThreadID;
end;

// TEnterableLock

class operator TEnterableLock.Initialize(var Self: TEnterableLock);
begin
  Self.FLock := TCriticalSection.Create;
end;

class operator TEnterableLock.Finalize(var Self: TEnterableLock);
begin
  if Assigned(Self.FLock) then
    FreeAndNil(Self.FLock);
end;

function TEnterableLock.TryEnter: Boolean;
begin
  Result := FLock.TryEnter;
end;

procedure TEnterableLock.Enter;
begin
  FLock.Enter;
end;

procedure TEnterableLock.Leave;
begin
  FLock.Leave;
end;

// TWaitableLock

class operator TWaitableLock.Initialize(var Self: TWaitableLock);
begin
  Self.FLock := TSimpleEvent.Create;
end;

class operator TWaitableLock.Finalize(var Self: TWaitableLock);
begin
  if Assigned(Self.FLock) then
    FreeAndNil(Self.FLock);
end;

procedure TWaitableLock.Lock;
begin
  FLock.ResetEvent;
end;

procedure TWaitableLock.Unlock;
begin
  FLock.SetEvent;
end;

procedure TWaitableLock.WaitLocked;
begin
  FLock.WaitFor(INFINITE);
end;

function TWaitableLock.WaitLocked(Timeout: Integer): Boolean;
begin
  Result := FLock.WaitFor(Timeout) = wrSignaled;
end;

function TWaitableLock.IsLocked: Boolean;
begin
  Result := FLock.WaitFor(0) = wrTimeout;
end;

end.

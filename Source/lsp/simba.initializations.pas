{
  Author: Raymond van Venetië and Merlijn Wajer
  Project: Simba (https://github.com/MerlijnWajer/Simba)
  License: GNU General Public License (https://www.gnu.org/licenses/gpl-3.0)

  Stub simba.initializations for standalone LSP server.
  Provides minimal initialization interface.
}
unit simba.initializations;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

{$PUSH}
{$SCOPEDENUMS ON}
type
  ESimbaInit = (
    IDE_BEFORE_CREATE,
    IDE_BEFORE_SHOW,
    IDE_BEFORE_SHOW_BACKGROUND,
    IDE_DESTROY,
    CREATE,
    DESTROY
  );
  TSimbaInitName = String[64];
{$POP}

procedure SimbaInitialization_Add(Init: ESimbaInit; Proc: TProcedure; Name: TSimbaInitName; Priority: Integer = 0);
procedure SimbaInitialization_Call(Init: ESimbaInit);

implementation

type
  TInitMethod = record
    Init: ESimbaInit;
    Proc: TProcedure;
    Name: TSimbaInitName;
    Priority: Integer;
  end;
  TInitMethods = array of TInitMethod;

var
  InitMethods: TInitMethods;

procedure SimbaInitialization_Add(Init: ESimbaInit; Proc: TProcedure; Name: TSimbaInitName; Priority: Integer = 0);
var
  Item: TInitMethod;
begin
  Item := Default(TInitMethod);
  Item.Init := Init;
  Item.Proc := Proc;
  Item.Name := Name;
  Item.Priority := Priority;

  SetLength(InitMethods, Length(InitMethods) + 1);
  InitMethods[High(InitMethods)] := Item;
end;

procedure SimbaInitialization_Call(Init: ESimbaInit);
var
  I: Integer;
begin
  for I := 0 to High(InitMethods) do
    if InitMethods[I].Init = Init then
      InitMethods[I].Proc();
end;

end.

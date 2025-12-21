{
  Author: Raymond van Venetië and Merlijn Wajer
  Project: Simba (https://github.com/MerlijnWajer/Simba)
  License: GNU General Public License (https://www.gnu.org/licenses/gpl-3.0)

  Minimal simba.base stub for standalone LSP server.
  Provides basic types without LCL/Graphics dependencies.
}
unit simba.base;

{$i simba.inc}

interface

uses
  Classes, SysUtils;

type
  // Basic color type (normally from Graphics unit)
  TColor = type Integer;
  TColorArray = array of TColor;
  PColorArray = ^TColorArray;

  // Color record
  PColorBGRA = ^TColorBGRA;
  TColorBGRA = packed record
    B, G, R, A: Byte;
  end;
  TColorBGRAArray = array of TColorBGRA;

  // Point types
  PPoint = ^TPoint;
  TPoint = record
    X, Y: Integer;
  end;
  TPointArray = array of TPoint;
  T2DPointArray = array of TPointArray;

  // Box type
  PBox = ^TBox;
  TBox = record
    X1, Y1, X2, Y2: Integer;
  end;
  TBoxArray = array of TBox;

  // Quad type
  PQuad = ^TQuad;
  TQuad = record
    Top, Right, Bottom, Left: TPoint;
  end;
  TQuadArray = array of TQuad;

  // String arrays
  TStringArray = array of String;
  T2DStringArray = array of TStringArray;

  // Integer arrays
  TIntegerArray = array of Integer;
  T2DIntegerArray = array of TIntegerArray;
  TSingleArray = array of Single;
  TDoubleArray = array of Double;
  TByteArray = array of Byte;
  TBooleanArray = array of Boolean;

  // Variant
  TSimbaVariant = Variant;

  // Comparison function type
  TCompareFunc = function(const L, R): Integer;

  // Exception type
  ESimbaException = class(Exception);

  // Debug flags
  EDebugLn = (CLEAR, YELLOW, RED, GREEN, FOCUS);
  EDebugLnFlags = set of EDebugLn;

const
  clRed     = TColor($0000FF);
  clGreen   = TColor($00FF00);
  clBlue    = TColor($FF0000);
  clWhite   = TColor($FFFFFF);
  clBlack   = TColor($000000);
  clYellow  = TColor($00FFFF);
  clAqua    = TColor($FFFF00);
  clFuchsia = TColor($FF00FF);

var
  OnDebugLn: procedure(const S: String) of object = nil;

procedure Debug(const Msg: String); overload;
procedure Debug(const Msg: String; Args: array of const); overload;
procedure DebugLn(const Msg: String); overload;
procedure DebugLn(const Msg: String; Args: array of const); overload;
procedure DebugLn(const Flags: EDebugLnFlags; const Msg: String); overload;
procedure DebugLn(const Flags: EDebugLnFlags; const Msg: String; Args: array of const); overload;

procedure SimbaException(Message: String; Args: array of const); overload;
procedure SimbaException(Message: String); overload;

procedure Swap(var A, B: Integer); inline; overload;
procedure Swap(var A, B: String); inline; overload;
procedure Swap(var A, B: TPoint); inline; overload;
procedure Swap(var A, B: TColorBGRA); inline; overload;

function IfThen(Condition: Boolean; TrueValue, FalseValue: Integer): Integer; inline; overload;
function IfThen(Condition: Boolean; const TrueValue, FalseValue: String): String; inline; overload;

implementation

procedure Debug(const Msg: String);
begin
  // Silent for LSP - no console output during operation
end;

procedure Debug(const Msg: String; Args: array of const);
begin
  // Silent for LSP
end;

procedure DebugLn(const Msg: String);
begin
  if Assigned(OnDebugLn) then
    OnDebugLn(Msg);
  // Silent for LSP otherwise
end;

procedure DebugLn(const Msg: String; Args: array of const);
begin
  DebugLn(Format(Msg, Args));
end;

procedure DebugLn(const Flags: EDebugLnFlags; const Msg: String);
begin
  DebugLn(Msg);
end;

procedure DebugLn(const Flags: EDebugLnFlags; const Msg: String; Args: array of const);
begin
  DebugLn(Format(Msg, Args));
end;

procedure SimbaException(Message: String; Args: array of const);
begin
  raise ESimbaException.CreateFmt(Message, Args);
end;

procedure SimbaException(Message: String);
begin
  raise ESimbaException.Create(Message);
end;

procedure Swap(var A, B: Integer);
var
  Temp: Integer;
begin
  Temp := A;
  A := B;
  B := Temp;
end;

procedure Swap(var A, B: String);
var
  Temp: String;
begin
  Temp := A;
  A := B;
  B := Temp;
end;

procedure Swap(var A, B: TPoint);
var
  Temp: TPoint;
begin
  Temp := A;
  A := B;
  B := Temp;
end;

procedure Swap(var A, B: TColorBGRA);
var
  Temp: TColorBGRA;
begin
  Temp := A;
  A := B;
  B := Temp;
end;

function IfThen(Condition: Boolean; TrueValue, FalseValue: Integer): Integer;
begin
  if Condition then
    Result := TrueValue
  else
    Result := FalseValue;
end;

function IfThen(Condition: Boolean; const TrueValue, FalseValue: String): String;
begin
  if Condition then
    Result := TrueValue
  else
    Result := FalseValue;
end;

end.

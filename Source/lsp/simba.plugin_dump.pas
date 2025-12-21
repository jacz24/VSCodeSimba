{
  Author: Raymond van Venetië and Merlijn Wajer
  Project: Simba (https://github.com/MerlijnWajer/Simba)
  License: GNU General Public License (https://www.gnu.org/licenses/gpl-3.0)

  Stub simba.plugin_dump for standalone LSP server.
  Plugin support is not available in standalone mode.
}
unit simba.plugin_dump;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

function DumpPlugin(Plugin: String): TStringList;
function DumpPluginInAnotherProcess(FileName: String): String;

implementation

function DumpPlugin(Plugin: String): TStringList;
begin
  // Plugin support not available in standalone LSP
  Result := TStringList.Create;
end;

function DumpPluginInAnotherProcess(FileName: String): String;
begin
  // Plugin support not available in standalone LSP
  Result := '';
end;

end.

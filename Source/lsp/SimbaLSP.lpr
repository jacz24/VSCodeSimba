{
  Author: Raymond van Venetië and Merlijn Wajer
  Project: Simba (https://github.com/MerlijnWajer/Simba)
  License: GNU General Public License (https://www.gnu.org/licenses/gpl-3.0)

  Standalone LSP Server for Simba - can be built without full Simba IDE.
}
program SimbaLSP;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes, SysUtils,
  simba.lsp_server;

begin
  // --check <file>: Run diagnostics and exit (no LSP server)
  if (ParamCount >= 2) and (ParamStr(1) = '--check') then
    RunCheckMode(ParamStr(2))
  else
    RunLSPServer();
end.

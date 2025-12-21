{
  Author: Raymond van Venetië and Merlijn Wajer
  Project: Simba (https://github.com/MerlijnWajer/Simba)
  License: GNU General Public License (https://www.gnu.org/licenses/gpl-3.0)

  Stub simba.settings for standalone LSP server.
  Provides minimal settings interface without IDE dependencies.
}
unit simba.settings;

{$mode objfpc}{$H+}

interface

type
  // Minimal stub for settings used by codetools
  TSimbaSettingStub = record
    Value: Boolean;
  end;

  TSimbaCodeToolsSettings = record
    IgnoreIDEDirective: TSimbaSettingStub;
  end;

  TSimbaSettings = record
    CodeTools: TSimbaCodeToolsSettings;
  end;

var
  SimbaSettings: TSimbaSettings;

implementation

initialization
  // Default: don't ignore IDE directives
  SimbaSettings.CodeTools.IgnoreIDEDirective.Value := False;

end.

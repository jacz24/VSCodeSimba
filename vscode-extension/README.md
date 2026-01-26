# Simba Language Support for Visual Studio Code

This extension provides comprehensive language support for [Simba](https://github.com/Villavu/Simba) scripts (`.simba` files).

## Features

### Syntax Highlighting
Full syntax highlighting for the Lape scripting language used by Simba, including:
- Keywords and control structures
- Type declarations and primitives
- Comments (line, block, and parenthesis-style)
- Strings and character constants
- Numbers (decimal, hexadecimal, binary)
- Compiler directives
- IDE directives

### Code Intelligence (via LSP)
When connected to the Simba Language Server:
- **Auto-completion**: Context-aware suggestions for functions, types, and variables
- **Hover information**: See function signatures and type information
- **Go to Definition**: Jump to symbol definitions (Ctrl+Click or F12)
- **Signature Help**: Parameter hints while typing function calls
- **Document Symbols**: Quick navigation to functions and types (Ctrl+Shift+O)

## Requirements

- Visual Studio Code 1.75.0 or higher
- One of the following for LSP features:
  - **SimbaLSP** (standalone, lightweight) - Recommended for quick setup
  - **Simba 2.0** (full IDE with --lsp support) - Includes all built-in functions

## Installation

### From VSIX (Recommended)
1. Download the latest `.vsix` file from the releases
2. In VS Code, go to Extensions (Ctrl+Shift+X)
3. Click the "..." menu and select "Install from VSIX..."
4. Select the downloaded file

### Building from Source
```bash
cd vscode-extension
npm install
npm run compile
npx vsce package
```

## Configuration

### Settings

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `simba.lsp.enabled` | boolean | `true` | Enable the Simba Language Server for code intelligence |
| `simba.lsp.path` | string | `""` | Path to Simba executable. Leave empty to auto-detect. |
| `simba.lsp.trace.server` | string | `"off"` | Traces communication between VS Code and the language server |

### Auto-detection Paths

The extension searches for SimbaLSP (standalone) first, then falls back to full Simba:

**Windows:**
- `%USERPROFILE%\Simba\SimbaLSP.exe` / `Simba.exe`
- `%USERPROFILE%\Simba64\SimbaLSP.exe` / `Simba.exe`
- `C:\Simba\SimbaLSP.exe` / `Simba.exe`
- `C:\Program Files\Simba\SimbaLSP.exe` / `Simba.exe`

**macOS:**
- `~/Simba/SimbaLSP` / `Simba`
- `/Applications/Simba.app/Contents/MacOS/SimbaLSP` / `Simba`
- `/usr/local/bin/simbalsp` / `simba`

**Linux:**
- `~/Simba/SimbaLSP` / `Simba`
- `/usr/local/bin/simbalsp` / `simba`
- `/usr/bin/simbalsp` / `simba`
- `/opt/simba/SimbaLSP` / `Simba`

### LSP Server Options

| Server | Build | Features |
|--------|-------|----------|
| **SimbaLSP** | `lazbuild SimbaLSP.lpi` | Keywords, script symbols, includes |
| **Simba --lsp** | `lazbuild Simba.lpi` | All above + built-in Simba functions |

## Commands

| Command | Description |
|---------|-------------|
| `Simba: Restart Language Server` | Restart the Simba Language Server |

## Supported File Types

- `.simba` - Simba script files

## Language Features

### Keywords
```simba
program, function, procedure, var, const, type, begin, end,
if, then, else, case, of, for, to, downto, while, repeat, until,
do, with, try, except, finally, array, record, object, set, enum
```

### Built-in Types
```simba
Integer, String, Boolean, Single, Double, Byte, Word,
TPoint, TPointArray, TBox, TColor, TImage, etc.
```

### Example Script
```simba
program Example;

var
  MyPoint: TPoint;
  MyArray: TIntegerArray;

function CalculateDistance(P1, P2: TPoint): Double;
begin
  Result := Sqrt(Sqr(P2.X - P1.X) + Sqr(P2.Y - P1.Y));
end;

begin
  MyPoint := [100, 200];
  WriteLn('Hello from Simba!');
  WriteLn('Distance: ', CalculateDistance([0, 0], MyPoint));
end.
```

## Troubleshooting

### Language Server Not Starting
1. Check that Simba is installed and the path is correct
2. Try setting `simba.lsp.path` explicitly in settings
3. Check the Output panel (View → Output → Simba Language Server)

### No Auto-completion
1. Ensure `simba.lsp.enabled` is `true`
2. Verify the language server is running (check Output panel)
3. Try restarting the language server with the command palette

## Contributing

This extension is part of the [Simba project](https://github.com/Villavu/Simba). Contributions are welcome!

## License

GPL-3.0 - See the [LICENSE](https://github.com/Villavu/Simba/blob/master/COPYING) file for details.

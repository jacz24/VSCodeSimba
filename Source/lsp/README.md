# SimbaLSP - Standalone Language Server

SimbaLSP is a lightweight, standalone language server for Simba scripts. It provides code intelligence features like autocompletion, hover info, go-to-definition, and more in Visual Studio Code.

## Prerequisites

You need the following binaries in the same directory:

| Binary | Purpose |
|--------|---------|
| `SimbaLSP.exe` | The language server (handles code intelligence) |
| `Simba.exe` | The full Simba IDE (provides built-in declarations) |

**Why both?** SimbaLSP runs `Simba.exe --dumpcompiler` once to extract all built-in types and functions (like `TPoint`, `WriteLn`, `FindColor`, etc.). Without Simba.exe, the LSP still works but won't know about Simba's built-in features.

## VSCode Setup

### 1. Install the Extension

Install the Simba extension from the VSCode marketplace, or install the `.vsix` file manually:
- Press `Ctrl+Shift+P`
- Type "Install from VSIX"
- Select the `simba-x.x.x.vsix` file

### 2. Configure Settings

Open VSCode settings (`Ctrl+,`) and search for "simba". Configure these settings:

#### Required Settings

```json
{
  "simba.lsp.simbaLspPath": "C:/path/to/SimbaLSP.exe"
}
```

This tells VSCode where to find the standalone LSP binary.

#### Optional Settings

```json
{
  // Additional include paths (for your script libraries)
  "simba.includePaths": [
    "C:/Users/YourName/Simba/Includes",
    "C:/Projects/MySimbaLibrary"
  ],

  // Path to Simba for running scripts (F5)
  "simba.runPath": "C:/path/to/Simba.exe",

  // Enable verbose logging (for debugging)
  "simba.lsp.trace.server": "verbose"
}
```

### 3. Verify It's Working

1. Open a `.simba` file
2. Check the Output panel (`View` → `Output`)
3. Select "Simba" from the dropdown
4. You should see:
   ```
   Simba Language Support extension activated
   Using configured SimbaLSP: C:/path/to/SimbaLSP.exe
   Simba Language Server started successfully
   Loading X declaration sections
   Built-in declarations loaded successfully
   ```

## Features

Once configured, you get:

| Feature | Shortcut | Description |
|---------|----------|-------------|
| **Autocomplete** | `Ctrl+Space` | Suggestions for functions, types, variables |
| **Hover Info** | Hover mouse | See function signatures and documentation |
| **Go to Definition** | `Ctrl+Click` or `F12` | Jump to where something is defined |
| **Find References** | `Shift+F12` | Find all usages of a symbol |
| **Signature Help** | Type `(` | See parameter hints while typing |
| **Document Symbols** | `Ctrl+Shift+O` | Navigate to functions/types in current file |
| **Workspace Symbols** | `Ctrl+T` | Search all symbols across workspace |
| **Rename Symbol** | `F2` | Rename a variable/function everywhere |
| **Format Document** | `Shift+Alt+F` | Auto-format your code |
| **Folding** | Click gutter | Collapse/expand code blocks |

## Troubleshooting

### LSP Not Starting

**Symptoms:** No autocomplete, "Loading..." that never finishes

**Check:**
1. Is `simba.lsp.simbaLspPath` set correctly?
2. Does the file exist at that path?
3. Check Output panel for error messages

### No Built-in Functions

**Symptoms:** Your code works, but `WriteLn`, `Wait`, etc. aren't recognized

**Cause:** Simba.exe not found or `--dumpcompiler` failed

**Fix:**
1. Put `Simba.exe` in the same directory as `SimbaLSP.exe`
2. Or set `simba.lsp.simbaPath` to point to Simba.exe
3. Restart VSCode

### Includes Not Found

**Symptoms:** `{$I myinclude.simba}` shows errors

**Fix:** Add the include directory to settings:
```json
{
  "simba.includePaths": [
    "C:/path/to/your/includes"
  ]
}
```

### Debugging LSP Issues

Enable verbose tracing:
```json
{
  "simba.lsp.trace.server": "verbose"
}
```

Then check the Output panel for detailed logs.

## File Structure

Recommended directory layout:

```
Simba/
├── Simba.exe           # Full Simba IDE
├── SimbaLSP.exe        # Standalone LSP server
├── Includes/           # Your include files
│   ├── SRL/
│   └── WaspLib/
├── Plugins/            # Native plugins
└── Scripts/            # Your scripts
```

## Environment Variables

The LSP also respects these environment variables:

| Variable | Purpose |
|----------|---------|
| `SIMBA_PATH` | Override the Simba installation path |
| `SIMBA_INCLUDE_PATHS` | Additional include paths (semicolon-separated) |

## Building from Source

```bash
# Build SimbaLSP
lazbuild --build-mode="Win64" "Source/lsp/SimbaLSP.lpi"

# Build full Simba (needed for --dumpcompiler)
lazbuild --build-mode="Win64" "Source/Simba.lpi"
```

Requires Lazarus 4.4 with FPC 3.2.4.

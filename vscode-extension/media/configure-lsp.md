# Configure Language Server

The Simba Language Server provides code intelligence features like autocomplete, go-to-definition, and diagnostics.

## Option 1: Standalone SimbaLSP (Recommended)

Set the path to the standalone `SimbaLSP` binary:

```json
{
  "simba.lsp.simbaLspPath": "C:\\Path\\To\\SimbaLSP-Win64.exe"
}
```

## Option 2: Full Simba with --lsp flag

If you don't have the standalone LSP, the extension can use the full Simba binary:

```json
{
  "simba.lsp.simbaPath": "C:\\Path\\To\\Simba.exe"
}
```

## Disabling LSP

Set `simba.lsp.enabled` to `false` if you only need syntax highlighting.

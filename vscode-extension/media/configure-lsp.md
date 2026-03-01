# Configure Language Server

The Simba Language Server provides code intelligence features like autocomplete, go-to-definition, and diagnostics.

## Configuration

Set the path to the `SimbaLSP` binary:

```json
{
  "simba.lsp.simbaLspPath": "C:\\Path\\To\\SimbaLSP-Win64.exe"
}
```

If left empty, the extension will auto-detect SimbaLSP from common install locations.

## Disabling LSP

Set `simba.lsp.enabled` to `false` if you only need syntax highlighting.

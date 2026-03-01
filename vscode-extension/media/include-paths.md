# Configure Include Paths

Simba scripts use `{$I ...}` directives to include other files. The LSP needs to know where to find them.

## Default Paths

These are included automatically:
- The `Includes/` folder next to your Simba binary
- Your workspace folders

## Additional Paths

Add extra include paths for libraries like WaspLib:

```json
{
  "simba.includePaths": [
    "C:\\Users\\YourName\\Simba\\Includes"
  ]
}
```

This ensures the LSP can resolve includes like `{$I WaspLib/osrs.simba}`.

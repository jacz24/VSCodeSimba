# Configure Simba Path

The extension needs to know where your Simba binary is located to run scripts.

## Auto-detection

The extension checks common install locations automatically:
- `~/Simba/Simba.exe` (Windows)
- `~/Simba/Simba` (Linux/macOS)

## Manual Configuration

If Simba is installed elsewhere, set the path in settings:

```json
{
  "simba.runPath": "C:\\Path\\To\\Simba.exe"
}
```

Open **Settings** and search for `simba.runPath` to configure.

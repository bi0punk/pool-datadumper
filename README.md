# pool-datadumper

PowerShell script that dumps IIS configuration data (Application Pools, Sites, Applications, Bindings, SSL certificates, web.config/appsettings.json contents) to a timestamped JSON file.

## Stack

PowerShell, IIS WebAdministration module

## Usage

```powershell
# Basic dump
.\app.ps1

# Extended dump (includes SSL certificate details)
.\app-extended.ps1
```

Output is saved as a JSON file named with the server IP and timestamp.

## License

MIT

# pool-datadumper

Volcado de configuracion IIS (App Pools, Sites, certificados SSL, web.config, appsettings.json, ACLs NTFS) a JSON con redaccion automatica de secretos.

## Stack

PowerShell, IIS WebAdministration module

## Requisitos

- Windows con IIS instalado
- Ejecutar como **Administrador**
- Modulo WebAdministration

## Uso

```powershell
# Volcado estandar (redaccion de secretos activada)
.\app.ps1

# Volcado extendido (SSL detallado, ACLs, CPU, RapidFailProtection)
.\app.ps1 -Mode Extended

# Volcado basico (solo pools y bindings)
.\app.ps1 -Mode Basic

# Personalizar salida
.\app.ps1 -OutputPath D:\Backups -JsonDepth 15

# Filtrar por pool/sitio
.\app.ps1 -PoolFilter "MyApp*" -SiteFilter "MySite"

# DESACTIVAR redaccion (peligroso - expone credenciales)
.\app.ps1 -NoRedact
```

## Modos

| Modo | Contenido |
|------|-----------|
| **Basic** | Pools, bindings, thumbprints SSL, paths |
| **Standard** | Basic + web.config, appsettings.json (redactado) |
| **Extended** | Standard + SSL detallado, ACLs NTFS, CPU/RapidFail config |

## Seguridad

Por defecto, **todas** las credenciales se redactan automaticamente:
- Connection strings: `Password=***REDACTED***`
- App settings con claves sensibles: `***REDACTED***`
- appsettings.json: redaccion recursiva de keys que contengan `password`, `secret`, `key`, `token`, `connection`

Usa `-NoRedact` solo para debugging local.

## License

MIT

<#
.SYNOPSIS
    IIS Configuration Dumper - vuelca configuracion de IIS a JSON
.DESCRIPTION
    Recopila Application Pools, Sites, aplicaciones, bindings, certificados SSL,
    web.config, appsettings.json, ACLs NTFS y mas.
.PARAMETER Mode
    Nivel de recopilacion: Basic (minimo), Standard (por defecto), Extended (todo).
.PARAMETER OutputPath
    Directorio de salida (por defecto C:\Temp).
.PARAMETER NoRedact
    Deshabilita la redaccion de secretos. ¡PELIGROSO!
.PARAMETER PoolFilter
    Filtrar por nombre de Application Pool (wildcard).
.PARAMETER SiteFilter
    Filtrar por nombre de sitio (wildcard).
.PARAMETER JsonDepth
    Profundidad maxima para ConvertTo-Json (por defecto 10).
.EXAMPLE
    .\app.ps1 -Mode Basic
    .\app.ps1 -Mode Extended -OutputPath D:\Backups
    .\app.ps1 -PoolFilter "MyApp*"
#>

param(
    [ValidateSet('Basic', 'Standard', 'Extended')]
    [string]$Mode = 'Standard',

    [string]$OutputPath = 'C:\Temp',

    [switch]$NoRedact = $false,

    [string]$PoolFilter = '*',

    [string]$SiteFilter = '*',

    [int]$JsonDepth = 10
)

# --- Funciones de redaccion de secretos ---

function Redact-ConnectionString {
    param([string]$cs)
    if ($NoRedact) { return $cs }
    $cs -replace '(Password\s*=\s*)([^;]+)', "`$1***REDACTED***"
}

function Redact-Value {
    param([string]$value)
    if ($NoRedact) { return $value }
    if ($value -match '(?i)(password|secret|key|token|connection)') {
        return "***REDACTED***"
    }
    return $value
}

function Redact-SensitiveKeys {
    param($obj, [int]$depth = 5)
    if ($depth -le 0) { return $obj }
    if ($obj -is [PSCustomObject] -or $obj -is [hashtable]) {
        $result = @{}
        foreach ($key in $obj.PSObject.Properties.Name) {
            $val = $obj.$key
            if ($key -match '(?i)(password|secret|key|token|connectionstring)') {
                $result[$key] = "***REDACTED***"
            } elseif ($val -is [PSCustomObject] -or $val -is [hashtable] -or $val -is [Array]) {
                $result[$key] = Redact-SensitiveKeys $val ($depth - 1)
            } else {
                $result[$key] = $val
            }
        }
        return [PSCustomObject]$result
    } elseif ($obj -is [Array]) {
        return $obj | ForEach-Object { Redact-SensitiveKeys $_ ($depth - 1) }
    }
    return $obj
}

# --- Validacion de prerrequisitos ---

if (-not (Get-Module -ListAvailable -Name WebAdministration)) {
    Write-Error "WebAdministration module no disponible. Instale IIS Management Console."
    exit 1
}

try {
    Import-Module WebAdministration -ErrorAction Stop
} catch {
    Write-Error "No se pudo cargar WebAdministration: $_"
    exit 1
}

if (-not (Test-Path IIS:\)) {
    Write-Error "IIS PSDrive no disponible. Ejecute como Administrador y verifique instalacion de IIS."
    exit 1
}

# --- Deteccion de IP ---

$ip = (Get-WmiObject Win32_NetworkAdapterConfiguration |
    Where-Object { $_.IPEnabled -eq $true } |
    Select-Object -ExpandProperty IPAddress |
    Where-Object {
        $_ -notlike "127.*" -and
        $_ -notlike "169.254.*" -and
        $_ -notlike "10.*" -and
        $_ -notlike "172.1[6-9].*" -and
        $_ -notlike "172.2[0-9].*" -and
        $_ -notlike "172.3[0-1].*" -and
        $_ -notlike "192.168.*"
    })[0]

if (-not $ip) {
    $ip = "localhost"
    Write-Warning "No se detecto IP publica, usando '$ip'"
}

$ip = "$ip"
$timestamp = Get-Date -Format "yyyy-MM-dd_HHmm"

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$filename = "$ip`_$timestamp`_$Mode.json"
$outputFile = Join-Path $OutputPath $filename

# --- Funciones auxiliares ---

function Get-AppSettingsJsonSecure {
    param([string]$physicalPath)
    $appSettingsData = @{}
    if (-not $physicalPath) { return $appSettingsData }
    if (-not (Test-Path $physicalPath)) { return $appSettingsData }

    $jsonFiles = Get-ChildItem -Path $physicalPath -Filter "appsettings*.json" -File -ErrorAction SilentlyContinue
    foreach ($jsonFile in $jsonFiles) {
        try {
            $cleanLines = Get-Content $jsonFile.FullName -ErrorAction Stop |
                Where-Object { ($_ -notmatch '^\s*//') -and ($_ -notmatch '^\s*$') }
            $json = ($cleanLines -join "`n") | ConvertFrom-Json

            if (-not $NoRedact) {
                $json = Redact-SensitiveKeys $json
            }

            $appSettingsData[$jsonFile.Name] = $json
        } catch {
            $appSettingsData[$jsonFile.Name] = @{ Error = "Error leyendo $($jsonFile.Name): $_" }
        }
    }
    return $appSettingsData
}

function Get-WebConfigData {
    param([string]$physicalPath)
    $webConfigData = @{}
    if (-not $physicalPath) { return $webConfigData }

    $webConfigPath = Join-Path $physicalPath "web.config"
    if (-not (Test-Path $webConfigPath)) { return $webConfigData }

    try {
        [xml]$webConfig = Get-Content $webConfigPath

        $connectionStrings = @($webConfig.configuration.connectionStrings.add | ForEach-Object {
            @{ Name = $_.name; ConnectionString = Redact-ConnectionString $_.connectionString; ProviderName = $_.providerName }
        })
        $appSettings = @($webConfig.configuration.appSettings.add | ForEach-Object {
            @{ Key = $_.key; Value = Redact-Value $_.value }
        })

        $webConfigData = @{
            ConnectionStrings = $connectionStrings
            AppSettings       = $appSettings
            CustomErrorsMode  = $webConfig.configuration.'system.web'.customErrors.mode
            CompilationDebug  = $webConfig.configuration.'system.web'.compilation.debug
        }

        if ($Mode -eq 'Extended') {
            $webConfigData.Authentication   = $webConfig.configuration.'system.web'.authentication.mode
            $webConfigData.SessionStateMode = $webConfig.configuration.'system.web'.sessionState.mode
        }
    } catch {
        $webConfigData = @{ Error = "Error leyendo web.config: $_" }
    }
    return $webConfigData
}

function Get-SslCertificate {
    param($binding)
    $certData = $null
    $thumbprint = $binding.CertificateHash

    if ($Mode -eq 'Basic') {
        return $thumbprint
    }

    if ($Mode -eq 'Standard') {
        return @{ Thumbprint = $thumbprint }
    }

    if ($thumbprint) {
        $cert = Get-Item "Cert:\LocalMachine\My\$thumbprint" -ErrorAction SilentlyContinue
        $certData = @{
            Thumbprint  = $thumbprint
            Subject     = if ($cert) { $cert.Subject } else { $null }
            NotAfter    = if ($cert) { $cert.NotAfter } else { $null }
            Store       = "My"
        }
    }
    return $certData
}

function Get-ProcessModelConfig {
    param($config)
    $pm = @{
        MaxProcesses    = $config.processModel.maxProcesses
        LoadUserProfile = $config.processModel.loadUserProfile
    }
    if ($Mode -eq 'Extended') {
        $pm.PingEnabled      = $config.processModel.pingingEnabled
        $pm.PingInterval     = $config.processModel.pingInterval
        $pm.PingResponseTime = $config.processModel.pingResponseTime
    }
    return $pm
}

function Get-RecyclingConfig {
    param($config)
    $rc = @{
        PeriodicRestartTime  = $config.recycling.periodicRestart.time
        RequestsLimit        = $config.recycling.periodicRestart.requests
        PrivateMemoryLimitMB = $config.recycling.periodicRestart.privateMemory
    }
    if ($Mode -eq 'Extended') {
        $rc.SpecificTimes = $config.recycling.periodicRestart.specificTimes.value
    }
    return $rc
}

# --- Recoleccion principal ---

$errorCount = 0
$totalPools = 0
$totalApps = 0

$pools = Get-ChildItem IIS:\AppPools |
    Where-Object { $_.Name -like $PoolFilter } |
    ForEach-Object {
        $totalPools++
        $appPoolName = $_.Name
        Write-Information "Procesando pool: $appPoolName"

        try {
            $state = (Get-WebAppPoolState $appPoolName).Value
            $config = Get-WebConfiguration -Filter "system.applicationHost/applicationPools/add[@name='$appPoolName']"
        } catch {
            Write-Warning "Error leyendo configuracion del pool '$appPoolName': $_"
            $errorCount++
            return
        }

        $apps = Get-Website |
            Where-Object { $_.Name -like $SiteFilter } |
            ForEach-Object {
                $site = $_
                $bindings = @(Get-WebBinding -Name $site.Name | Select-Object protocol, bindingInformation)
                $siteConfig = Get-WebConfigurationProperty -Filter "/system.applicationHost/sites/site[@name='$($site.Name)']/application[@path='/']/virtualDirectory[@path='/']" -Name physicalPath
                $siteRoot = if ($siteConfig) { $siteConfig.Value } else { $null }

                $httpsBinding = Get-WebBinding -Name $site.Name | Where-Object { $_.protocol -eq "https" }
                $certData = if ($httpsBinding) { Get-SslCertificate $httpsBinding } else { $null }

                $siteObj = @{
                    SiteName    = $site.Name
                    SiteRoot    = $siteRoot
                    Bindings    = $bindings
                    SSLCert     = $certData
                }

                if ($Mode -eq 'Extended') {
                    $siteObj.SiteId    = $site.Id
                    $siteObj.SiteState = $site.State
                }

                Get-WebApplication -Site $site.Name | Where-Object { $_.ApplicationPool -eq $appPoolName } | ForEach-Object {
                    $totalApps++
                    $app = $_
                    try {
                        $vdirConfig = Get-WebConfigurationProperty -Filter "/system.applicationHost/sites/site[@name='$($site.Name)']/application[@path='$($app.Path)']/virtualDirectory[@path='/']" -Name physicalPath
                    } catch {
                        $vdirConfig = $null
                    }
                    $physicalPath = if ($vdirConfig) { $vdirConfig.Value } else { $null }

                    $virtualDirs = @(Get-WebVirtualDirectory -Site $site.Name -Application $app.Path |
                        Where-Object { $_.Path -ne "/" } |
                        Select-Object path, physicalPath)

                    $appObj = [PSCustomObject]@{
                        AppPath            = $app.Path
                        PhysicalPath       = $physicalPath
                        VirtualDirectories = $virtualDirs
                        WebConfig          = Get-WebConfigData $physicalPath
                        AppSettingsJson    = Get-AppSettingsJsonSecure $physicalPath
                    }

                    if ($Mode -eq 'Extended' -and $physicalPath -and (Test-Path $physicalPath)) {
                        try {
                            $aclData = (Get-Acl $physicalPath).Access | ForEach-Object {
                                @{
                                    Identity          = $_.IdentityReference.ToString()
                                    FileSystemRights  = $_.FileSystemRights.ToString()
                                    AccessControlType = $_.AccessControlType.ToString()
                                }
                            }
                            $appObj | Add-Member -NotePropertyName ACLs -NotePropertyValue $aclData
                        } catch {
                            $appObj | Add-Member -NotePropertyName ACLs -NotePropertyValue $null
                        }
                    }

                    foreach ($siteKey in $siteObj.Keys) {
                        $appObj | Add-Member -NotePropertyName $siteKey -NotePropertyValue $siteObj[$siteKey]
                    }
                    $appObj
                }
            }

        $poolObj = [PSCustomObject]@{
            Name                  = $appPoolName
            Status                = $state
            ManagedRuntimeVersion = $config.managedRuntimeVersion
            PipelineMode          = $config.managedPipelineMode
            IdentityType          = $config.processModel.identityType
            UserName              = $config.processModel.userName
            Enable32Bit           = $config.enable32BitAppOnWin64
            AutoStart             = $config.autoStart
            IdleTimeout           = $config.processModel.idleTimeout
            ProcessModel          = Get-ProcessModelConfig $config
            Recycling             = Get-RecyclingConfig $config
            Applications          = @($apps)
        }

        if ($Mode -eq 'Extended') {
            $poolObj | Add-Member -NotePropertyName Cpu -NotePropertyValue @{
                Limit         = $config.cpu.limit
                Action        = $config.cpu.action
                ResetInterval = $config.cpu.resetInterval
            }
            $poolObj | Add-Member -NotePropertyName RapidFailProtection -NotePropertyValue @{
                Enabled     = $config.failure.rapidFailProtection
                MaxCrashes  = $config.failure.rapidFailProtectionMaxCrashes
                Interval    = $config.failure.rapidFailProtectionInterval
            }
        }

        $poolObj
    }

# --- Exportar ---

$pools | ConvertTo-Json -Depth $JsonDepth | Set-Content -Path $outputFile -Encoding UTF8

$sizeKB = [math]::Round((Get-Item $outputFile).Length / 1KB, 1)
Write-Host ""
Write-Host "Resumen:" -ForegroundColor Green
Write-Host "  Modo:          $Mode"
Write-Host "  Pools:         $totalPools"
Write-Host "  Aplicaciones:  $totalApps"
Write-Host "  Errores:       $errorCount"
Write-Host "  Redactado:     $(if ($NoRedact) { 'NO' } else { 'SI' })"
Write-Host "  Archivo:       $outputFile"
Write-Host "  Tamaño:        $sizeKB KB"

Import-Module WebAdministration

# Obtener la primera IP válida (no loopback, no APIPA)
$ip = (Get-WmiObject Win32_NetworkAdapterConfiguration |
    Where-Object { $_.IPEnabled -eq $true } |
    Select-Object -ExpandProperty IPAddress |
    Where-Object { $_ -notlike "127.*" -and $_ -notlike "169.*" })[0]

$ip = "$ip"
$timestamp = Get-Date -Format "yyyy-MM-dd_HHmm"
$filename = "$ip`_$timestamp.json"
$outputPath = "C:\Temp\$filename"

$pools = Get-ChildItem IIS:\AppPools | ForEach-Object {
    $appPoolName = $_.Name
    $state = (Get-WebAppPoolState $appPoolName).Value
    $config = Get-WebConfiguration -Filter "system.applicationHost/applicationPools/add[@name='$appPoolName']"

    $apps = Get-Website | ForEach-Object {
        $site = $_
        $bindings = @(Get-WebBinding -Name $site.Name | Select-Object protocol, bindingInformation)
        $siteConfig = Get-WebConfigurationProperty -Filter "/system.applicationHost/sites/site[@name='$($site.Name)']/application[@path='/']/virtualDirectory[@path='/']" -Name physicalPath
        $siteRoot = if ($siteConfig) { $siteConfig.Value } else { $null }

        $httpsBinding = Get-WebBinding -Name $site.Name | Where-Object { $_.protocol -eq "https" }
        $certData = $null
        if ($httpsBinding) {
            $cert = Get-Item "Cert:\LocalMachine\My\$($httpsBinding.CertificateHash)" -ErrorAction SilentlyContinue
            $certData = @{
                Thumbprint  = $httpsBinding.CertificateHash
                Subject     = $cert.Subject
                NotAfter    = $cert.NotAfter
                Store       = "My"
            }
        }

        $siteId = $site.Id
        $siteState = $site.State

        Get-WebApplication -Site $site.Name | Where-Object { $_.ApplicationPool -eq $appPoolName } | ForEach-Object {
            $app = $_
            $vdirConfig = Get-WebConfigurationProperty -Filter "/system.applicationHost/sites/site[@name='$($site.Name)']/application[@path='$($app.Path)']/virtualDirectory[@path='/']" -Name physicalPath
            $physicalPath = if ($vdirConfig) { $vdirConfig.Value } else { $null }

            $virtualDirs = @(Get-WebVirtualDirectory -Site $site.Name -Application $app.Path | Where-Object { $_.Path -ne "/" } | Select-Object path, physicalPath)

            # web.config
            $webConfigData = @{}
            $webConfigPath = Join-Path $physicalPath "web.config"
            if (Test-Path $webConfigPath) {
                try {
                    [xml]$webConfig = Get-Content $webConfigPath
                    $connectionStrings = $webConfig.configuration.connectionStrings.add | ForEach-Object {
                        @{ Name = $_.name; ConnectionString = $_.connectionString; ProviderName = $_.providerName }
                    }
                    $appSettings = $webConfig.configuration.appSettings.add | ForEach-Object {
                        @{ Key = $_.key; Value = $_.value }
                    }

                    $authMode = $webConfig.configuration.'system.web'.authentication.mode
                    $customErrors = $webConfig.configuration.'system.web'.customErrors.mode
                    $compilationDebug = $webConfig.configuration.'system.web'.compilation.debug
                    $sessionState = $webConfig.configuration.'system.web'.sessionState.mode

                    $webConfigData = @{
                        ConnectionStrings = $connectionStrings
                        AppSettings       = $appSettings
                        Authentication    = $authMode
                        CustomErrorsMode  = $customErrors
                        CompilationDebug  = $compilationDebug
                        SessionStateMode  = $sessionState
                    }
                } catch {
                    $webConfigData = @{ Error = "Error leyendo web.config: $_" }
                }
            }

            # appsettings.json y variantes
            $appSettingsData = @{}
            $jsonFiles = Get-ChildItem -Path $physicalPath -Filter "appsettings*.json" -File -ErrorAction SilentlyContinue
            foreach ($jsonFile in $jsonFiles) {
                try {
                    $cleanLines = Get-Content $jsonFile.FullName -ErrorAction Stop |
                        Where-Object { ($_ -notmatch '^\s*//') -and ($_ -notmatch '^\s*$') }
                    $json = ($cleanLines -join "`n") | ConvertFrom-Json

                    $appSettingsData[$jsonFile.Name] = @{
                        ConnectionStrings = $json.ConnectionStrings
                        Logging           = $json.Logging
                        Environment       = $json.Environment
                        Jwt               = $json.Jwt
                        Serilog           = $json.Serilog
                        AllowedHosts      = $json.AllowedHosts
                    }
                } catch {
                    $appSettingsData[$jsonFile.Name] = @{ Error = "Error leyendo $($jsonFile.Name): $_" }
                }
            }

            # ACLs (permisos NTFS)
            $aclData = @()
            if (Test-Path $physicalPath) {
                try {
                    $acl = Get-Acl $physicalPath
                    $aclData = $acl.Access | ForEach-Object {
                        @{
                            Identity  = $_.IdentityReference.ToString()
                            FileSystemRights = $_.FileSystemRights.ToString()
                            AccessControlType = $_.AccessControlType.ToString()
                        }
                    }
                } catch {
                    $aclData = @{ Error = "Error leyendo permisos NTFS: $_" }
                }
            }

            [PSCustomObject]@{
                SiteName           = $site.Name
                SiteId             = $siteId
                SiteState          = $siteState
                AppPath            = $app.Path
                PhysicalPath       = $physicalPath
                SiteRoot           = $siteRoot
                Bindings           = $bindings
                SSLCertificate     = $certData
                VirtualDirectories = $virtualDirs
                WebConfig          = $webConfigData
                AppSettingsJson    = $appSettingsData
                ACLs               = $aclData
            }
        }
    }

    [PSCustomObject]@{
        Name                  = $appPoolName
        Status                = $state
        ManagedRuntimeVersion = $config.managedRuntimeVersion
        PipelineMode          = $config.managedPipelineMode
        IdentityType          = $config.processModel.identityType
        UserName              = $config.processModel.userName
        Enable32Bit           = $config.enable32BitAppOnWin64
        AutoStart             = $config.autoStart
        IdleTimeout           = $config.processModel.idleTimeout
        ProcessModel = @{
            MaxProcesses    = $config.processModel.maxProcesses
            LoadUserProfile = $config.processModel.loadUserProfile
            PingEnabled     = $config.processModel.pingingEnabled
            PingInterval    = $config.processModel.pingInterval
            PingResponseTime= $config.processModel.pingResponseTime
        }
        Recycling = @{
            PeriodicRestartTime  = $config.recycling.periodicRestart.time
            RequestsLimit        = $config.recycling.periodicRestart.requests
            PrivateMemoryLimitMB = $config.recycling.periodicRestart.privateMemory
            SpecificTimes        = $config.recycling.periodicRestart.specificTimes.value
        }
        Cpu = @{
            Limit     = $config.cpu.limit
            Action    = $config.cpu.action
            ResetInterval = $config.cpu.resetInterval
        }
        RapidFailProtection = @{
            Enabled = $config.failure.rapidFailProtection
            MaxCrashes = $config.failure.rapidFailProtectionMaxCrashes
            Interval = $config.failure.rapidFailProtectionInterval
        }
        Applications = $apps
    }
}

# Exportar a archivo
$pools | ConvertTo-Json -Depth 15 | Set-Content -Path $outputPath -Encoding UTF8
Write-Host "JSON exportado en: $outputPath"

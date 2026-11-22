param(
    [ValidateSet('Todo', 'Config', 'Limpieza', 'Reporte')][string]$Fase = 'Todo'
)

# ======= CONFIGURACION ========
$ResetPlanesEnergia     = $true     
$QuitarAppx             = $true     
$DismLimpieza           = $false    
$EfectosVisualesMinimos = $true     
$ApagarRecall           = $true     
$QuitarBloatOEM         = $true     
$OptimizarWSL           = $true     
$QuitarDockerInicio     = $false    
$DeshabilitarTelemetria = $false    
# ==============================

$ErrorActionPreference = 'Continue'
$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $esAdmin) { Write-Host 'Ejecuta este script desde PowerShell como administrador.'; exit 1 }
$SetupDir = 'C:\ProgramData\Setup'
$RepDir   = Join-Path $SetupDir 'Reportes'
New-Item -ItemType Directory -Force -Path $SetupDir, $RepDir | Out-Null
$Report = Join-Path $RepDir ('{0}_{1}.txt' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd'))

function Log([string]$m) {
    $l = '[OPT] ' + $m
    Add-Content -Path (Join-Path $SetupDir 'instalacion.log') -Value ('{0} - {1}' -f (Get-Date -Format 'dd/MM/yyyy HH:mm:ss'), $l) -ErrorAction SilentlyContinue
    Write-Host $l
}
function Paso([string]$t) { Log ('===== ' + $t + ' =====') }
function Rep([string]$titulo, $obj) {
    Add-Content -Path $Report -Value ("`r`n===== " + $titulo + ' =====')
    if ($null -eq $obj) { return }
    if ($obj -is [string]) { $txt = $obj } else { $txt = ($obj | Format-Table -AutoSize | Out-String -Width 250) }
    Add-Content -Path $Report -Value $txt
}
function Set-Reg([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord') {
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    } catch { Log ("ERROR registro {0}\{1}: {2}" -f $Path, $Name, $_.Exception.Message) }
}
function Remove-Contenido([string]$ruta) {
    if (Test-Path $ruta) {
        Get-ChildItem -Path $ruta -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
}
function Get-LibreGB { [math]::Round((Get-PSDrive C).Free / 1GB, 1) }

function Invoke-EnUsuarios([scriptblock]$Accion) {
    # 1) Default User (perfiles nuevos)  2) usuarios con sesion cargada  3) perfiles existentes sin sesion (equipos en uso)
    $def = 'C:\Users\Default\NTUSER.DAT'
    $cargado = $false
    if (Test-Path $def) {
        & reg.exe load 'HKU\DefUser' $def 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $cargado = $true } else { Log 'AVISO: no se pudo cargar el hive de Default User' }
    }
    if ($cargado) { & $Accion 'Registry::HKEY_USERS\DefUser' }
    Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' } |
        ForEach-Object { & $Accion ('Registry::HKEY_USERS\' + $_.PSChildName) }

    $montados = @()
    $n = 0
    $perfiles = @(Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { -not $_.Special -and -not $_.Loaded -and $_.LocalPath })
    foreach ($p in $perfiles) {
        $dat = Join-Path $p.LocalPath 'NTUSER.DAT'
        if (-not (Test-Path -LiteralPath $dat)) { continue }
        $n++
        $clave = 'TmpUser' + $n
        & reg.exe load ('HKU\' + $clave) $dat 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $montados += $clave
            & $Accion ('Registry::HKEY_USERS\' + $clave)
            Log ('Perfil sin sesion ajustado: ' + $p.LocalPath)
        } else { Log ('AVISO: no se pudo cargar el hive de ' + $p.LocalPath) }
    }

    if ($cargado -or $montados.Count -gt 0) {
        [gc]::Collect(); [gc]::WaitForPendingFinalizers(); Start-Sleep 1
        if ($cargado) { & reg.exe unload 'HKU\DefUser' 2>&1 | Out-Null }
        foreach ($m in $montados) { & reg.exe unload ('HKU\' + $m) 2>&1 | Out-Null }
    }
}

function Write-Estado([string]$tag) {
    Paso ('ESTADO ' + $tag)
    $os = Get-CimInstance Win32_OperatingSystem
    $ramLibre = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    Log ('RAM libre: {0} GB | Disco C libre: {1} GB' -f $ramLibre, (Get-LibreGB))
    Log ('Plan de energia: ' + ((& powercfg /getactivescheme) -join ' '))
    try {
        $bl = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
        Log ('BitLocker C: {0} ({1}% cifrado)' -f $bl.VolumeStatus, $bl.EncryptionPercentage)
    } catch { Log 'BitLocker: sin informacion' }
    try {
        $d = Get-MpComputerStatus -ErrorAction Stop
        Log ('Defender: servicio={0} proteccion tiempo real={1}' -f $d.AMServiceEnabled, $d.RealTimeProtectionEnabled)
    } catch { Log 'Defender: sin informacion (puede haber otro antivirus)' }
}

# Diagnostico: quien consume RAM/CPU ahora mismo (solo lectura)
function Write-Diagnostico {
    Rep 'Corrida' (Get-Date -Format 'dd/MM/yyyy HH:mm:ss')
    $osn = Get-CimInstance Win32_OperatingSystem
    Rep 'Tiempo encendido' ('{0} horas desde el ultimo arranque' -f [math]::Round(((Get-Date) - $osn.LastBootUpTime).TotalHours, 1))
    $nCpu = [Environment]::ProcessorCount
    $antes = @{}
    Get-Process -ErrorAction SilentlyContinue | ForEach-Object { if ($null -ne $_.CPU) { $antes[$_.Id] = $_.CPU } }
    Start-Sleep -Seconds 3
    $cpuTop = Get-Process -ErrorAction SilentlyContinue | Where-Object { $antes.ContainsKey($_.Id) -and $null -ne $_.CPU } |
        ForEach-Object { [pscustomobject]@{ Proceso = $_.ProcessName; Pct = (($_.CPU - $antes[$_.Id]) / 3 / $nCpu) * 100 } } |
        Group-Object Proceso |
        ForEach-Object { [pscustomobject]@{ Proceso = $_.Name; CPU_pct = [math]::Round(($_.Group | Measure-Object Pct -Sum).Sum, 1) } } |
        Sort-Object CPU_pct -Descending | Select-Object -First 10
    Rep 'Top 10 procesos por CPU (muestra de 3 s)' $cpuTop
    Rep 'Memoria' ('RAM total: {0} GB | libre: {1} GB' -f [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1), [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB, 1))
    Rep 'Top 15 procesos por RAM (agrupados)' (Get-Process -ErrorAction SilentlyContinue | Group-Object ProcessName |
        ForEach-Object { [pscustomobject]@{ Proceso = $_.Name; Instancias = $_.Count; RAM_MB = [math]::Round(($_.Group | Measure-Object WorkingSet64 -Sum).Sum / 1MB) } } |
        Sort-Object RAM_MB -Descending | Select-Object -First 15)
    Rep 'Tareas programadas activas (no Microsoft)' (Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.State -ne 'Disabled' -and $_.TaskPath -notlike '\Microsoft\*' } | Select-Object TaskName, TaskPath, State)
    Rep 'Servicios automaticos en ejecucion (no Microsoft)' (Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.StartMode -eq 'Auto' -and $_.State -eq 'Running' -and $_.PathName -notmatch 'system32|SysWOW64|Windows\\' } | Select-Object Name, DisplayName)
}

# =====================================================================
#  FASE CONFIG
# =====================================================================
if ($Fase -eq 'Todo' -or $Fase -eq 'Config') {

    Log '######## OPTIMIZACION (CONFIG) INICIADA ########'
    $cs  = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $bio = Get-CimInstance Win32_BIOS
    $os  = Get-CimInstance Win32_OperatingSystem
    $ver = (Get-CimInstance Win32_ComputerSystemProduct).Version
    if ([string]::IsNullOrWhiteSpace($ver) -or $ver -match 'None|Not Applicable|To be filled') { $ver = ('{0} {1}' -f $cs.Manufacturer, $cs.Model).Trim() }
    Log ('Modelo: {0} | CPU: {1} | RAM: {2} GB | BIOS: {3} | Windows build {4}' -f $ver, $cpu.Name.Trim(), [math]::Round($cs.TotalPhysicalMemory / 1GB), $bio.SMBIOSBIOSVersion, $os.BuildNumber)
    Rep 'Equipo' ("Modelo: $ver`r`nCPU: $($cpu.Name)`r`nBIOS: $($bio.SMBIOSBIOSVersion) ($($bio.ReleaseDate))`r`nWindows: $($os.Caption) build $($os.BuildNumber)")
    Write-Estado 'INICIAL'

    # ---- Energia ----
    Paso 'ENERGIA'
    try {
        if ($ResetPlanesEnergia) { & powercfg -restoredefaultschemes | Out-Null; Log 'Planes de energia restaurados a valores de Windows.' }
        & powercfg -setactive 381b4222-f694-41f0-9685-ff5bb260df2e | Out-Null
        & powercfg -setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100 | Out-Null
        & powercfg -setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100 | Out-Null
        & powercfg -setactive SCHEME_CURRENT | Out-Null
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0
        Log 'Plan Equilibrado activo, CPU maximo 100% (AC y bateria), Inicio rapido desactivado.'
    } catch { Log ('ERROR energia: ' + $_.Exception.Message) }

    # ---- Politicas de maquina (HKLM) ----
    Paso 'POLITICAS DEL EQUIPO'
    $pol = @(
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent','DisableWindowsConsumerFeatures',1,'DWord'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent','DisableSoftLanding',1,'DWord'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent','DisableCloudOptimizedContent',1,'DWord'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Dsh','AllowNewsAndInterests',0,'DWord'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Chat','ChatIcon',3,'DWord'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search','AllowCortana',0,'DWord'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search','ConnectedSearchUseWeb',0,'DWord'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer','DisableSearchBoxSuggestions',1,'DWord'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection','AllowTelemetry',1,'DWord'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection','DoNotShowFeedbackNotifications',1,'DWord'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization','DODownloadMode',0,'DWord'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR','AllowGameDVR',0,'DWord'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common','QMEnable',0,'DWord'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\Feedback','Enabled',0,'DWord'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Edge','StartupBoostEnabled',0,'DWord'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Edge','BackgroundModeEnabled',0,'DWord'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Edge','SleepingTabsEnabled',1,'DWord'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Edge','SleepingTabsTimeout',900,'DWord'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Edge','MetricsReportingEnabled',0,'DWord'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Edge','EdgeShoppingAssistantEnabled',0,'DWord'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Edge','HideFirstRunExperience',1,'DWord'),
        @('HKLM:\SOFTWARE\Policies\Google\Chrome','BackgroundModeEnabled',0,'DWord'),
        @('HKLM:\SOFTWARE\Policies\Google\Chrome','HighEfficiencyModeEnabled',1,'DWord'),
        @('HKLM:\SOFTWARE\Policies\Google\Chrome','MetricsReportingEnabled',0,'DWord'),
        # --- Edge: menos ruido (la barra lateral/Copilot de Edge NO se toca) ---
        @('HKLM:\SOFTWARE\Policies\Microsoft\Edge','ShowRecommendationsEnabled',0,'DWord'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Edge','PersonalizationReportingEnabled',0,'DWord'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Edge','PromotionalTabsEnabled',0,'DWord'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Edge','SpotlightExperiencesAndRecommendationsEnabled',0,'DWord'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Edge','ShowMicrosoftRewards',0,'DWord'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Edge','NewTabPageContentEnabled',0,'DWord'),
        # --- Chrome ---
        @('HKLM:\SOFTWARE\Policies\Google\Chrome','ShoppingListEnabled',0,'DWord'),
        @('HKLM:\SOFTWARE\Policies\Google\Chrome','PromotionsEnabled',0,'DWord'),
        # --- Brave: sin Rewards/Wallet/VPN/Leo; mismas politicas Chromium de ahorro ---
        @('HKLM:\SOFTWARE\Policies\BraveSoftware\Brave','BraveRewardsDisabled',1,'DWord'),
        @('HKLM:\SOFTWARE\Policies\BraveSoftware\Brave','BraveWalletDisabled',1,'DWord'),
        @('HKLM:\SOFTWARE\Policies\BraveSoftware\Brave','BraveVPNDisabled',1,'DWord'),
        @('HKLM:\SOFTWARE\Policies\BraveSoftware\Brave','BraveAIChatEnabled',0,'DWord'),
        @('HKLM:\SOFTWARE\Policies\BraveSoftware\Brave','BackgroundModeEnabled',0,'DWord'),
        @('HKLM:\SOFTWARE\Policies\BraveSoftware\Brave','HighEfficiencyModeEnabled',1,'DWord'),
        @('HKLM:\SOFTWARE\Policies\BraveSoftware\Brave','MetricsReportingEnabled',0,'DWord'),
        # --- OneDrive: archivos bajo demanda (menos disco/CPU de sincronizacion) ---
        @('HKLM:\SOFTWARE\Policies\Microsoft\OneDrive','FilesOnDemandEnabled',1,'DWord'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\OneDrive','PreventNetworkTrafficPreUserSignIn',1,'DWord'),
        # --- Sugerencias, actividad y reportes de errores ---
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent','DisableWindowsSpotlightFeatures',1,'DWord'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent','DisableTailoredExperiencesWithDiagnosticData',1,'DWord'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\System','EnableActivityFeed',0,'DWord'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\System','PublishUserActivities',0,'DWord'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\System','UploadUserActivities',0,'DWord'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting','Disabled',1,'DWord'),
        @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat','AITEnable',0,'DWord')
    )
    if ($ApagarRecall) {
        $pol += ,@('HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI','DisableAIDataAnalysis',1,'DWord')
        $pol += ,@('HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI','DisableClickToDo',1,'DWord')
    }
    foreach ($r in $pol) { Set-Reg $r[0] $r[1] $r[2] $r[3] }
    Log ('{0} politicas aplicadas.' -f $pol.Count)

    # ---- Ajustes de usuario (Default User + usuarios con sesion cargada) ----
    Paso 'AJUSTES DE USUARIO (perfil por defecto)'
    $cdm = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    $tw = @(
        @('Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize','StartupDelayInMSec',0,'DWord'),
        @('Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications','GlobalUserDisabled',1,'DWord'),
        @('System\GameConfigStore','GameDVR_Enabled',0,'DWord'),
        @($cdm,'ContentDeliveryAllowed',0,'DWord'),
        @($cdm,'OemPreInstalledAppsEnabled',0,'DWord'),
        @($cdm,'PreInstalledAppsEnabled',0,'DWord'),
        @($cdm,'PreInstalledAppsEverEnabled',0,'DWord'),
        @($cdm,'SilentInstalledAppsEnabled',0,'DWord'),
        @($cdm,'SystemPaneSuggestionsEnabled',0,'DWord'),
        @($cdm,'SubscribedContent-338388Enabled',0,'DWord'),
        @($cdm,'SubscribedContent-338389Enabled',0,'DWord'),
        @($cdm,'SubscribedContent-338393Enabled',0,'DWord'),
        @($cdm,'SubscribedContent-353694Enabled',0,'DWord'),
        @($cdm,'SubscribedContent-353696Enabled',0,'DWord'),
        @('Software\Microsoft\Office\16.0\Common\Graphics','DisableAnimations',1,'DWord'),
        @('Software\Microsoft\Office\16.0\Common','DisableTransitions',1,'DWord'),
        @('Software\Microsoft\Office\16.0\Common\LinkedIn','ShowLinkedInUpsell',0,'DWord')
    )
    # Busqueda web / resaltados y widgets en la barra (siempre)
    $tw += ,@('Software\Microsoft\Windows\CurrentVersion\Search','BingSearchEnabled',0,'DWord')
    $tw += ,@('Software\Microsoft\Windows\CurrentVersion\SearchSettings','IsDynamicSearchBoxEnabled',0,'DWord')
    $tw += ,@('Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced','TaskbarDa',0,'DWord')
    $tw += ,@('Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced','TaskbarMn',0,'DWord')
    # Efectos visuales: perfil "personalizado" (VisualFXSetting=3) con lo pesado apagado
    # y se conserva suavizado de fuentes (ClearType) y miniaturas, que si ayudan al usuario.
    if ($EfectosVisualesMinimos) {
        $fx = 'Software\Microsoft\Windows\CurrentVersion\Explorer'
        $vis = @(
            @(($fx + '\VisualEffects'),'VisualFXSetting',3,'DWord'),
            @('Control Panel\Desktop','UserPreferencesMask',[byte[]](0x90,0x12,0x03,0x80,0x10,0x00,0x00,0x00),'Binary'),
            @('Control Panel\Desktop','MenuShowDelay','0','String'),
            @('Control Panel\Desktop','DragFullWindows','0','String'),
            @('Control Panel\Desktop','FontSmoothing','2','String'),
            @('Control Panel\Desktop\WindowMetrics','MinAnimate','0','String'),
            @(($fx + '\Advanced'),'TaskbarAnimations',0,'DWord'),
            @(($fx + '\Advanced'),'ListviewAlphaSelect',0,'DWord'),
            @(($fx + '\Advanced'),'ListviewShadow',0,'DWord'),
            @(($fx + '\Advanced'),'IconsOnly',0,'DWord'),
            @('Software\Microsoft\Windows\CurrentVersion\Themes\Personalize','EnableTransparency',0,'DWord'),
            @('Software\Microsoft\Windows\DWM','EnableAeroPeek',0,'DWord'),
            @('Software\Microsoft\Windows\DWM','AlwaysHibernateThumbnails',0,'DWord')
        )
        foreach ($v in $vis) { $tw += ,$v }
        Log 'Efectos visuales minimos: se aplican al proximo inicio de sesion de cada usuario.'
    }
    Invoke-EnUsuarios {
        param($raiz)
        foreach ($t in $tw) { Set-Reg ($raiz + '\' + $t[0]) $t[1] $t[2] $t[3] }
    }
    Log ('{0} ajustes aplicados al perfil por defecto, usuarios con sesion y perfiles existentes.' -f $tw.Count)

    # ---- Servicios y tareas programadas ----
    Paso 'SERVICIOS Y TAREAS'
    # Copia de seguridad del arranque original de TODOS los servicios (para revertir si hace falta)
    try {
        Get-CimInstance Win32_Service | Select-Object Name, StartMode, State |
            Export-Csv -Path (Join-Path $RepDir ('{0}_{1}_servicios_antes.csv' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd'))) -NoTypeInformation -ErrorAction Stop
        Log 'Respaldo del arranque original de servicios guardado en Reportes (*_servicios_antes.csv).'
    } catch { Log ('AVISO: no se pudo guardar el respaldo de servicios: ' + $_.Exception.Message) }
    $servicios = @('WerSvc','XblAuthManager','XblGameSave','XboxGipSvc','XboxNetApiSvc','MapsBroker','lfsvc','RetailDemo','WMPNetworkSvc','MixedRealityOpenXRSvc','PhoneSvc','Fax','RemoteRegistry',
                   'dmwappushservice','AJRouter','WpcMonSvc','SEMgrSvc','wisvc','WalletService','lltdsvc','workfolderssvc','SmsRouter','SSDPSRV','upnphost')
    if ($DeshabilitarTelemetria) { $servicios += 'DiagTrack' }
    foreach ($s in $servicios) {
        if (Get-Service -Name $s -ErrorAction SilentlyContinue) {
            & sc.exe config $s start= disabled | Out-Null
            & sc.exe stop $s 2>&1 | Out-Null
        }
    }
    Log ('Servicios deshabilitados (si existian): ' + ($servicios -join ', '))

    $tareas = @(
        @('\Microsoft\Windows\Application Experience\','ProgramDataUpdater'),
        @('\Microsoft\Windows\Customer Experience Improvement Program\','Consolidator'),
        @('\Microsoft\Windows\Customer Experience Improvement Program\','UsbCeip'),
        @('\Microsoft\Windows\Feedback\Siuf\','DmClient'),
        @('\Microsoft\Windows\Feedback\Siuf\','DmClientOnScenarioDownload'),
        @('\Microsoft\Windows\DiskDiagnostic\','Microsoft-Windows-DiskDiagnosticDataCollector'),
        @('\Microsoft\Windows\Customer Experience Improvement Program\','KernelCeipTask'),
        @('\Microsoft\Windows\Application Experience\','StartupAppTask'),
        @('\Microsoft\Windows\Maps\','MapsToastTask'),
        @('\Microsoft\Windows\Maps\','MapsUpdateTask'),
        @('\Microsoft\Windows\Windows Error Reporting\','QueueReporting'),
        @('\Microsoft\Windows\Autochk\','Proxy'),
        @('\Microsoft\Windows\Shell\','FamilySafetyMonitor'),
        @('\Microsoft\Windows\Shell\','FamilySafetyRefreshTask'),
        @('\Microsoft\Windows\Windows Media Sharing\','UpdateLibrary'),
        @('\Microsoft\XblGameSave\','XblGameSaveTask')
    )
    foreach ($t in $tareas) { Disable-ScheduledTask -TaskPath $t[0] -TaskName $t[1] -ErrorAction SilentlyContinue | Out-Null }
    Get-ScheduledTask -TaskPath '\SoftLanding\*' -ErrorAction SilentlyContinue | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
    if (Get-Service -Name 'AdobeARMservice' -ErrorAction SilentlyContinue) { & sc.exe config AdobeARMservice start= demand | Out-Null }
    Log 'Tareas de telemetria/CEIP deshabilitadas. SysMain, Windows Update, Office y navegadores NO se tocan.'

    $inicioBasura = @('Spotify','Discord','EpicGamesLauncher','SteamService','Steam','iTunesHelper','ApplePhotoStreams','AdobeAAMUpdater-1.0','AdobeGCInvoker-1.0','AcroTray','Adobe ARM','SunJavaUpdateSched')
    foreach ($rk in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run') {
        foreach ($n in $inicioBasura) { Remove-ItemProperty -Path $rk -Name $n -ErrorAction SilentlyContinue }
    }
    # Igual por usuario (HKCU\Run) + autolanzadores de Edge/Chrome en segundo plano. Teams y OneDrive NO se tocan.
    Invoke-EnUsuarios {
        param($raiz)
        $run = $raiz + '\Software\Microsoft\Windows\CurrentVersion\Run'
        if (-not (Test-Path $run)) { return }
        foreach ($p in @((Get-Item $run).Property)) {
            if (($inicioBasura -contains $p) -or $p -like 'MicrosoftEdgeAutoLaunch*' -or $p -like 'GoogleChromeAutoLaunch*' -or ($QuitarDockerInicio -and $p -eq 'Docker Desktop')) {
                Remove-ItemProperty -Path $run -Name $p -ErrorAction SilentlyContinue
            }
        }
    }
    Log 'Entradas de inicio basura limpiadas (equipo y usuarios).'

    # ---- Debloat de apps UWP (se consulta la lista UNA sola vez) ----
    Paso 'DEBLOAT UWP'
    if ($QuitarAppx) {
        $patrones = @(
            'Microsoft.BingNews','Microsoft.BingWeather','Microsoft.BingSearch','Microsoft.GetHelp','Microsoft.Getstarted',
            'Microsoft.MicrosoftSolitaireCollection','Microsoft.WindowsFeedbackHub','Microsoft.YourPhone','Microsoft.ZuneVideo',
            'Microsoft.XboxApp','Microsoft.GamingApp','Microsoft.XboxGamingOverlay','Microsoft.XboxGameOverlay',
            'Microsoft.XboxIdentityProvider','Microsoft.XboxSpeechToTextOverlay','Microsoft.Xbox.TCUI',
            'Clipchamp.Clipchamp','Microsoft.People','Microsoft.WindowsMaps','Microsoft.MixedReality.Portal',
            'Microsoft.SkypeApp','Microsoft.549981C3F5F10','MicrosoftWindows.Client.WebExperience',
            'MicrosoftTeams','MicrosoftCorporationII.MicrosoftFamily','Microsoft.PowerAutomateDesktop',
            '*Spotify*','*Disney*','*TikTok*','*Instagram*','*Facebook*','*Netflix*','*AmazonPrimeVideo*',
            '*Twitter*','*CandyCrush*','*Duolingo*','*LinkedIn*',
            'Microsoft.WindowsAlarms','Microsoft.ZuneMusic','Microsoft.WindowsSoundRecorder','Microsoft.WindowsCommunicationsApps',
            'Microsoft.MicrosoftJournal','MicrosoftWindows.CrossDevice','Microsoft.OneConnect','Microsoft.Messaging',
            'Microsoft.3DBuilder','Microsoft.Microsoft3DViewer','Microsoft.MSPaint','Microsoft.Print3D','Microsoft.Wallet'
        )
        if ($QuitarBloatOEM) { $patrones += @('*HPJumpStarts*','*HPPrivacySettings*','*HPQuickDrop*','*HPEasyClean*','*DellDigitalDelivery*','*McAfee*') }
        $instalados  = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)
        $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)
        $hechosPkg  = @{}
        $hechosProv = @{}
        $quitados = 0
        foreach ($p in $patrones) {
            foreach ($a in ($instalados | Where-Object { $_.Name -like $p })) {
                if ($hechosPkg.ContainsKey($a.PackageFullName)) { continue }
                $hechosPkg[$a.PackageFullName] = $true
                Remove-AppxPackage -Package $a.PackageFullName -AllUsers -ErrorAction SilentlyContinue
                $quitados++
            }
            foreach ($v in ($provisioned | Where-Object { $_.DisplayName -like $p })) {
                if ($hechosProv.ContainsKey($v.PackageName)) { continue }
                $hechosProv[$v.PackageName] = $true
                Remove-AppxProvisionedPackage -Online -PackageName $v.PackageName -ErrorAction SilentlyContinue | Out-Null
            }
        }
        Log ("Apps UWP removidas: {0}. (Teams de trabajo 'MSTeams', Store, Fotos, Calculadora, Terminal, Quick Assist y Portal de empresa NO se tocan.)" -f $quitados)
    } else { Log 'Debloat UWP desactivado en configuracion.' }

    # ---- Ajustes de sistema seguros ----
    Paso 'SISTEMA'
    & fsutil.exe behavior set disablelastaccess 1 | Out-Null
    Log 'NTFS: actualizacion de ultimo acceso desactivada (menos escrituras a disco).'

    if ($OptimizarWSL -and (Test-Path 'C:\Windows\System32\wsl.exe')) {
        $wslTxt = "[wsl2]`r`n`r`n[experimental]`r`nautoMemoryReclaim=gradual`r`n"
        Get-ChildItem 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin 'Public','Default','Default User','All Users' } | ForEach-Object {
                $cfg = Join-Path $_.FullName '.wslconfig'
                if (-not (Test-Path -LiteralPath $cfg)) {
                    Set-Content -Path $cfg -Value $wslTxt -Encoding ASCII -ErrorAction SilentlyContinue
                    Log ('.wslconfig creado (liberacion gradual de RAM): ' + $cfg)
                }
            }
    }

    Log '######## OPTIMIZACION (CONFIG) TERMINADA ########'
}

# =====================================================================
#  FASE LIMPIEZA
# =====================================================================
if ($Fase -eq 'Todo' -or $Fase -eq 'Limpieza') {

    Log '######## LIMPIEZA INICIADA ########'
    $libreInicio = Get-LibreGB

    Paso 'LIMPIEZA'
    Remove-Contenido 'C:\Windows\Temp'
    Remove-Contenido 'C:\ProgramData\Microsoft\Windows\WER'
    Remove-Contenido 'C:\Windows\Minidump'
    Remove-Item 'C:\Windows\MEMORY.DMP' -Force -ErrorAction SilentlyContinue
    Get-ChildItem 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin 'Public','Default','Default User','All Users' } | ForEach-Object {
            $u = $_.FullName
            Remove-Contenido (Join-Path $u 'AppData\Local\Temp')
            Remove-Contenido (Join-Path $u 'AppData\Local\CrashDumps')
            Remove-Item (Join-Path $u 'AppData\Local\Microsoft\Windows\Explorer\thumbcache_*.db') -Force -ErrorAction SilentlyContinue
        }
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
    & ipconfig.exe /flushdns | Out-Null
    Log ('Temporales y papelera limpiados. Liberado aprox. {0} GB.' -f [math]::Round((Get-LibreGB) - $libreInicio, 1))

    if ($DismLimpieza) {
        Log 'Ejecutando DISM StartComponentCleanup (puede tardar varios minutos)...'
        $dp = Start-Process -FilePath 'dism.exe' -ArgumentList '/Online /Cleanup-Image /StartComponentCleanup' -Wait -PassThru -WindowStyle Hidden
        Log ('DISM termino (codigo {0})' -f $dp.ExitCode)
    }

    $discoTipo = 'Desconocido'
    try {
        $num = (Get-Partition -DriveLetter C -ErrorAction Stop | Get-Disk).Number
        $pd  = Get-PhysicalDisk | Where-Object { [int]$_.DeviceId -eq $num } | Select-Object -First 1
        if ($pd) { if ($pd.BusType -eq 'NVMe') { $discoTipo = 'NVMe' } else { $discoTipo = [string]$pd.MediaType } }
    } catch { }
    if ($discoTipo -eq 'NVMe' -or $discoTipo -eq 'SSD') {
        Optimize-Volume -DriveLetter C -ReTrim -ErrorAction SilentlyContinue
        Log 'TRIM ejecutado.'
    }

    Paso 'INVENTARIO'
    $sw = Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
          Where-Object { $_.DisplayName } | Sort-Object DisplayName | Select-Object DisplayName, DisplayVersion, Publisher
    Rep 'Software instalado' $sw
    Rep 'Programas de inicio' (Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue | Select-Object Name, Command, Location, User)
    Write-Diagnostico
    Write-Estado 'FINAL'
    Log ('Reporte completo: ' + $Report)
    Log '######## LIMPIEZA TERMINADA ########'
}

if ($Fase -eq 'Reporte') {
    Log '######## REPORTE (SOLO LECTURA) ########'
    Write-Estado 'REPORTE'
    Write-Diagnostico
    Log ('Reporte completo: ' + $Report)
}

exit 0

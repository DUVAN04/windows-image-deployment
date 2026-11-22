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
$ProgressPreference    = 'SilentlyContinue'
$esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $esAdmin) { Write-Host 'Ejecuta este script desde PowerShell como administrador.'; exit 1 }
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$Cronometro = [System.Diagnostics.Stopwatch]::StartNew()
$SetupDir = 'C:\ProgramData\Setup'
$RepDir   = Join-Path $SetupDir 'Reportes'
New-Item -ItemType Directory -Force -Path $SetupDir, $RepDir | Out-Null
$Report   = Join-Path $RepDir ('{0}_{1}.txt' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd'))
$LogFile  = Join-Path $SetupDir 'instalacion.log'

# Total de pasos visibles segun la fase (para la barra de progreso)
$UI_Pasos = switch ($Fase) { 'Config' { 9 } 'Limpieza' { 6 } 'Reporte' { 2 } default { 15 } }
$script:UI_PasoActual = 0
$script:HiveModo      = $false
$script:St = @{
    RegCambios = 0; RegOk = 0; RegErr = 0
    SvcDeshab  = 0; SvcAusente = 0
    Tareas     = 0
    Inicio     = 0
    Apps       = 0; AppsProv = 0
    BytesLiberados = [double]0
}

# ==============================================================================
# MOTOR DE PRESENTACION TERMINAL (mismo estilo del script de mantenimiento)
#   Paso    : "[NN/TT] MODULO  descripcion" + barra de progreso
#   Det     : linea de detalle tecnica  "HH:mm:ss [ETIQUETA] texto"
#   Resultado: "[ OK ] MODULO  resultado"
# ==============================================================================
$UI_COL_P = 8; $UI_COL_M = 14; $UI_COL_SEP = 1

function Obtener-AnchoUI {
    $ancho = 80
    try { $ancho = $Host.UI.RawUI.WindowSize.Width } catch {}
    if ($ancho -lt 70)  { return 70  }
    if ($ancho -gt 120) { return 120 }
    return $ancho
}

function Write-LogFile([string]$linea) {
    try { Add-Content -Path $LogFile -Value ('{0} - [OPT] {1}' -f (Get-Date -Format 'dd/MM/yyyy HH:mm:ss'), $linea) -ErrorAction SilentlyContinue } catch {}
}

function UI-Linea($Char = '-', $Color = 'DarkBlue') {
    Write-Host ($Char * (Obtener-AnchoUI)) -ForegroundColor $Color
}

function UI-Centrar($Texto, $Color) {
    $ancho = Obtener-AnchoUI
    $pad = [math]::Max(0, [math]::Floor(($ancho - $Texto.Length) / 2))
    Write-Host ((' ' * $pad) + $Texto) -ForegroundColor $Color
}

function UI-Header {
    Write-Host ''
    UI-Linea '=' 'DarkCyan'
    UI-Centrar 'HERRAMIENTA DE OPTIMIZACION Y LIMPIEZA' 'Cyan'
    UI-Centrar 'Soporte y Tecnologia' 'White'
    UI-Linea '=' 'DarkCyan'
    Write-Host ''
}

function UI-SeccionTitulo($Titulo) {
    Write-Host ''
    Write-Host "  $Titulo  " -BackgroundColor DarkBlue -ForegroundColor White
    Write-Host ''
}

function UI-Separador {
    Write-Host ''
    UI-Linea '-' 'DarkGray'
    Write-Host ''
}

function UI-Paso($Numero, $TotalPasos, $Modulo, $Descripcion) {
    $ancho  = Obtener-AnchoUI
    $Pct    = [math]::Round(($Numero / $TotalPasos) * 100)
    $Tiempo = $Cronometro.Elapsed.ToString('mm\:ss')
    $MaxT = $ancho - $UI_COL_P - $UI_COL_M - $UI_COL_SEP
    if ($MaxT -lt 10) { $MaxT = 10 }
    $T = if ($Descripcion.Length -gt $MaxT) { $Descripcion.Substring(0, $MaxT - 3) + '...' } else { $Descripcion }
    $P = '[{0:D2}/{1:D2}] ' -f $Numero, $TotalPasos
    $M = '{0,-14}' -f $Modulo
    Write-Host $P -NoNewline -ForegroundColor DarkGray
    Write-Host $M -NoNewline -ForegroundColor Cyan
    Write-Host (' ' + $T) -ForegroundColor Gray

    $Sufijo   = '  {0,3}%  {1}' -f $Pct, $Tiempo
    $AnchoBar = $ancho - 2 - $Sufijo.Length
    if ($AnchoBar -lt 4) { $AnchoBar = 4 }
    $Llenos = [math]::Floor(($Numero / $TotalPasos) * $AnchoBar)
    $Vacios = $AnchoBar - $Llenos
    Write-Host '[' -NoNewline -ForegroundColor DarkGray
    Write-Host ('=' * $Llenos) -NoNewline -ForegroundColor Cyan
    if ($Vacios -gt 0) { Write-Host ('-' * $Vacios) -NoNewline -ForegroundColor DarkGray }
    Write-Host (']' + $Sufijo) -ForegroundColor DarkGray
    Write-Host ''
    Write-LogFile ('===== [{0}/{1}] {2}: {3} =====' -f $Numero, $TotalPasos, $Modulo, $Descripcion)
}

# Avanza el contador automaticamente
function Paso([string]$modulo, [string]$desc) {
    if ($script:UI_PasoActual -gt 0) { Write-Host '' }
    $script:UI_PasoActual++
    UI-Paso $script:UI_PasoActual $UI_Pasos $modulo $desc
}

function UI-Resultado($Modulo, $Resultado, $Estado) {
    $ancho = Obtener-AnchoUI
    $Icono = switch ($Estado) {
        'OK'    { '[ OK ]  ' }
        'WARN'  { '[ !! ]  ' }
        'ERROR' { '[ XX ]  ' }
        default { '[ -- ]  ' }
    }
    $Color = switch ($Estado) {
        'OK'    { 'Green'  }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red'    }
        default { 'Cyan'   }
    }
    $MaxT = $ancho - $UI_COL_P - $UI_COL_M - $UI_COL_SEP
    if ($MaxT -lt 10) { $MaxT = 10 }
    $T = if ($Resultado.Length -gt $MaxT) { $Resultado.Substring(0, $MaxT - 3) + '...' } else { $Resultado }
    $M = '{0,-14}' -f $Modulo
    Write-Host $Icono -NoNewline -ForegroundColor $Color
    Write-Host $M -NoNewline -ForegroundColor DarkGray
    Write-Host (' ' + $T) -ForegroundColor Gray
    Write-LogFile ('[{0}] {1}: {2}' -f $Estado, $Modulo, $Resultado)
}

function UI-SubInfo($Etiqueta, $Valor) {
    $ancho = Obtener-AnchoUI
    $MaxT = $ancho - $UI_COL_P - $UI_COL_M - $UI_COL_SEP
    if ($MaxT -lt 10) { $MaxT = 10 }
    $T = if ($Valor.Length -gt $MaxT) { $Valor.Substring(0, $MaxT - 3) + '...' } else { $Valor }
    $M = '{0,-14}' -f ($Etiqueta + ':')
    Write-Host (' ' * $UI_COL_P) -NoNewline
    Write-Host $M -NoNewline -ForegroundColor DarkGray
    Write-Host (' ' + $T) -ForegroundColor White
}

# Linea de detalle: hora + etiqueta de accion + texto (con ajuste de linea, sin truncar)
#   LEER/CONSULTA = solo lectura      RUTA = ingresa a carpeta/clave   CMD = ejecuta comando
#   SERVICIO/TAREA/APP = componente   REGISTRO/CONFIG/MODIFICA = cambia valor
#   CREAR/ELIMINA = crea o borra      OK = ya estaba correcto          OMITIDO = no aplica
function UI-Det([string]$Tipo, [string]$Texto) {
    Write-LogFile ('[{0}] {1}' -f $Tipo, $Texto)
    $ancho = Obtener-AnchoUI
    $Color = switch ($Tipo) {
        'LEER'     { 'DarkCyan' }
        'CONSULTA' { 'DarkCyan' }
        'RUTA'     { 'DarkYellow' }
        'REGISTRO' { 'DarkYellow' }
        'CMD'      { 'Magenta' }
        'PROCESO'  { 'Magenta' }
        'SERVICIO' { 'Cyan' }
        'TAREA'    { 'Cyan' }
        'APP'      { 'Cyan' }
        'CONFIG'   { 'Yellow' }
        'MODIFICA' { 'Yellow' }
        'AVISO'    { 'Yellow' }
        'CREAR'    { 'Green' }
        'OK'       { 'Green' }
        'ELIMINA'  { 'Red' }
        'ERROR'    { 'Red' }
        'OMITIDO'  { 'DarkGray' }
        'REPORTE'  { 'DarkGray' }
        default    { 'Gray' }
    }
    $ColorTxt = if ($Tipo -in @('OMITIDO', 'REPORTE')) { 'DarkGray' } else { 'Gray' }
    $Hora = (Get-Date).ToString('HH:mm:ss')
    $Tag  = '{0,-10}' -f ('[' + $Tipo + ']')
    $MaxT = $ancho - 20
    if ($MaxT -lt 30) { $MaxT = 30 }
    $primera = $true
    do {
        if ($Texto.Length -gt $MaxT) {
            $corte = $Texto.LastIndexOf(' ', $MaxT - 1)
            if ($corte -lt ($MaxT / 2)) { $corte = $MaxT }
            $Trozo = $Texto.Substring(0, $corte)
            $Texto = $Texto.Substring($corte).TrimStart()
        } else { $Trozo = $Texto; $Texto = '' }
        if ($primera) {
            Write-Host ($Hora + ' ') -NoNewline -ForegroundColor DarkGray
            Write-Host ($Tag + ' ')  -NoNewline -ForegroundColor $Color
            $primera = $false
        } else { Write-Host (' ' * 20) -NoNewline }
        Write-Host $Trozo -ForegroundColor $ColorTxt
    } while ($Texto.Length -gt 0)
}

# Compatibilidad: Log = linea informativa
function Log([string]$m) { UI-Det 'INFO' $m }

function Rep([string]$titulo, $obj) {
    UI-Det 'REPORTE' ("Registrando seccion '{0}' en {1}" -f $titulo, $Report)
    Add-Content -Path $Report -Value ("`r`n===== " + $titulo + ' =====')
    if ($null -eq $obj) { return }
    if ($obj -is [string]) { $txt = $obj } else { $txt = ($obj | Format-Table -AutoSize | Out-String -Width 250) }
    Add-Content -Path $Report -Value $txt
}

function Fmt-MB($bytes) { [math]::Round(([double]$bytes) / 1MB, 1) }
function Get-LibreGB { [math]::Round((Get-PSDrive C).Free / 1GB, 1) }

# ------------------------------------------------------------------------------
# Escritura de registro con detalle: valor anterior -> valor nuevo, o "ya correcto"
# ------------------------------------------------------------------------------
function Set-Reg([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord') {
    try {
        $fmt = { param($v) if ($v -is [byte[]]) { (($v | ForEach-Object { '{0:X2}' -f $_ }) -join ' ') } else { [string]$v } }
        $disp = ($Path -replace '^Registry::HKEY_USERS\\', 'HKU\') -replace '^Registry::', ''
        $existeClave = Test-Path -LiteralPath $Path
        $prev = $null; $tienePrev = $false
        if ($existeClave) {
            $p = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
            if ($null -ne $p -and ($p.PSObject.Properties.Name -contains $Name)) { $prev = $p.$Name; $tienePrev = $true }
        }
        $nuevoTxt = & $fmt $Value
        if ($tienePrev -and ((& $fmt $prev) -eq $nuevoTxt)) {
            $script:St.RegOk++
            if (-not $script:HiveModo) { UI-Det 'OK' ('Ya correcto  {0}\{1} = {2}' -f $disp, $Name, $nuevoTxt) }
            return
        }
        if (-not $existeClave) {
            New-Item -Path $Path -Force | Out-Null
            UI-Det 'CREAR' ('Clave de registro: ' + $disp)
        }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        $antesTxt = if ($tienePrev) { & $fmt $prev } else { '(no existia)' }
        $script:St.RegCambios++
        UI-Det 'MODIFICA' ('{0}\{1} [{2}]  {3} -> {4}' -f $disp, $Name, $Type, $antesTxt, $nuevoTxt)
    } catch {
        $script:St.RegErr++
        UI-Det 'ERROR' ('Registro {0}\{1}: {2}' -f $Path, $Name, $_.Exception.Message)
    }
}

# ------------------------------------------------------------------------------
# Borrado de carpetas / archivos con detalle (cantidad, MB y lo que no se pudo borrar)
# ------------------------------------------------------------------------------
function Remove-Contenido([string]$ruta, [string]$motivo = '') {
    if (-not (Test-Path -LiteralPath $ruta)) { UI-Det 'OMITIDO' ('No existe: ' + $ruta); return }
    $raiz  = @(Get-ChildItem -LiteralPath $ruta -Force -ErrorAction SilentlyContinue)
    $archs = @(Get-ChildItem -LiteralPath $ruta -Recurse -Force -File -ErrorAction SilentlyContinue)
    $antes = ($archs | Measure-Object Length -Sum).Sum
    if (-not $antes) { $antes = 0 }
    $extra = if ($motivo) { ' - ' + $motivo } else { '' }
    UI-Det 'RUTA' ('Ingresando a {0}  ({1} elemento(s) en raiz, {2} archivo(s), {3} MB){4}' -f $ruta, $raiz.Count, $archs.Count, (Fmt-MB $antes), $extra)
    if ($raiz.Count -eq 0) { UI-Det 'OK' 'Carpeta ya vacia. Nada que eliminar.'; return }
    $raiz | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    $rest = @(Get-ChildItem -LiteralPath $ruta -Recurse -Force -File -ErrorAction SilentlyContinue)
    $despues = ($rest | Measure-Object Length -Sum).Sum
    if (-not $despues) { $despues = 0 }
    $lib = $antes - $despues
    if ($lib -lt 0) { $lib = 0 }
    $script:St.BytesLiberados += $lib
    UI-Det 'ELIMINA' ('{0}: {1} MB liberados. Quedaron {2} archivo(s) en uso o protegidos.' -f $ruta, (Fmt-MB $lib), $rest.Count)
}

function Remove-Archivos([string]$patron, [switch]$Silencioso) {
    $f = @(Get-ChildItem -Path $patron -Force -File -ErrorAction SilentlyContinue)
    if ($f.Count -eq 0) {
        if (-not $Silencioso) { UI-Det 'OMITIDO' ('Sin coincidencias: ' + $patron) }
        return
    }
    $b = ($f | Measure-Object Length -Sum).Sum
    if (-not $b) { $b = 0 }
    $f | Remove-Item -Force -ErrorAction SilentlyContinue
    $quedan = @(Get-ChildItem -Path $patron -Force -File -ErrorAction SilentlyContinue)
    $bq = ($quedan | Measure-Object Length -Sum).Sum
    if (-not $bq) { $bq = 0 }
    $script:St.BytesLiberados += ($b - $bq)
    UI-Det 'ELIMINA' ('{0}: {1} archivo(s) eliminados, {2} MB. En uso: {3}' -f $patron, ($f.Count - $quedan.Count), (Fmt-MB ($b - $bq)), $quedan.Count)
}

# ------------------------------------------------------------------------------
# Hives de usuario: Default User + sesiones cargadas + perfiles sin sesion
# ------------------------------------------------------------------------------
function Resolve-Sid([string]$sid) {
    try { return ([System.Security.Principal.SecurityIdentifier]$sid).Translate([System.Security.Principal.NTAccount]).Value } catch { return $sid }
}

function Invoke-Hive([scriptblock]$Accion, [string]$raiz, [string]$etiqueta) {
    $script:HiveModo = $true
    $c0 = $script:St.RegCambios; $o0 = $script:St.RegOk
    UI-Det 'RUTA' ('Hive {0}  ->  {1}' -f $etiqueta, ($raiz -replace '^Registry::', ''))
    & $Accion $raiz
    $script:HiveModo = $false
    $dc = $script:St.RegCambios - $c0; $do = $script:St.RegOk - $o0
    if (($dc + $do) -gt 0) { UI-Det 'INFO' ('Hive {0}: {1} valor(es) modificado(s), {2} ya estaban correctos.' -f $etiqueta, $dc, $do) }
}

function Invoke-EnUsuarios([scriptblock]$Accion) {
    # 1) Default User (perfiles nuevos)  2) usuarios con sesion cargada  3) perfiles existentes sin sesion
    $def = 'C:\Users\Default\NTUSER.DAT'
    $cargado = $false
    if (Test-Path $def) {
        UI-Det 'CMD' ('reg.exe load HKU\DefUser ' + $def + '  (monta el perfil base de usuarios nuevos)')
        & reg.exe load 'HKU\DefUser' $def 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $cargado = $true } else { UI-Det 'AVISO' 'No se pudo cargar el hive de Default User' }
    }
    if ($cargado) { Invoke-Hive $Accion 'Registry::HKEY_USERS\DefUser' 'Default User (perfiles nuevos)' }

    $sesiones = @(Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' })
    UI-Det 'CONSULTA' ('Hives de usuarios con sesion cargada en HKEY_USERS: {0}' -f $sesiones.Count)
    foreach ($s in $sesiones) {
        Invoke-Hive $Accion ('Registry::HKEY_USERS\' + $s.PSChildName) ('Sesion activa ' + (Resolve-Sid $s.PSChildName))
    }

    $montados = @()
    $n = 0
    $perfiles = @(Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { -not $_.Special -and -not $_.Loaded -and $_.LocalPath })
    UI-Det 'CONSULTA' ('Perfiles sin sesion (Win32_UserProfile, no cargados): {0}' -f $perfiles.Count)
    foreach ($p in $perfiles) {
        $dat = Join-Path $p.LocalPath 'NTUSER.DAT'
        if (-not (Test-Path -LiteralPath $dat)) { UI-Det 'OMITIDO' ('Sin NTUSER.DAT: ' + $p.LocalPath); continue }
        $n++
        $clave = 'TmpUser' + $n
        UI-Det 'CMD' ('reg.exe load HKU\{0} {1}' -f $clave, $dat)
        & reg.exe load ('HKU\' + $clave) $dat 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $montados += $clave
            Invoke-Hive $Accion ('Registry::HKEY_USERS\' + $clave) ('Perfil sin sesion ' + $p.LocalPath)
        } else { UI-Det 'AVISO' ('No se pudo cargar el hive de ' + $p.LocalPath + ' (probablemente en uso)') }
    }

    if ($cargado -or $montados.Count -gt 0) {
        UI-Det 'CMD' 'Liberando hives montados (GC + reg.exe unload)'
        [gc]::Collect(); [gc]::WaitForPendingFinalizers(); Start-Sleep 1
        if ($cargado) { & reg.exe unload 'HKU\DefUser' 2>&1 | Out-Null }
        foreach ($m in $montados) { & reg.exe unload ('HKU\' + $m) 2>&1 | Out-Null }
    }
}

# ------------------------------------------------------------------------------
# Estado del equipo (solo lectura)
# ------------------------------------------------------------------------------
function Write-Estado([string]$tag) {
    Paso 'ESTADO' ('Capturando estado del equipo - ' + $tag)
    UI-Det 'CONSULTA' 'Win32_OperatingSystem (RAM), Get-PSDrive C (disco), powercfg /getactivescheme, BitLocker y Defender. Solo lectura.'
    $os = Get-CimInstance Win32_OperatingSystem
    $ramLibre = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    UI-Resultado 'RAM' ('Libre: {0} GB' -f $ramLibre) 'INFO'
    UI-Resultado 'DISCO C' ('Libre: {0} GB' -f (Get-LibreGB)) 'INFO'
    UI-Resultado 'ENERGIA' ('Plan activo: ' + ((& powercfg /getactivescheme) -join ' ')) 'INFO'
    try {
        $bl = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction Stop
        UI-Resultado 'BITLOCKER' ('C: {0} ({1}% cifrado)' -f $bl.VolumeStatus, $bl.EncryptionPercentage) 'INFO'
    } catch { UI-Resultado 'BITLOCKER' 'Sin informacion' 'INFO' }
    try {
        $d = Get-MpComputerStatus -ErrorAction Stop
        UI-Resultado 'DEFENDER' ('Servicio={0} | Proteccion en tiempo real={1}' -f $d.AMServiceEnabled, $d.RealTimeProtectionEnabled) 'INFO'
    } catch { UI-Resultado 'DEFENDER' 'Sin informacion (puede haber otro antivirus)' 'INFO' }
}

# Diagnostico: quien consume RAM/CPU ahora mismo (solo lectura)
function Write-Diagnostico {
    UI-Det 'CONSULTA' 'Diagnostico de solo lectura: no modifica ningun valor del sistema.'
    Rep 'Corrida' (Get-Date -Format 'dd/MM/yyyy HH:mm:ss')
    $osn = Get-CimInstance Win32_OperatingSystem
    $horas = [math]::Round(((Get-Date) - $osn.LastBootUpTime).TotalHours, 1)
    UI-Det 'LEER' ('Tiempo encendido: {0} horas desde el ultimo arranque' -f $horas)
    Rep 'Tiempo encendido' ('{0} horas desde el ultimo arranque' -f $horas)
    $nCpu = [Environment]::ProcessorCount
    $antes = @{}
    UI-Det 'PROCESO' 'Muestreo de CPU por proceso durante 3 segundos (Get-Process, dos lecturas)...'
    Get-Process -ErrorAction SilentlyContinue | ForEach-Object { if ($null -ne $_.CPU) { $antes[$_.Id] = $_.CPU } }
    Start-Sleep -Seconds 3
    $cpuTop = Get-Process -ErrorAction SilentlyContinue | Where-Object { $antes.ContainsKey($_.Id) -and $null -ne $_.CPU } |
        ForEach-Object { [pscustomobject]@{ Proceso = $_.ProcessName; Pct = (($_.CPU - $antes[$_.Id]) / 3 / $nCpu) * 100 } } |
        Group-Object Proceso |
        ForEach-Object { [pscustomobject]@{ Proceso = $_.Name; CPU_pct = [math]::Round(($_.Group | Measure-Object Pct -Sum).Sum, 1) } } |
        Sort-Object CPU_pct -Descending | Select-Object -First 10
    foreach ($c in $cpuTop) { UI-Det 'LEER' ('CPU  {0,-28} {1} %' -f $c.Proceso, $c.CPU_pct) }
    Rep 'Top 10 procesos por CPU (muestra de 3 s)' $cpuTop
    $ramTot = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
    $ramLib = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB, 1)
    UI-Det 'LEER' ('Memoria: total {0} GB | libre {1} GB' -f $ramTot, $ramLib)
    Rep 'Memoria' ('RAM total: {0} GB | libre: {1} GB' -f $ramTot, $ramLib)
    $ramTop = Get-Process -ErrorAction SilentlyContinue | Group-Object ProcessName |
        ForEach-Object { [pscustomobject]@{ Proceso = $_.Name; Instancias = $_.Count; RAM_MB = [math]::Round(($_.Group | Measure-Object WorkingSet64 -Sum).Sum / 1MB) } } |
        Sort-Object RAM_MB -Descending | Select-Object -First 15
    foreach ($r in ($ramTop | Select-Object -First 5)) { UI-Det 'LEER' ('RAM  {0,-28} {1} MB ({2} instancia(s))' -f $r.Proceso, $r.RAM_MB, $r.Instancias) }
    Rep 'Top 15 procesos por RAM (agrupados)' $ramTop
    UI-Det 'CONSULTA' 'Get-ScheduledTask: tareas activas que no son de Microsoft'
    $tareasNoMs = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.State -ne 'Disabled' -and $_.TaskPath -notlike '\Microsoft\*' } | Select-Object TaskName, TaskPath, State)
    UI-Det 'INFO' ('Tareas programadas activas (no Microsoft): {0}' -f $tareasNoMs.Count)
    Rep 'Tareas programadas activas (no Microsoft)' $tareasNoMs
    UI-Det 'CONSULTA' 'Win32_Service: servicios automaticos en ejecucion fuera de system32/Windows'
    $svcNoMs = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.StartMode -eq 'Auto' -and $_.State -eq 'Running' -and $_.PathName -notmatch 'system32|SysWOW64|Windows\\' } | Select-Object Name, DisplayName)
    UI-Det 'INFO' ('Servicios automaticos en ejecucion (no Microsoft): {0}' -f $svcNoMs.Count)
    Rep 'Servicios automaticos en ejecucion (no Microsoft)' $svcNoMs
}

# ==============================================================================
# INICIO
# ==============================================================================
UI-Header
Write-Host ('{0,-12}{1}' -f '  Equipo :', $env:COMPUTERNAME) -ForegroundColor White
Write-Host ('{0,-12}{1}' -f '  Fase   :', $Fase) -ForegroundColor White
Write-Host ('{0,-12}{1}' -f '  Fecha  :', (Get-Date -Format 'dd/MM/yyyy HH:mm')) -ForegroundColor White
Write-Host ('{0,-12}{1}' -f '  Log    :', $LogFile) -ForegroundColor White
Write-Host ('{0,-12}{1}' -f '  Reporte:', $Report) -ForegroundColor White
UI-Separador
UI-SeccionTitulo 'PARAMETROS DE CONFIGURACION ACTIVOS'
function Fmt-Flag([bool]$v, [string]$txt) { if ($v) { 'SI  - ' + $txt } else { 'NO  - ' + $txt } }
UI-SubInfo 'Reset energia' (Fmt-Flag $ResetPlanesEnergia 'restaurar planes de energia de Windows')
UI-SubInfo 'Quitar UWP'    (Fmt-Flag $QuitarAppx 'desinstalar apps preinstaladas innecesarias')
UI-SubInfo 'Quitar OEM'    (Fmt-Flag $QuitarBloatOEM 'bloatware de HP / Dell / McAfee')
UI-SubInfo 'DISM limpieza' (Fmt-Flag $DismLimpieza 'StartComponentCleanup (WinSxS)')
UI-SubInfo 'Efectos vis.'  (Fmt-Flag $EfectosVisualesMinimos 'efectos visuales minimos')
UI-SubInfo 'Apagar Recall' (Fmt-Flag $ApagarRecall 'politicas de IA de Windows (Recall / Click to Do)')
UI-SubInfo 'Optimizar WSL' (Fmt-Flag $OptimizarWSL 'crear .wslconfig con liberacion gradual de RAM')
UI-SubInfo 'Docker inicio' (Fmt-Flag $QuitarDockerInicio 'quitar Docker Desktop del inicio')
UI-SubInfo 'Telemetria'    (Fmt-Flag $DeshabilitarTelemetria 'deshabilitar servicio DiagTrack')
Write-LogFile ('######## INICIO - Fase: {0} ########' -f $Fase)

# =====================================================================
#  FASE CONFIG
# =====================================================================
if ($Fase -eq 'Todo' -or $Fase -eq 'Config') {

    UI-Separador
    UI-SeccionTitulo 'FASE 1: OPTIMIZACION (CONFIGURACION)'

    $cs  = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $bio = Get-CimInstance Win32_BIOS
    $os  = Get-CimInstance Win32_OperatingSystem
    $ver = (Get-CimInstance Win32_ComputerSystemProduct).Version
    if ([string]::IsNullOrWhiteSpace($ver) -or $ver -match 'None|Not Applicable|To be filled') { $ver = ('{0} {1}' -f $cs.Manufacturer, $cs.Model).Trim() }
    Rep 'Equipo' ("Modelo: $ver`r`nCPU: $($cpu.Name)`r`nBIOS: $($bio.SMBIOSBIOSVersion) ($($bio.ReleaseDate))`r`nWindows: $($os.Caption) build $($os.BuildNumber)")
    Write-Estado 'INICIAL'
    UI-SubInfo 'Modelo'  $ver
    UI-SubInfo 'CPU'     ($cpu.Name.Trim())
    UI-SubInfo 'RAM'     ('{0} GB' -f [math]::Round($cs.TotalPhysicalMemory / 1GB))
    UI-SubInfo 'BIOS'    $bio.SMBIOSBIOSVersion
    UI-SubInfo 'Windows' ('{0} build {1}' -f $os.Caption, $os.BuildNumber)

    # ---- Energia ----
    Paso 'ENERGIA' 'Configurando plan de energia, limite de CPU e inicio rapido...'
    try {
        UI-Det 'LEER' ('Plan activo antes del cambio: ' + ((& powercfg /getactivescheme) -join ' '))
        if ($ResetPlanesEnergia) {
            UI-Det 'CMD' 'powercfg -restoredefaultschemes  (restaura los planes originales de Windows y elimina planes personalizados del fabricante)'
            & powercfg -restoredefaultschemes | Out-Null
            UI-Det 'MODIFICA' 'Planes de energia restaurados a valores de Windows.'
        } else { UI-Det 'OMITIDO' 'ResetPlanesEnergia = false: no se restauran los planes.' }
        UI-Det 'CMD' 'powercfg -setactive 381b4222-f694-41f0-9685-ff5bb260df2e  (activa el plan Equilibrado)'
        & powercfg -setactive 381b4222-f694-41f0-9685-ff5bb260df2e | Out-Null
        UI-Det 'CONFIG' 'powercfg -setacvalueindex SUB_PROCESSOR PROCTHROTTLEMAX = 100 %  (CPU maximo con corriente AC)'
        & powercfg -setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100 | Out-Null
        UI-Det 'CONFIG' 'powercfg -setdcvalueindex SUB_PROCESSOR PROCTHROTTLEMAX = 100 %  (CPU maximo con bateria)'
        & powercfg -setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 100 | Out-Null
        UI-Det 'CMD' 'powercfg -setactive SCHEME_CURRENT  (aplica los cambios al plan vigente)'
        & powercfg -setactive SCHEME_CURRENT | Out-Null
        UI-Det 'REGISTRO' 'Inicio rapido (Hiberboot): HiberbootEnabled = 0'
        Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0
        UI-Resultado 'ENERGIA' ('Plan activo ahora: ' + ((& powercfg /getactivescheme) -join ' ')) 'OK'
    } catch { UI-Resultado 'ENERGIA' ('ERROR: ' + $_.Exception.Message) 'ERROR' }

    # ---- Politicas de maquina (HKLM) ----
    Paso 'POLITICAS' 'Aplicando politicas del equipo (HKLM\SOFTWARE\Policies)...'
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
    } else { UI-Det 'OMITIDO' 'ApagarRecall = false: no se aplican politicas WindowsAI.' }
    UI-Det 'INFO' ('Se evaluaran {0} politicas. Para cada una: si ya esta correcta se informa [OK]; si no, se muestra valor anterior -> nuevo.' -f $pol.Count)
    $c0 = $script:St.RegCambios; $o0 = $script:St.RegOk
    foreach ($r in $pol) { Set-Reg $r[0] $r[1] $r[2] $r[3] }
    UI-Resultado 'POLITICAS' ('{0} politicas evaluadas: {1} modificadas, {2} ya correctas' -f $pol.Count, ($script:St.RegCambios - $c0), ($script:St.RegOk - $o0)) 'OK'

    # ---- Ajustes de usuario (Default User + usuarios con sesion cargada) ----
    Paso 'USUARIOS' 'Aplicando ajustes de usuario (perfil por defecto y perfiles existentes)...'
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
    # Efectos visuales: perfil "personalizado" (VisualFXSetting=3) con lo pesado apagado;
    # se conserva suavizado de fuentes (ClearType) y miniaturas, que si ayudan al usuario.
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
        UI-Det 'INFO' 'Efectos visuales minimos: se aplican al proximo inicio de sesion de cada usuario.'
    } else { UI-Det 'OMITIDO' 'EfectosVisualesMinimos = false: no se tocan efectos visuales.' }
    UI-Det 'INFO' ('{0} ajustes por perfil. Solo se muestran los valores que cambian; por hive se informa el resumen.' -f $tw.Count)
    Invoke-EnUsuarios {
        param($raiz)
        foreach ($t in $tw) { Set-Reg ($raiz + '\' + $t[0]) $t[1] $t[2] $t[3] }
    }
    UI-Resultado 'USUARIOS' ('{0} ajustes por perfil aplicados (perfil por defecto, sesiones y perfiles existentes)' -f $tw.Count) 'OK'

    # ---- Servicios ----
    Paso 'SERVICIOS' 'Deshabilitando servicios innecesarios (con respaldo previo)...'
    try {
        $csv = Join-Path $RepDir ('{0}_{1}_servicios_antes.csv' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd'))
        UI-Det 'CONSULTA' 'Win32_Service: leyendo arranque y estado de TODOS los servicios para respaldo'
        Get-CimInstance Win32_Service | Select-Object Name, StartMode, State |
            Export-Csv -Path $csv -NoTypeInformation -ErrorAction Stop
        UI-Det 'CREAR' ('Respaldo del arranque original de servicios (para revertir): ' + $csv)
    } catch { UI-Det 'AVISO' ('No se pudo guardar el respaldo de servicios: ' + $_.Exception.Message) }
    $servicios = @('WerSvc','XblAuthManager','XblGameSave','XboxGipSvc','XboxNetApiSvc','MapsBroker','lfsvc','RetailDemo','WMPNetworkSvc','MixedRealityOpenXRSvc','PhoneSvc','Fax','RemoteRegistry',
                   'dmwappushservice','AJRouter','WpcMonSvc','SEMgrSvc','wisvc','WalletService','lltdsvc','workfolderssvc','SmsRouter','SSDPSRV','upnphost')
    if ($DeshabilitarTelemetria) { $servicios += 'DiagTrack' } else { UI-Det 'OMITIDO' 'DeshabilitarTelemetria = false: el servicio DiagTrack NO se toca.' }
    $svcMap = @{}
    Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | ForEach-Object { $svcMap[$_.Name] = $_ }
    foreach ($s in $servicios) {
        $o = $svcMap[$s]
        if (-not $o) { $script:St.SvcAusente++; UI-Det 'OMITIDO' ('Servicio {0}: no existe en este equipo' -f $s); continue }
        UI-Det 'CMD' ('sc.exe config {0} start= disabled  |  sc.exe stop {0}' -f $s)
        & sc.exe config $s start= disabled | Out-Null
        $rc = $LASTEXITCODE
        & sc.exe stop $s 2>&1 | Out-Null
        if ($o.State -eq 'Running') { Start-Sleep -Milliseconds 400 }
        $n = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $s) -ErrorAction SilentlyContinue
        $script:St.SvcDeshab++
        $tipo = if ($rc -eq 0) { 'SERVICIO' } else { 'AVISO' }
        UI-Det $tipo ('{0} ({1})  Inicio: {2} -> {3}  |  Estado: {4} -> {5}  |  sc config rc={6}' -f $s, $o.DisplayName, $o.StartMode, $n.StartMode, $o.State, $n.State, $rc)
    }
    if (Get-Service -Name 'AdobeARMservice' -ErrorAction SilentlyContinue) {
        UI-Det 'CMD' 'sc.exe config AdobeARMservice start= demand  (pasa a manual, no se deshabilita)'
        & sc.exe config AdobeARMservice start= demand | Out-Null
        UI-Det 'SERVICIO' 'AdobeARMservice: Inicio -> Manual (demand)'
    } else { UI-Det 'OMITIDO' 'AdobeARMservice no existe en este equipo' }
    UI-Resultado 'SERVICIOS' ('{0} servicio(s) deshabilitados, {1} no existian en el equipo' -f $script:St.SvcDeshab, $script:St.SvcAusente) 'OK'
    UI-Det 'INFO' 'SysMain, Windows Update, Office y navegadores NO se tocan.'

    # ---- Tareas programadas ----
    Paso 'TAREAS' 'Deshabilitando tareas programadas de telemetria / CEIP...'
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
    foreach ($t in $tareas) {
        $ruta = $t[0] + $t[1]
        $tk = Get-ScheduledTask -TaskPath $t[0] -TaskName $t[1] -ErrorAction SilentlyContinue
        if (-not $tk) { UI-Det 'OMITIDO' ('Tarea no existe: ' + $ruta); continue }
        $antes = [string]$tk.State
        if ($antes -eq 'Disabled') { UI-Det 'OK' ('Tarea ya deshabilitada: ' + $ruta); continue }
        UI-Det 'CMD' ('Disable-ScheduledTask -TaskPath "{0}" -TaskName "{1}"' -f $t[0], $t[1])
        Disable-ScheduledTask -TaskPath $t[0] -TaskName $t[1] -ErrorAction SilentlyContinue | Out-Null
        $despues = [string](Get-ScheduledTask -TaskPath $t[0] -TaskName $t[1] -ErrorAction SilentlyContinue).State
        $script:St.Tareas++
        UI-Det 'TAREA' ('{0}  Estado: {1} -> {2}' -f $ruta, $antes, $despues)
    }
    UI-Det 'CONSULTA' 'Buscando tareas de adware en la carpeta \SoftLanding\'
    $soft = @(Get-ScheduledTask -TaskPath '\SoftLanding\*' -ErrorAction SilentlyContinue)
    if ($soft.Count -eq 0) { UI-Det 'OMITIDO' 'No hay tareas en \SoftLanding\' }
    foreach ($tsk in $soft) {
        $antes = [string]$tsk.State
        $tsk | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
        $script:St.Tareas++
        UI-Det 'TAREA' ('{0}{1}  Estado: {2} -> Disabled' -f $tsk.TaskPath, $tsk.TaskName, $antes)
    }
    UI-Resultado 'TAREAS' ('{0} tarea(s) programadas deshabilitadas en esta ejecucion' -f $script:St.Tareas) 'OK'

    # ---- Programas de inicio ----
    Paso 'INICIO' 'Limpiando entradas de inicio innecesarias (equipo y usuarios)...'
    $inicioBasura = @('Spotify','Discord','EpicGamesLauncher','SteamService','Steam','iTunesHelper','ApplePhotoStreams','AdobeAAMUpdater-1.0','AdobeGCInvoker-1.0','AcroTray','Adobe ARM','SunJavaUpdateSched')
    foreach ($rk in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run') {
        UI-Det 'RUTA' ('Revisando clave de inicio: ' + $rk)
        $props = Get-ItemProperty -LiteralPath $rk -ErrorAction SilentlyContinue
        $quitadas = 0
        foreach ($n in $inicioBasura) {
            if ($props -and ($props.PSObject.Properties.Name -contains $n)) {
                $cmd = $props.$n
                Remove-ItemProperty -LiteralPath $rk -Name $n -ErrorAction SilentlyContinue
                $script:St.Inicio++; $quitadas++
                UI-Det 'ELIMINA' ('Entrada de inicio {0}\{1}  (comando: {2})' -f $rk, $n, $cmd)
            }
        }
        if ($quitadas -eq 0) { UI-Det 'OK' 'Sin entradas basura en esta clave.' }
    }
    # Igual por usuario (HKCU\Run) + autolanzadores de Edge/Chrome en segundo plano. Teams y OneDrive NO se tocan.
    Invoke-EnUsuarios {
        param($raiz)
        $run = $raiz + '\Software\Microsoft\Windows\CurrentVersion\Run'
        if (-not (Test-Path $run)) { return }
        foreach ($p in @((Get-Item $run).Property)) {
            if (($inicioBasura -contains $p) -or $p -like 'MicrosoftEdgeAutoLaunch*' -or $p -like 'GoogleChromeAutoLaunch*' -or ($QuitarDockerInicio -and $p -eq 'Docker Desktop')) {
                $cmd = (Get-ItemProperty -LiteralPath $run -Name $p -ErrorAction SilentlyContinue).$p
                Remove-ItemProperty -Path $run -Name $p -ErrorAction SilentlyContinue
                $script:St.Inicio++
                UI-Det 'ELIMINA' ('Entrada de inicio de usuario {0}\{1}  (comando: {2})' -f ($run -replace '^Registry::HKEY_USERS\\', 'HKU\'), $p, $cmd)
            }
        }
    }
    UI-Resultado 'INICIO' ('{0} entrada(s) de inicio eliminadas (Teams y OneDrive no se tocan)' -f $script:St.Inicio) 'OK'

    # ---- Debloat de apps UWP (se consulta la lista UNA sola vez) ----
    Paso 'UWP' 'Desinstalando apps preinstaladas innecesarias...'
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
        else { UI-Det 'OMITIDO' 'QuitarBloatOEM = false: no se buscan paquetes HP/Dell/McAfee.' }
        UI-Det 'CONSULTA' 'Get-AppxPackage -AllUsers y Get-AppxProvisionedPackage -Online (una sola consulta)'
        $instalados  = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)
        $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)
        UI-Det 'INFO' ('Paquetes instalados: {0} | provisionados: {1} | patrones a evaluar: {2}' -f $instalados.Count, $provisioned.Count, $patrones.Count)
        $hechosPkg  = @{}
        $hechosProv = @{}
        foreach ($p in $patrones) {
            foreach ($a in ($instalados | Where-Object { $_.Name -like $p })) {
                if ($hechosPkg.ContainsKey($a.PackageFullName)) { continue }
                $hechosPkg[$a.PackageFullName] = $true
                UI-Det 'CMD' ('Remove-AppxPackage -AllUsers  {0}' -f $a.PackageFullName)
                Remove-AppxPackage -Package $a.PackageFullName -AllUsers -ErrorAction SilentlyContinue
                $script:St.Apps++
                UI-Det 'APP' ('Removida: {0} v{1}  (patron: {2})' -f $a.Name, $a.Version, $p)
            }
            foreach ($v in ($provisioned | Where-Object { $_.DisplayName -like $p })) {
                if ($hechosProv.ContainsKey($v.PackageName)) { continue }
                $hechosProv[$v.PackageName] = $true
                UI-Det 'CMD' ('Remove-AppxProvisionedPackage -Online  {0}  (evita que se reinstale en usuarios nuevos)' -f $v.PackageName)
                Remove-AppxProvisionedPackage -Online -PackageName $v.PackageName -ErrorAction SilentlyContinue | Out-Null
                $script:St.AppsProv++
                UI-Det 'APP' ('Desaprovisionada: {0}' -f $v.DisplayName)
            }
        }
        UI-Resultado 'UWP' ('{0} app(s) removidas, {1} desaprovisionada(s)' -f $script:St.Apps, $script:St.AppsProv) 'OK'
        UI-Det 'INFO' "Teams de trabajo (MSTeams), Store, Fotos, Calculadora, Terminal, Quick Assist y Portal de empresa NO se tocan."
    } else { UI-Resultado 'UWP' 'Desactivado en configuracion (QuitarAppx = false)' 'INFO' }

    # ---- Ajustes de sistema seguros ----
    Paso 'SISTEMA' 'Ajustes seguros de sistema de archivos y WSL...'
    UI-Det 'CMD' 'fsutil behavior query disablelastaccess  (valor actual)'
    $fsAntes = (& fsutil.exe behavior query disablelastaccess 2>&1 | Out-String).Trim()
    UI-Det 'LEER' ('Antes: ' + $fsAntes)
    UI-Det 'CMD' 'fsutil behavior set disablelastaccess 1  (NTFS deja de escribir la fecha de ultimo acceso en cada lectura)'
    & fsutil.exe behavior set disablelastaccess 1 | Out-Null
    $fsDespues = (& fsutil.exe behavior query disablelastaccess 2>&1 | Out-String).Trim()
    UI-Det 'MODIFICA' ('NTFS ultimo acceso. Despues: ' + $fsDespues)

    if ($OptimizarWSL -and (Test-Path 'C:\Windows\System32\wsl.exe')) {
        $wslTxt = "[wsl2]`r`n`r`n[experimental]`r`nautoMemoryReclaim=gradual`r`n"
        UI-Det 'CONSULTA' 'WSL detectado (C:\Windows\System32\wsl.exe). Revisando .wslconfig en cada perfil de C:\Users'
        Get-ChildItem 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin 'Public','Default','Default User','All Users' } | ForEach-Object {
                $cfg = Join-Path $_.FullName '.wslconfig'
                UI-Det 'RUTA' ('Perfil ' + $_.FullName)
                if (-not (Test-Path -LiteralPath $cfg)) {
                    Set-Content -Path $cfg -Value $wslTxt -Encoding ASCII -ErrorAction SilentlyContinue
                    UI-Det 'CREAR' ('{0}  (autoMemoryReclaim=gradual: libera RAM de WSL de forma progresiva)' -f $cfg)
                } else { UI-Det 'OK' ('.wslconfig ya existe, no se sobrescribe: ' + $cfg) }
            }
    } else { UI-Det 'OMITIDO' 'WSL: opcion desactivada o wsl.exe no esta instalado.' }
    UI-Resultado 'SISTEMA' 'Ajustes de sistema aplicados' 'OK'
}

# =====================================================================
#  FASE LIMPIEZA
# =====================================================================
if ($Fase -eq 'Todo' -or $Fase -eq 'Limpieza') {

    UI-Separador
    UI-SeccionTitulo 'FASE 2: LIMPIEZA DE ARCHIVOS TEMPORALES'
    $libreInicio = Get-LibreGB

    Paso 'LIMPIEZA' 'Eliminando temporales, volcados de error y papelera...'
    UI-Det 'INFO' ('Espacio libre en C: antes de limpiar: {0} GB' -f $libreInicio)
    Remove-Contenido 'C:\Windows\Temp' 'temporales del sistema'
    Remove-Contenido 'C:\ProgramData\Microsoft\Windows\WER' 'reportes de errores de Windows'
    Remove-Contenido 'C:\Windows\Minidump' 'volcados pequenos de pantallazo azul'
    Remove-Archivos 'C:\Windows\MEMORY.DMP'
    UI-Det 'CONSULTA' 'Recorriendo perfiles de C:\Users (se excluyen Public, Default, Default User, All Users)'
    Get-ChildItem 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin 'Public','Default','Default User','All Users' } | ForEach-Object {
            $u = $_.FullName
            UI-Det 'RUTA' ('Perfil de usuario: ' + $u)
            Remove-Contenido (Join-Path $u 'AppData\Local\Temp') 'temporales del usuario'
            Remove-Contenido (Join-Path $u 'AppData\Local\CrashDumps') 'volcados de aplicaciones'
            Remove-Archivos (Join-Path $u 'AppData\Local\Microsoft\Windows\Explorer\thumbcache_*.db') -Silencioso
        }
    try {
        $sh = New-Object -ComObject Shell.Application
        $nPap = @($sh.NameSpace(0xA).Items()).Count
        UI-Det 'RUTA' ('Papelera de reciclaje: {0} elemento(s)' -f $nPap)
    } catch { UI-Det 'RUTA' 'Papelera de reciclaje (conteo no disponible)' }
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
    UI-Det 'ELIMINA' 'Papelera de reciclaje vaciada (Clear-RecycleBin, todas las unidades)'
    UI-Det 'CMD' 'ipconfig.exe /flushdns  (vacia la cache DNS del equipo)'
    & ipconfig.exe /flushdns | Out-Null
    $libreDesp = Get-LibreGB
    UI-Resultado 'LIMPIEZA' ('Liberado aprox. {0} GB (C: libre: {1} GB -> {2} GB)' -f [math]::Round($libreDesp - $libreInicio, 1), $libreInicio, $libreDesp) 'OK'

    Paso 'DISM' 'Limpieza de componentes de Windows (WinSxS)...'
    if ($DismLimpieza) {
        UI-Det 'CMD' 'dism.exe /Online /Cleanup-Image /StartComponentCleanup  (elimina versiones antiguas de componentes en C:\Windows\WinSxS)'
        $dp = Start-Process -FilePath 'dism.exe' -ArgumentList '/Online /Cleanup-Image /StartComponentCleanup' -PassThru -WindowStyle Hidden
        if ($dp) {
            UI-Det 'PROCESO' ('DISM lanzado (PID {0}). Esperando; puede tardar varios minutos.' -f $dp.Id)
            Write-Host (' ' * 20) -NoNewline
            Write-Host 'Ejecutando ' -NoNewline -ForegroundColor DarkCyan
            while (-not $dp.HasExited) { Write-Host '.' -NoNewline -ForegroundColor Cyan; Start-Sleep -Seconds 5 }
            Write-Host ' [FIN]' -ForegroundColor Green
            $dp.WaitForExit()
            if ($dp.ExitCode -eq 0) { UI-Resultado 'DISM' 'Componentes obsoletos eliminados (codigo 0)' 'OK' }
            else { UI-Resultado 'DISM' ('Termino con codigo {0}' -f $dp.ExitCode) 'WARN' }
        } else { UI-Resultado 'DISM' 'No se pudo lanzar dism.exe' 'ERROR' }
    } else {
        UI-Det 'OMITIDO' 'DismLimpieza = false: no se ejecuta DISM StartComponentCleanup.'
        UI-Resultado 'DISM' 'Omitido por configuracion' 'INFO'
    }

    Paso 'TRIM' 'Detectando tipo de disco y optimizando SSD...'
    $discoTipo = 'Desconocido'
    try {
        UI-Det 'CONSULTA' 'Get-Partition C -> Get-Disk -> Get-PhysicalDisk (tipo de medio y bus)'
        $num = (Get-Partition -DriveLetter C -ErrorAction Stop | Get-Disk).Number
        $pd  = Get-PhysicalDisk | Where-Object { [int]$_.DeviceId -eq $num } | Select-Object -First 1
        if ($pd) {
            if ($pd.BusType -eq 'NVMe') { $discoTipo = 'NVMe' } else { $discoTipo = [string]$pd.MediaType }
            UI-Det 'LEER' ('Disco {0}: {1} | Bus: {2} | Medio: {3} | Salud: {4}' -f $num, $pd.FriendlyName, $pd.BusType, $pd.MediaType, $pd.HealthStatus)
        }
    } catch { UI-Det 'AVISO' 'No se pudo determinar el tipo de disco.' }
    if ($discoTipo -eq 'NVMe' -or $discoTipo -eq 'SSD') {
        UI-Det 'CMD' 'Optimize-Volume -DriveLetter C -ReTrim  (informa al SSD que bloques estan libres)'
        Optimize-Volume -DriveLetter C -ReTrim -ErrorAction SilentlyContinue
        UI-Resultado 'TRIM' ('TRIM ejecutado en C: ({0})' -f $discoTipo) 'OK'
    } else {
        UI-Det 'OMITIDO' ('Disco tipo "{0}": TRIM solo aplica a SSD/NVMe.' -f $discoTipo)
        UI-Resultado 'TRIM' 'No aplica (disco no es SSD/NVMe)' 'INFO'
    }

    Paso 'INVENTARIO' 'Generando inventario de software y programas de inicio...'
    UI-Det 'REGISTRO' 'Leyendo HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall\* y WOW6432Node (solo lectura)'
    $sw = Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
          Where-Object { $_.DisplayName } | Sort-Object DisplayName | Select-Object DisplayName, DisplayVersion, Publisher
    UI-Det 'INFO' ('Programas instalados detectados: {0}' -f @($sw).Count)
    Rep 'Software instalado' $sw
    UI-Det 'CONSULTA' 'Win32_StartupCommand: programas de inicio'
    $ini = @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue | Select-Object Name, Command, Location, User)
    UI-Det 'INFO' ('Programas de inicio detectados: {0}' -f $ini.Count)
    Rep 'Programas de inicio' $ini
    UI-Resultado 'INVENTARIO' ('{0} programas instalados, {1} de inicio registrados en el reporte' -f @($sw).Count, $ini.Count) 'OK'

    Paso 'DIAGNOSTICO' 'Diagnostico de consumo de CPU, RAM, tareas y servicios...'
    Write-Diagnostico
    UI-Resultado 'DIAGNOSTICO' 'Diagnostico guardado en el reporte' 'OK'

    Write-Estado 'FINAL'
    UI-Det 'RUTA' ('Reporte completo: ' + $Report)
}

if ($Fase -eq 'Reporte') {
    UI-Separador
    UI-SeccionTitulo 'REPORTE (SOLO LECTURA)'
    Write-Estado 'REPORTE'
    Paso 'DIAGNOSTICO' 'Diagnostico de consumo de CPU, RAM, tareas y servicios...'
    Write-Diagnostico
    UI-Resultado 'DIAGNOSTICO' 'Diagnostico guardado en el reporte' 'OK'
    UI-Det 'RUTA' ('Reporte completo: ' + $Report)
}

# ==============================================================================
# RESUMEN FINAL
# ==============================================================================
$Cronometro.Stop()
Write-Host ''
UI-Linea '=' 'Green'
UI-Centrar 'PROCESO FINALIZADO' 'Green'
UI-Linea '=' 'Green'
Write-Host ''
$resumen = @(
    @('Duracion total',            $Cronometro.Elapsed.ToString('mm\:ss')),
    @('Valores de registro',       ('{0} modificados | {1} ya correctos | {2} con error' -f $script:St.RegCambios, $script:St.RegOk, $script:St.RegErr)),
    @('Servicios deshabilitados',  [string]$script:St.SvcDeshab),
    @('Tareas deshabilitadas',     [string]$script:St.Tareas),
    @('Entradas de inicio quitadas', [string]$script:St.Inicio),
    @('Apps UWP removidas',        ('{0} instaladas | {1} provisionadas' -f $script:St.Apps, $script:St.AppsProv)),
    @('Archivos eliminados (MB)',  [string](Fmt-MB $script:St.BytesLiberados)),
    @('Log detallado',             $LogFile),
    @('Reporte',                   $Report)
)
foreach ($r in $resumen) {
    Write-Host ('  {0,-30}: ' -f $r[0]) -NoNewline -ForegroundColor DarkGray
    Write-Host $r[1] -ForegroundColor White
}
Write-Host ''
UI-Linea '=' 'DarkCyan'
Write-Host ''
Write-LogFile ('######## FIN - Fase: {0} ########' -f $Fase)

exit 0
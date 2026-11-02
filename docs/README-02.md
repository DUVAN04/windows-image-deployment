## Flujo del procedimiento

```mermaid
flowchart LR
    A["Fase 1<br/>Preparación<br/>Pasos 1–2"] --> B["Fase 2<br/>Limpieza<br/>Pasos 3–9"]
    B --> C["Fase 3<br/>Generalización<br/>Pasos 10–11"]
    C --> D["Fase 4<br/>Captura<br/>Paso 12"]

    classDef f1 fill:#DBEAFE,stroke:#2563EB,stroke-width:2px,color:#1E293B
    classDef f2 fill:#DCFCE7,stroke:#16A34A,stroke-width:2px,color:#1E293B
    classDef f3 fill:#FEF3C7,stroke:#D97706,stroke-width:2px,color:#1E293B
    classDef f4 fill:#EDE9FE,stroke:#7C3AED,stroke-width:2px,color:#1E293B

    class A f1
    class B f2
    class C f3
    class D f4
```

<br>
<br>

---

## Fase 1 · Preparación

### 1. Modo Auditoría

En la pantalla OOBE, presione <kbd>Ctrl</kbd> + <kbd>Shift</kbd> + <kbd>F3</kbd>. El equipo reinicia y entra en Modo Auditoría. Cierre la ventana de Sysprep que aparece.

<p align="center">
  <img src="../pictures/sysprep/01.png" width="32%" alt="Modo Auditoría 1">
  <img src="../pictures/sysprep/02.png" width="32%" alt="Modo Auditoría 2">
  <img src="../pictures/sysprep/03.png" width="32%" alt="Modo Auditoría 3">
</p>

<br>

### 2. Instalación de aplicaciones

Instale el software corporativo y aplique los ajustes de Windows que requiera su empresa.

> [!IMPORTANT]
> Instale todo en `C:\Program Files` con instaladores para todos los usuarios (*System*), no *User Setup*. Ver [Requisitos críticos](../README.md#requisitos-críticos).

<p align="center">
  <img src="../pictures/sysprep/software/02.png" width="32%" alt="Instalación de aplicaciones 1">
  <img src="../pictures/sysprep/software/04.png" width="32%" alt="Instalación de aplicaciones 2">
</p>

<br>
<br>

---

## Fase 2 · Limpieza

> [!NOTE]
> **Consola:** CMD como administrador · pasos 3 a 9

### 3. Detener servicios de actualización

```cmd
net stop wuauserv
net stop bits
net stop cryptsvc
```

<br>

### 4. Limpiar el almacén de componentes

```cmd
dism /Online /Cleanup-Image /StartComponentCleanup /ResetBase
```

El proceso debe llegar al 100 %. `/ResetBase` impide desinstalar las actualizaciones ya instaladas.

<br>

### 5. Limpiar la caché de Windows Update

```cmd
rd /s /q C:\Windows\SoftwareDistribution\Download
mkdir C:\Windows\SoftwareDistribution\Download
```

<br>

### 6. Limpiar el disco

```cmd
cleanmgr /sageset:1
cleanmgr /sagerun:1
```

En la ventana de `sageset`, marque todas las categorías y acepte.

<br>

### 7. Eliminar temporales y papelera

```cmd
del /q /f /s "%TEMP%\*"
del /q /f /s "C:\Windows\Temp\*"
rd /s /q C:\$Recycle.Bin
```

<br>

### 8. Eliminar registros de eventos

```cmd
for /F "tokens=*" %G in ('wevtutil el') do wevtutil cl "%G"
```

<br>

### 9. Eliminar logs de Sysprep y DISM

```cmd
del /q /f "C:\Windows\System32\Sysprep\Panther\*.*"
del /q /f "C:\Windows\Logs\DISM\*.*"
```

<br>
<br>

---

## Fase 3 · Generalización

> [!NOTE]
> **Consola como administrador:** PowerShell en el paso 10 · CMD en el paso 11

### 10. Verificar paquetes AppX

Verifique que no haya paquetes en estado *staged*:

```powershell
Get-AppxPackage -AllUsers | Where-Object {$_.PackageUserInformation -match "Staged"} | Select Name,PackageFullName
```

Si aparece alguno, elimínelo:

```powershell
Remove-AppxPackage -Package "NombreCompletoDelPaquete" -AllUsers
```

<br>

### 11. Generalizar con Sysprep

```cmd
C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown
```

El equipo se apaga al finalizar. Si Sysprep falla, revise `C:\Windows\System32\Sysprep\Panther\setuperr.log`.

> [!CAUTION]
> **No inicie Windows después de este paso.** Si arranca normalmente, el sistema entra al OOBE y todo el proceso debe repetirse.

<br>
<br>

---

## Fase 4 · Captura

> [!NOTE]
> **Consola:** CMD en WinPE

### 12. Capturar la imagen

Arranque desde WinPE o un USB booteable.

> [!TIP]
> Verifique las letras de unidad con `diskpart` → `list volume`. En esta guía, `C:` es Windows y `D:` es la unidad externa.

```cmd
mkdir D:\Scratch
dism /Capture-Image /ImageFile:D:\install.wim /CaptureDir:C:\ /Name:"Windows Personalizado Rapido" /Description:"Imagen Sysprep optimizada" /Compress:fast /ScratchDir:D:\Scratch
```

<p align="center">
  <img src="../pictures/sysprep/07.png" width="32%" alt="Captura en ejecución">
  <img src="../pictures/sysprep/08.png" width="32%" alt="Captura finalizada">
</p>

> [!IMPORTANT]
> Espere a que DISM llegue al **100 %** y muestre el mensaje de finalización. No interrumpa el proceso ni apague el equipo.

<br>
<br>

---

**Siguiente paso:** [Aplicación de imagen y secuencias de despliegue](README-03.md)
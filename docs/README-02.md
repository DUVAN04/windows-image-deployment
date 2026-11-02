# Guía de ejecución

Procedimiento para preparar una instalación de Windows 11, aplicar tareas de mantenimiento, generalizar el sistema y generar una imagen reutilizable mediante Sysprep y DISM.

---

## Fase 1 · Preparación

### 1. Modo Auditoría

En la pantalla OOBE, presione `Ctrl + Shift + F3`. El equipo se reinicia y entra en modo auditoría mediante la cuenta de administrador integrada.

Cierre la ventana de Sysprep que aparece al ingresar; se utilizará más adelante.

<p align="center">
  <img src="../pictures/sysprep/01.png" width="30%" alt="Inicio del modo auditoría">
  <img src="../pictures/sysprep/02.png" width="30%" alt="Ingreso al modo auditoría">
  <img src="../pictures/sysprep/03.png" width="30%" alt="Escritorio en modo auditoría">
</p>

### 2. Instalación de software y configuración

Instale las aplicaciones corporativas y aplique los ajustes de Windows requeridos por la organización.

Priorice instalaciones para todos los usuarios del equipo. Evite instaladores de tipo *User Setup* que almacenen aplicaciones en `%LocalAppData%`.

Verifique las rutas de instalación:

- `C:\Program Files`
- `C:\Program Files (x86)`

<p align="center">
  <img src="../pictures/sysprep/software/02.png" width="42%" alt="Instalación de aplicaciones">
  <img src="../pictures/sysprep/software/04.png" width="42%" alt="Configuración de software">
</p>

---

## Fase 2 · Limpieza

### 3. Servicios y caché de Windows Update

Detenga los servicios relacionados con Windows Update y elimine los archivos descargados para liberar espacio de almacenamiento.

**CMD (administrador):**

```cmd
net stop wuauserv
net stop bits
net stop cryptsvc

rd /s /q C:\Windows\SoftwareDistribution\Download
mkdir C:\Windows\SoftwareDistribution\Download
```

> **Resultado esperado:** servicios detenidos y directorio de descargas reconstruido.

### 4. Limpieza del sistema

Ejecute las siguientes operaciones para reducir archivos temporales y componentes innecesarios.

**CMD (administrador):**

```cmd
dism /Online /Cleanup-Image /StartComponentCleanup /ResetBase

cleanmgr /sageset:1
cleanmgr /sagerun:1
```

En la ventana de `sageset`, seleccione las categorías de limpieza correspondientes y confirme.

Complete la limpieza de archivos temporales:

```cmd
del /q /f /s "%TEMP%\*"
del /q /f /s "C:\Windows\Temp\*"
rd /s /q C:\$Recycle.Bin
```

> [!NOTE]
> `/ResetBase` consolida la limpieza del almacén de componentes, pero impide desinstalar las actualizaciones existentes mediante los mecanismos habituales de Windows.

---

## Fase 3 · Generalización

### 5. Verificación de paquetes AppX

Antes de ejecutar Sysprep, compruebe si existen paquetes AppX en estado `Staged`, ya que determinadas aplicaciones pueden generar conflictos durante la generalización.

**PowerShell (administrador):**

```powershell
Get-AppxPackage -AllUsers |
Where-Object {$_.PackageUserInformation -match "Staged"} |
Select-Object Name, PackageFullName
```

Verifique también los paquetes provisionados:

```powershell
Get-AppxProvisionedPackage -Online |
Select-Object DisplayName, PackageName
```

Si se identifican paquetes problemáticos, evalúe su procedencia y dependencias antes de eliminarlos.

> [!IMPORTANT]
> Los paquetes instalados y los provisionados son elementos diferentes. Eliminar una aplicación de un usuario no garantiza que deje de instalarse en los nuevos perfiles.

### 6. Generalización con Sysprep

Ejecute Sysprep para preparar la instalación para su implementación en otros equipos.

**CMD (administrador):**

```cmd
C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown
```

> **Resultado esperado:** el equipo se apaga automáticamente al finalizar la generalización.

> [!CAUTION]
> **No vuelva a iniciar Windows después de este paso.** Arranque directamente desde WinPE para continuar con la captura de la imagen.

En caso de error, consulte el registro:

`C:\Windows\System32\Sysprep\Panther\setuperr.log`

---

## Fase 4 · Captura

### 7. Captura de imagen con DISM

Arranque desde WinPE o un medio USB booteable.

Identifique las unidades disponibles mediante `diskpart` → `list volume`. Las letras pueden variar respecto a las utilizadas durante la instalación de Windows.

En este procedimiento se utiliza `C:` como partición de origen y `D:` como unidad de destino.

**CMD (WinPE):**

```cmd
mkdir D:\Scratch

dism /Capture-Image /ImageFile:D:\install.wim /CaptureDir:C:\ /Name:"Windows Personalizado Rapido" /Description:"Imagen Sysprep optimizada" /Compress:fast /ScratchDir:D:\Scratch
```

**Referencia de parámetros:**

| Parámetro | Función |
|:---:|---|
| `/Capture-Image` | Inicia la captura de la partición de origen. |
| `/ImageFile` | Define la ruta y el nombre del archivo WIM. |
| `/CaptureDir` | Especifica la partición de Windows que se capturará. |
| `/Name` | Asigna el nombre de la imagen. |
| `/Description` | Define la descripción de la imagen. |
| `/Compress:fast` | Aplica compresión rápida. |
| `/ScratchDir` | Define el directorio temporal de DISM. |

> [!IMPORTANT]
> **Tiempo de captura:** la duración depende del volumen de información, las aplicaciones instaladas y el rendimiento del almacenamiento. Espere hasta que DISM alcance el **100 %**, finalice correctamente y libere la terminal. No interrumpa el proceso ni apague el equipo.

<p align="center">
  <img src="../pictures/sysprep/07.png" width="70%" alt="Captura de imagen de Windows mediante DISM">
</p>

### 8. Verificación de la imagen

Una vez finalizada la captura, consulte los metadatos del archivo WIM para comprobar que la imagen se haya generado correctamente.

**CMD (WinPE):**

```cmd
dism /Get-WimInfo /WimFile:D:\install.wim
```

**Resultado esperado:** DISM muestra el índice, nombre y descripción definidos durante la captura.

Verifique también la existencia y el tamaño del archivo `install.wim` en la unidad de destino.

---

**Siguiente paso:** [Aplicación de imagen y secuencias de despliegue](README-03.md)

**Documento principal:** [README.md](../README.md)
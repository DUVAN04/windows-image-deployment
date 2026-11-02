# Fase 1 · Preparación

### 01. Ingresar al modo auditoría

**Entorno:** Windows OOBE

En la pantalla inicial de configuración de Windows, presione `Ctrl + Shift + F3`.

El equipo se reiniciará e ingresará al modo auditoría mediante la cuenta de administrador integrada.

Cierre la ventana de Sysprep que aparece automáticamente. Se utilizará posteriormente.

<p align="center">
  <img src="../pictures/sysprep/01.png" width="30%" alt="Inicio del modo auditoría">
  <img src="../pictures/sysprep/02.png" width="30%" alt="Proceso de ingreso al modo auditoría">
  <img src="../pictures/sysprep/03.png" width="30%" alt="Escritorio en modo auditoría">
</p>

---

### 02. Instalar aplicaciones y configurar Windows

**Entorno:** Modo auditoría

Instale las aplicaciones corporativas y aplique las configuraciones requeridas para el entorno de destino.

Verifique que las aplicaciones se instalen en las rutas correspondientes:

- `C:\Program Files`
- `C:\Program Files (x86)`

Evite instalaciones por usuario cuando el objetivo sea disponer de las aplicaciones para todos los usuarios del equipo.

<p align="center">
  <img src="../pictures/sysprep/software/02.png" width="42%" alt="Instalación de aplicaciones">
  <img src="../pictures/sysprep/software/04.png" width="42%" alt="Configuración de software">
</p>

---

# Fase 2 · Limpieza

### 03. Detener servicios de actualización

**Consola:** CMD como administrador

Detenga los servicios relacionados con Windows Update para realizar las tareas de mantenimiento.

```cmd
net stop wuauserv
net stop bits
net stop cryptsvc
```

> **Resultado esperado:** Windows confirma que los servicios se han detenido o que no se encuentran iniciados.

<p align="center">
  <img src="../pictures/sysprep/05.png" width="65%" alt="Detención de servicios de actualización">
</p>

---

### 04. Limpiar el almacén de componentes

**Consola:** CMD como administrador

Ejecute DISM para realizar la limpieza del almacén de componentes de Windows.

```cmd
dism /Online /Cleanup-Image /StartComponentCleanup /ResetBase
```

> **Resultado esperado:** la operación alcanza el 100 % y finaliza correctamente.
>
> **Consideración:** el parámetro `/ResetBase` impide desinstalar las actualizaciones existentes mediante los mecanismos habituales de desinstalación de actualizaciones.

<p align="center">
  <img src="../pictures/sysprep/06.png" width="65%" alt="Limpieza del almacén de componentes">
</p>

---

### 05. Limpiar la caché de Windows Update

**Consola:** CMD como administrador

Elimine los archivos descargados por Windows Update y reconstruya el directorio de caché.

```cmd
rd /s /q C:\Windows\SoftwareDistribution\Download
mkdir C:\Windows\SoftwareDistribution\Download
```

---

### 06. Ejecutar limpieza de disco

**Consola:** CMD como administrador

Configure y ejecute la herramienta de limpieza de disco.

```cmd
cleanmgr /sageset:1
cleanmgr /sagerun:1
```

En la ventana de configuración (`sageset`), seleccione las categorías de limpieza correspondientes y confirme la operación.

---

### 07. Eliminar archivos temporales y papelera

**Consola:** CMD como administrador

Elimine los archivos temporales de usuario y del sistema, así como el contenido de la papelera de reciclaje.

```cmd
del /q /f /s "%TEMP%\*"
del /q /f /s "C:\Windows\Temp\*"
rd /s /q C:\$Recycle.Bin
```

---

### 08. Limpiar registros de eventos

**Consola:** CMD como administrador

Ejecute el siguiente comando para limpiar los registros de eventos de Windows.

```cmd
for /F "tokens=*" %G in ('wevtutil el') do wevtutil cl "%G"
```

> [!WARNING]
> Esta operación elimina los registros de eventos existentes, incluidos aquellos que pueden ser relevantes para auditoría y diagnóstico. Ejecútela únicamente cuando exista autorización y se haya definido la política de conservación de registros.

> **Nota:** en archivos `.bat`, sustituya `%G` por `%%G`.

---

### 09. Limpiar registros anteriores de Sysprep y DISM

**Consola:** CMD como administrador

Elimine los registros de ejecuciones anteriores para facilitar el diagnóstico de los siguientes procesos.

```cmd
del /q /f "C:\Windows\System32\Sysprep\Panther\*.*"
del /q /f "C:\Windows\Logs\DISM\*.*"
```

---

# Fase 3 · Generalización

### 10. Verificar paquetes AppX

**Consola:** PowerShell como administrador

Compruebe si existen paquetes AppX en estado `Staged`, ya que determinadas aplicaciones provisionadas o actualizadas pueden generar conflictos durante Sysprep.

```powershell
Get-AppxPackage -AllUsers |
Where-Object {$_.PackageUserInformation -match "Staged"} |
Select-Object Name, PackageFullName
```

Si se identifican paquetes que deban eliminarse, evalúe su dependencia y procedencia antes de realizar la operación.

```powershell
Remove-AppxPackage -Package "NombreCompletoDelPaquete" -AllUsers
```

> [!NOTE]
> La eliminación de un paquete instalado y la eliminación de su aprovisionamiento son operaciones diferentes. Verifique también los paquetes provisionados cuando corresponda.

---

### 11. Ejecutar Sysprep

**Consola:** CMD como administrador

Ejecute Sysprep con los parámetros de generalización, experiencia inicial y apagado automático.

```cmd
C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown
```

<blockquote>
  <strong>Resultado esperado:</strong> el equipo se apaga automáticamente cuando finaliza la generalización.
</blockquote>

> [!CAUTION]
> **No vuelva a iniciar Windows después de este procedimiento.** El siguiente paso debe realizarse desde WinPE para evitar iniciar el OOBE de la instalación que se va a capturar.

En caso de error, consulte el registro:

`C:\Windows\System32\Sysprep\Panther\setuperr.log`

---

# Fase 4 · Captura

### 12. Capturar la imagen del sistema

**Entorno:** WinPE

Arranque el equipo desde WinPE o un medio USB booteable.

Antes de ejecutar DISM, identifique las unidades disponibles mediante `diskpart` y `list volume`. Las letras pueden variar respecto a las asignadas durante la instalación de Windows.

Asegúrese de que la partición de origen y la unidad de destino sean diferentes y que esta última disponga de espacio suficiente.

**Consola:** CMD en WinPE

```cmd
mkdir D:\Scratch

dism /Capture-Image /ImageFile:D:\install.wim /CaptureDir:C:\ /Name:"Windows Personalizado Rapido" /Description:"Imagen Sysprep optimizada" /Compress:fast /ScratchDir:D:\Scratch
```

#### Referencia de parámetros

| Parámetro | Descripción |
|:---:|---|
| `/Capture-Image` | Inicia la captura de la partición de origen. |
| `/ImageFile` | Define la ruta y el nombre del archivo WIM. |
| `/CaptureDir` | Especifica la partición de Windows que se capturará. |
| `/Name` | Asigna el nombre de la imagen. |
| `/Description` | Define la descripción de la imagen. |
| `/Compress:fast` | Utiliza compresión rápida para reducir el tiempo de procesamiento frente a `max`. |
| `/ScratchDir` | Define el directorio temporal utilizado por DISM. |

> [!IMPORTANT]
> **Tiempo de ejecución:** la duración de la captura depende del volumen de información, el software instalado y el rendimiento del almacenamiento. Espere hasta que DISM alcance el **100 %**, finalice correctamente y libere la terminal. No interrumpa el proceso ni apague el equipo durante su ejecución.

<p align="center">
  <img src="../pictures/sysprep/07.png" width="75%" alt="Captura de imagen de Windows mediante DISM">
</p>

---

### 13. Verificar la imagen generada

**Entorno:** WinPE

Compruebe los metadatos de la imagen capturada mediante DISM.

```cmd
dism /Get-WimInfo /WimFile:D:\install.wim
```

**Resultado esperado:** DISM muestra la información de la imagen, incluyendo el índice, nombre y descripción definidos durante la captura.

Verifique que el archivo `install.wim` exista en la unidad de destino y que la consulta finalice correctamente.

---

## Finalización

Con la captura y verificación completadas, el archivo `install.wim` queda disponible para su posterior implementación en los equipos de destino mediante el mecanismo de despliegue correspondiente.

---

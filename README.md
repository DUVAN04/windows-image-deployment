# Despliegue y Captura de Imagen Windows con Sysprep y DISM

Documentación técnica y procedimientos de ingeniería para la estandarización, preparación y captura de imágenes del sistema operativo Windows 11.

> **Nota técnica:** Este procedimiento no genera un archivo ejecutable `.iso`. El resultado final es la captura de la partición generalizada en un archivo **`.wim`**, diseñado para el aprovisionamiento masivo de infraestructura corporativa.

---

## Requisitos Críticos de Instalación en Modo Auditoria

Para garantizar que el proceso de generalización con Sysprep finalice sin errores de compilación o fallos en el empaquetado final, es obligatorio cumplir con las siguientes directrices técnicas desde el primer arranque:

1. **Ruta de Instalación Obligatoria (`C:\`):** 
   Toda aplicación corporativa debe instalarse estrictamente dentro de la unidad de sistema (`C:\Program Files` o `C:\Archivos de Programa`). 
   * **Atención con instaladores de usuario:** Herramientas como Visual Studio Code ofrecen por defecto ejecutables de tipo *User Setup* que instalan el software en rutas de perfil (`%LocalAppData%` / `AppData`). Estas instalaciones se eliminarán al generalizar el sistema y romperán la imagen. Se deben utilizar exclusivamente instaladores de sistema (*System Installer / System-wide*) o ejecutables administrativos directos.

2. **Bloqueo por Procesos en Segundo Plano (Microsoft Store):**
   Los paquetes AppX instalados o en estado depuesto (*staged*) por la Microsoft Store bloquean la ejecución de Sysprep. Es necesario detener los servicios de actualización y purgar las aplicaciones en segundo plano antes de proceder con el cierre de la imagen.

---

## Consideraciones de Hardware, Drivers y Entornos

### Implementación en Hardware Físico vs. Máquinas Virtuales

* **Entornos Físicos (Método Recomendado):** 
  Se recomienda realizar la preparación de la imagen sobre un equipo físico representativo de la infraestructura corporativa (ej. Lenovo ThinkPad). Al ejecutar la herramienta oficial *Lenovo System Update*, los controladores requeridos se instalan y quedan registrados nativamente en el *Driver Store* de Windows (`C:\Windows\System32\DriverStore`). La captura de la imagen `.wim` conservará automáticamente esa base de controladores para toda la familia de equipos compatibles, logrando un alistamiento óptimo post-formateo.

* **Máquinas Virtuales (Advertencia sobre Integración de Drivers):** 
  **No se recomienda intentar empaquetar o inyectar lotes masivos de controladores de diversos fabricantes dentro de una máquina virtual.** Este procedimiento incrementa drásticamente el peso del archivo `.wim` y no ofrece resultados viables en producción.

  Al generar la imagen en un entorno virtual, el sistema operativo queda "virgen" (sin controladores dedicados del fabricante). Al desplegarla en un equipo físico, la instalación de drivers requerirá mayor tiempo. Para optimizar este proceso, **se debe validar con anterioridad** si el fabricante dispone de soluciones de despliegue corporativo.

---

### Procedimiento Offline para Equipos Lenovo (Paquetes SCCM)

Para el caso específico de equipos Lenovo, es posible reducir el tiempo de búsqueda post-instalación utilizando sus paquetes corporativos oficiales:

1. **Validación previa:** Ingrese al portal de soporte oficial de Lenovo con el modelo exacto o número de serie del equipo.
2. **Descarga del paquete:** Acceda a la categoría **Gestión de Empresas** y descargue el paquete de controladores para despliegue (ejemplo: *SCCM Package for Windows 11 Version 25H2*, instalador `.exe`.
3. **Extracción de controladores:** Descomprima el archivo `.exe` en su estación de trabajo. El volumen descomprimido aumentará considerablemente (~3 GB a 5 GB) al exponer la estructura de archivos de controlador (`.inf`).
4. **Almacenamiento externo:** Copie la carpeta descomprimida directamente en el medio de almacenamiento externo (USB/HDD) junto al archivo `.wim` (fuera de la imagen).
5. **Inyección post-despliegue:** Una vez aplicada la imagen `.wim` e iniciado el equipo destino, ejecute la instalación directa de controladores desde la consola con privilegios de administrador mediante la herramienta nativa `PnPUtil`:

   ```cmd
   pnputil /add-driver "E:\DriversLenovo\*.inf" /subdirs /install
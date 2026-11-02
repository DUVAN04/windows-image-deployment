> [!NOTE]
> Este procedimiento **no genera una ISO**. El resultado final es un archivo **`.wim`** con el sistema ya preparado y generalizado.

## Resumen

| | |
|---|---|
| **Herramientas** | Modo Auditoría, Sysprep, DISM, PnPUtil |
| **Resultado** | Imagen `.wim` reutilizable en múltiples equipos |
| **Beneficio** | Alistar y configurar **una sola vez** lo que normalmente se hace equipo por equipo |

El Modo Auditoría permite trabajar sobre la imagen como en cualquier equipo, y todo lo que se deje listo se replica en cada despliegue. Según el proceso de cada empresa, se puede adelantar:

- Instalación de software corporativo.
- Ajustes y configuraciones de Windows.
- Políticas, accesos y personalizaciones.
- Cualquier otro paso del alistamiento habitual.

## Flujo general

```mermaid
flowchart LR
    A[Crear imagen en Modo Auditoría] --> B[Limpieza y Sysprep]
    B --> C[Captura con DISM]
    C --> D[Despliegue en equipo destino]
    D --> E{"¿Dónde se creó la imagen?"}
    E -->|Equipo físico| F["Drivers ya incluidos en la imagen"]
    E -->|Máquina virtual| G["Instalar drivers con paquete offline"]
    F --> H["Verificar actualizaciones del fabricante"]
    G --> H
```

---

## Requisitos críticos

> [!IMPORTANT]
> Estos dos puntos son los que más fallas generan al cerrar Sysprep. Léalos completos y verifíquelos **antes** de continuar.

1. **Instalar todo el software en `C:\Program Files`.**
   Evite los instaladores *User Setup* (por ejemplo, Visual Studio Code en su modo por defecto): instalan en `%LocalAppData%`, solo para el usuario actual, y pueden hacer fallar Sysprep. Use siempre el instalador *System* (para todos los usuarios).

2. **Verificar aplicaciones y procesos activos de la Microsoft Store.**
   Los paquetes AppX instalados, actualizados o en estado *staged* pueden impedir que Sysprep finalice. Deben revisarse y purgarse antes de cerrar la imagen.

---

## Drivers según el entorno de creación

**Equipo físico (recomendado).**
La imagen se prepara sobre un equipo representativo de la infraestructura (ej. Lenovo ThinkPad) y los drivers se instalan con la herramienta oficial del fabricante (ej. *Lenovo System Update*). Quedan registrados en el *Driver Store* (`C:\Windows\System32\DriverStore`) y la captura `.wim` los conserva para los equipos compatibles de la misma familia.

**Máquina virtual.**
La imagen queda "virgen", sin drivers del fabricante, por lo que al desplegarla en un equipo físico la instalación de drivers toma más tiempo. **No inyecte drivers de varios fabricantes dentro de la VM:** infla el `.wim` y no ofrece resultados viables en producción. Valide antes si el fabricante ofrece un paquete corporativo de despliegue (ver complemento Lenovo).

> [!NOTE]
> Los drivers no son un paso único. Incluso con la imagen ya desplegada, los fabricantes publican actualizaciones con frecuencia, por lo que se debe seguir verificándolas.

<br>
<br>
<br>

---

## Complemento: paquete offline de drivers Lenovo (SCCM)

**Aplica solo si la imagen se creó en una máquina virtual.** Es una solución opcional para reducir el tiempo de instalación de drivers en el equipo destino.

### 1. Descargar el paquete

En el portal de soporte de Lenovo, busque por modelo o número de serie, abra la categoría **Gestión de Empresas** y descargue el paquete que coincida con su versión de Windows (por ejemplo, *SCCM Package for Windows 11 Version 25H2*).

<table>
  <tr>
    <td align="center"><img src="pictures/packages-offline-SCCM/01.png" alt="Categoría Gestión de Empresas"><br><sub>Categoría Empresas</sub></td>
    <td align="center"><img src="pictures/packages-offline-SCCM/02.png" alt="Descarga del paquete SCCM"><br><sub>Descarga del paquete SCCM</sub></td>
  </tr>
</table>

### 2. Extraer los controladores

Ejecute el `.exe` en una estación de trabajo técnica. La carpeta resultante ocupa entre 3 y 5 GB, con todos los archivos `.inf`.

<table>
  <tr>
    <td align="center"><img src="pictures/packages-offline-SCCM/03.png" alt="Extracción del paquete"><br><sub>Extracción del instalador</sub></td>
    <td align="center"><img src="pictures/packages-offline-SCCM/04.png" alt="Estructura de archivos extraída"><br><sub>Estructura extraída</sub></td>
  </tr>
</table>

### 3. Instalar en el equipo destino

Copie la carpeta (`DriversLenovo`) a un USB o disco externo junto al `.wim`, **fuera de la imagen**. Con la imagen ya aplicada, abra **CMD como administrador** y ejecute:

```cmd
pnputil /add-driver "E:\DriversLenovo\*.inf" /subdirs /install
```

Reemplace `E:` por la letra que Windows asigne a su unidad externa. El parámetro `/subdirs` incluye todas las subcarpetas e `/install` instala los drivers en los dispositivos detectados.

<table>
  <tr>
    <td align="center"><img src="pictures/packages-offline-SCCM/05.png" alt="Ejecución de PnPUtil"><br><sub>Ejecución del comando</sub></td>
    <td align="center"><img src="pictures/packages-offline-SCCM/06.png" alt="Drivers instalados"><br><sub>Instalación finalizada</sub></td>
  </tr>
</table>

<br>
<br>
<br>

---

**Siguiente paso:** [`docs/README-02.md`](docs/README-02.md)

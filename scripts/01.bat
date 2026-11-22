@echo off
set WIM=D:\automation\install.wim

if not exist "%WIM%" (echo [ERROR] No se encuentra %WIM% & pause & exit /b 1)

:: ---------- FORMATEO DE UNIDAD (GPT/UEFI, disco 0) ----------
(
echo sel disk 0
echo clean
echo convert gpt
echo create part efi size=260
echo format quick fs=fat32 label="System"
echo assign letter=S
echo create part msr size=16
echo create part pri
echo format quick fs=ntfs label="Windows"
echo assign letter=W
echo exit
) | diskpart >nul

:: ---------- APLICACION DE IMAGEN ----------
dism /Apply-Image /ImageFile:"%WIM%" /Index:1 /ApplyDir:W:\ || (echo [ERROR] Fallo DISM & pause & exit /b 1)

:: ---------- PARAMETROS PARA SALTAR EL REQUISITO DE RED/CUENTA MICROSOFT ----------
reg load HKLM\OFF_SOFT W:\Windows\System32\config\SOFTWARE >nul
reg add "HKLM\OFF_SOFT\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f >nul
reg unload HKLM\OFF_SOFT >nul

:: ---------- ARRANQUE UEFI ----------
bcdboot W:\Windows /s S: /f UEFI /l es-ES >nul

echo.
echo LISTO. RETIRA LA USB Y REINICIA.
pause
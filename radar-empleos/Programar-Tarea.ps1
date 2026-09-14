<#
.SYNOPSIS
    Registra (o quita) una tarea programada de Windows que corre el radar de empleos.

.EXAMPLE
    .\Programar-Tarea.ps1                    # todos los dias a las 08:30
    .\Programar-Tarea.ps1 -Hora "19:00"
    .\Programar-Tarea.ps1 -Quitar
#>
param(
    [string] $Hora = '08:30',
    [string] $Nombre = 'Radar de empleos',
    [switch] $Quitar
)

$ErrorActionPreference = 'Stop'
$Raiz    = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script  = Join-Path $Raiz 'Buscar-Empleos.ps1'

if ($Quitar) {
    Unregister-ScheduledTask -TaskName $Nombre -Confirm:$false
    Write-Host "Tarea '$Nombre' eliminada." -ForegroundColor Yellow
    return
}

if (-not (Test-Path $Script)) { throw "No encuentro $Script" }

$accion = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -NoAbrir' -f $Script)

$disparador = New-ScheduledTaskTrigger -Daily -At $Hora

$opciones = New-ScheduledTaskSettingsSet -StartWhenAvailable `
    -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

Register-ScheduledTask -TaskName $Nombre -Action $accion -Trigger $disparador `
    -Settings $opciones -Description 'Busca ofertas de Data Analyst / BI y genera el reporte HTML.' `
    -Force | Out-Null

Write-Host ""
Write-Host "  Tarea registrada: '$Nombre'" -ForegroundColor Green
Write-Host "  Corre todos los dias a las $Hora (aunque la PC haya estado apagada, al prenderla)."
Write-Host "  Los reportes quedan en: $(Join-Path $Raiz 'reportes')"
Write-Host ""
Write-Host "  Para quitarla:  .\Programar-Tarea.ps1 -Quitar" -ForegroundColor Gray
Write-Host ""

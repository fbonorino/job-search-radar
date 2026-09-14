# Radar de empleos

Busca ofertas de rol, las puntúa contra tu perfil y arma un reporte ordenado por match.
Escrito en PowerShell — en Windows viene nativo; en Mac/Linux corre igual con PowerShell 7
(`pwsh`), que desde 2016 es multiplataforma y no requiere reescribir nada.

## Uso

**Windows** (PowerShell nativo):
```powershell
cd "C:\Users\TuUsuario\Desktop\CV\radar-empleos"
.\Buscar-Empleos.ps1
```

**Mac/Linux** (instalar PowerShell una vez, después corre igual):
```bash
brew install powershell      # una sola vez
cd radar-empleos
pwsh -File ./Buscar-Empleos.ps1
```

Al terminar abre el reporte HTML en el navegador. Opciones:

| Parámetro | Para qué |
|---|---|
| `-SinDetalle` | No baja las descripciones completas. Corre en ~1 min en vez de ~2, pero puntúa peor. |
| `-PuntajeMinimo 55` | Solo los matches fuertes. |
| `-NoAbrir` | No abre el navegador (lo usa la tarea programada). |

Para que corra solo todos los días:

**Windows** (Programador de Tareas):
```powershell
.\Programar-Tarea.ps1 -Hora "08:30"
```

**Mac** (`launchd`, el equivalente nativo — `Programar-Tarea.ps1` no funciona acá):
```bash
./Programar-Tarea-Mac.sh -h 08:30
./Programar-Tarea-Mac.sh -q      # para quitarla
```
Nota: a diferencia del Programador de Tareas de Windows, `launchd` no despierta la Mac si está
dormida — corre solo si la Mac está prendida y con sesión iniciada a la hora programada.

## Qué mira

| Fuente | Cobertura | Cómo |
|---|---|---|
| **LinkedIn** | Argentina | Endpoint público de invitado, sin login |
| **Computrabajo** | Argentina | HTML de la búsqueda |
| **Indeed** | Argentina | HTML de la búsqueda — **desactivado, confirmado 403 (anti-bot)** |
| **Remotive / Jobicy / Himalayas / RemoteOK / Arbeitnow** | Remoto global | APIs públicas en JSON |

**Bumeran y Zonajobs quedaron afuera**: son aplicaciones JavaScript que no traen ningún dato
en el HTML, y su API interna no está en ninguna ruta pública conocida (probé varias, todas 404).
No se pueden scrapear sin un navegador real. Para esas dos, usá la búsqueda asistida por Chrome.

**Indeed quedó desactivado** (`perfil.json` → `busquedas.indeed.activo: false`): probado en vivo,
devuelve 403 Forbidden en todas las peticiones por protección anti-bot, igual que Bumeran/Zonajobs.
El código (`Get-Indeed`) queda en el script por si en el futuro aparece otra vía de acceso; mientras
tanto, para esa fuente conviene usar la búsqueda asistida por Chrome.

## Cómo puntúa

El puntaje va de 0 a 100 y **sirve para ordenar, no para decidir**. Se calcula así:

1. **El título manda.** Cada habilidad de tu CV que aparece en el título suma su peso completo.
2. **El cuerpo aporta poco.** Las coincidencias en la descripción están topeadas en 18 puntos
   (`topeCuerpo`). Sin ese tope, una fuente que devuelve la descripción entera le gana siempre
   a una que solo da el título, aunque la oferta sea peor.
3. **Rol núcleo.** Si el título no es un puesto de BI/Data, resta 20. Esto es lo que evita que
   un "Sales Engineer" puntúe alto solo porque su descripción menciona SQL y Excel.
4. **Geografía.** Se evalúa **solo sobre la ubicación**. Si dice Argentina/LATAM/Worldwide suma 8;
   si dice un país donde no podés trabajar, resta 60 y la oferta desaparece.
5. **Dominio** afín a tu experiencia (fintech, pagos, transporte, banca): +3.
6. **Seniority** y antigüedad de la publicación ajustan al final.

Todo eso vive en `perfil.json` — **editá ese archivo, no el script**.

## Ajustes que probablemente quieras hacer

- **Muy pocos resultados** → bajá `puntajeMinimo` (está en 35).
- **Aparece ruido** → subí `puntajeMinimo` a 50, o agregá el término molesto a `exclusiones`.
- **Querés incluir un país** (ej. te interesa España) → sacalo de `geo.noElegibles`.
- **Cambiaste de foco** (ej. Data Engineer) → ajustá pesos en `habilidades` y sumá el rol a `rolesNucleo.terminos`.

## Archivos

```
radar-empleos/
├─ Buscar-Empleos.ps1        el script
├─ Programar-Tarea.ps1       registra/quita la tarea diaria (Windows)
├─ Programar-Tarea-Mac.sh    registra/quita la tarea diaria (Mac, launchd)
├─ perfil.json               tu perfil y todos los pesos  <- editá esto
├─ datos/vistos.json         qué ofertas ya viste (para marcar las NUEVAS)
└─ reportes/                 un HTML + un CSV por corrida
```

Si borrás `datos/vistos.json`, la próxima corrida marca todo como nuevo.

## Límites honestos

- **El scraping de HTML se rompe** cuando LinkedIn o Computrabajo cambian su maquetado.
  Si una fuente empieza a devolver 0 ofertas, es eso: hay que reajustar la expresión regular.
- **LinkedIn puede cortarte por IP** si lo corrés muchas veces seguidas. Una vez por día está bien.
- **El puntaje es una heurística**, no una lectura de la oferta. Un 60 bien ubicado puede
  convenirte más que un 90.

# Radar de empleos

Herramienta personal para buscar trabajo: scrapea ofertas de varias fuentes, las
puntúa contra tu perfil y arma una cola de postulación. El CV va en esta misma carpeta.

## Qué hay acá

| Archivo | Qué es |
|---|---|
| `radar-empleos/Buscar-Empleos.ps1` | Scrapea las fuentes y puntúa ofertas contra el perfil |
| `radar-empleos/perfil.json` | Pesos, filtros geográficos y roles núcleo del radar. Editá esto, no el script. |
| `radar-empleos/datos-postulacion.json` | Tus datos de screening. Leelo antes de completar cualquier formulario. |
| `radar-empleos/cola-postulacion.md` | Ofertas por encima del umbral de match, con link y estado |
| `radar-empleos/reportes/` | Un HTML + un CSV por corrida |

Para refrescar el ranking: `.\radar-empleos\Buscar-Empleos.ps1`

## Configuración pendiente

Este repo arrancó como fork de una configuración de otra persona y quedó limpio de
sus datos. Antes de usarlo:

1. Completar `radar-empleos/perfil.json`: rol objetivo, habilidades y pesos, geografía
   elegible/no elegible, exclusiones.
2. Completar `radar-empleos/datos-postulacion.json`: datos personales, pretensión
   salarial, disponibilidad, modalidad aceptada, años por tecnología. **No inventar
   ningún valor** — si falta un dato, preguntar antes de completarlo en un formulario.
3. Poner el CV actualizado en esta carpeta.
4. Si vas a usar Playwright MCP para asistir con las postulaciones, la primera vez
   hay que loguearse a mano en cada portal para que la sesión quede guardada. **No
   commitear nunca el perfil de navegador ni logs de sesión al repo** — van al
   `.gitignore`.

## Reglas generales al completar formularios (ajustar a gusto)

1. **Mostrar la primera antes de enviar.** Enviar una postulación no se deshace.
   Mostrar el formulario completo de la primera oferta para validar el tono, y
   recién después seguir con las demás.
2. **No inventar.** Si un campo pide un dato que no está en `datos-postulacion.json`,
   preguntar. No completar a ojo.
3. **Ir despacio en LinkedIn** si se automatiza: va contra sus términos y hay riesgo
   de restricción de cuenta. Espaciar las postulaciones, no dispararlas en ráfaga.
4. **Actualizar `cola-postulacion.md`** con `ENVIADA` o `DESCARTADA` a medida que se avanza.
5. **Leer la descripción completa antes de postular, no solo el título.** El puntaje
   del radar mira sobre todo el título; el cuerpo puede contradecirlo.
6. **Nunca postular dos veces a la misma oferta.** Antes de enviar cualquier
   postulación (asistida o no), revisar el estado de esa URL en `cola-postulacion.md`.
   Si ya dice `ENVIADA`, no reenviar bajo ninguna circunstancia — avisar y preguntar
   en vez de asumir que hay que volver a mandarla. `PENDIENTE` no significa que se
   envió nada: es solo el estado inicial de las ofertas que superan el umbral de
   auto-envío (`puntajeAutoEnvio` en `perfil.json`), esperando que se postule.

## Trampas conocidas de los formularios (genéricas)

- Los parsers de CV suelen inventar años de experiencia en herramientas que no
  coinciden con la realidad. Verificar siempre contra tus propios datos.
- Workday suele mezclar campos (por ejemplo, meter el título del puesto en el campo
  Calle) y partir apellidos compuestos de forma rara.
- El teléfono con código de país a veces se rechaza si el `+` va pegado al número
  cuando el formulario espera el código de país en un campo aparte.
- Una URL de LinkedIn con caracteres especiales (tildes, ñ) a veces se rechaza:
  usar la versión URL-encoded.
- Workday crea una cuenta por empresa (tenant), no una cuenta global.
- Revisar el tope de caracteres de cada portal antes de pegar texto largo — algunos
  formularios fallan en silencio si te pasás.

# certificados_calibracion

Flutter app for BTMC: generates biomedical equipment calibration certificates and
keeps a per-client equipment inventory. Package id `co.btmc.certificados`.

## Team

Gabriel and Santiago are field technicians; Sebastián owns the Firebase project.
See memory `btmc-team` for emails/roles.

## Cloud sync architecture (lib/data/inventario_sync.dart + inventario_data.dart)

Firestore (`btmc-certificados` project, default database) + Anonymous Auth give
offline-first, near-real-time inventory sync across technicians' phones. No
manual login screen — each device signs in anonymously once
(`InventarioSync._asegurarSesion`).

**Schema:** `clientes/{clienteId}/equipos/{equipoId}`.

**`clienteId`** = `InventarioSync.slug(nombreCliente)` — uppercased, tildes
stripped, non-alphanumerics collapsed to `_`. Normalizing this way is
deliberate: two technicians almost never type a client name identically
("Clínica X" vs "CLINICA X"), and if the cloud id depended on that spelling
they'd silently write to two different documents. Do not weaken this
normalization.

**`equipoId`** = `InventarioSync.docId(equipo)` = the equipo's
**`clave_nube`** field (since 2026-09-29), fixed ONCE and never recomputed:
set by `InventarioData.fusionarConExistentes` on import (inherited from the
matched existing equipo, else `claveEquipo`), by `agregarEquipo`, by
`_asegurarIds` for legacy data, and from `doc.id` for every equipo read from
Firestore (`_equipoDeDoc`). Before this, every write recomputed
`claveEquipo(equipo)` from content — editing serie/ubicación or reimporting
an Excel with an inserted row wrote a NEW doc and left the old one:
duplicated equipos for everyone. Never address an equipo doc with
`claveEquipo` directly; always `docId`. Matching (`indexPorIdOCascada`,
`_mismoEquipo`) tries `clave_nube` before the local `id`, because the cloud
`id` field is last-writer-wins and can differ from an old solicitud's.

`claveEquipo(equipo)` (legacy fallback / initial value) — derived from the
equipo's own content (nombre+marca+modelo+serie+inventario+ubicacion,
normalized) plus its `orden` (row position in the imported Excel), NOT from
the local per-device random `id` field. This is the single most important
invariant in this codebase: `InventarioData._generarId()` produces a
different id on every device for the same physical equipment (it's seeded
from the device clock), so if that random id were used as the Firestore doc
key, two technicians importing the *same* Excel on two phones would create
two separate copies of the whole inventory in the cloud instead of merging.
The local `id` field still exists and is used for all *local* UI matching
(`indexPorIdOCascada`) — it is just never used to address a Firestore
document.

**Two different sync entry points, on purpose:**
- `InventarioData.cargarCliente` (reopening an already-known local client) →
  `InventarioSync.attachCliente`: seeds the cloud only if it's currently
  empty for that client, otherwise just attaches a listener and lets the
  cloud version win. Safe because the user isn't asserting new structure
  here.
- `InventarioData.guardarNuevoInventario` (importing/reimporting an Excel) →
  `InventarioSync.sincronizarEstructura`: ALWAYS batch-merges the full
  imported list into the cloud, regardless of what's already there. This
  must stay unconditional — making it conditional (skip if cloud
  non-empty) was a real shipped bug on 2026-09-16: reimporting an Excel
  after *any* stray cloud write (even a single test doc) made the app show
  only that stray doc instead of the freshly imported list.
  `_soloEstructura` deliberately omits empty `certificado`/`fecha`/
  `observaciones`/`fuera_de_servicio`/`fuera_de_servicio_por` from this
  merge so a blank reimport can never blow away a calibration another
  technician already recorded.

**`fuera_de_servicio_por`:** set automatically from `TecnicoProfile.obtenerNombre()`
(the device's own signed-in technician name, see `lib/data/tecnico_profile.dart`)
when a technician flips "Fuera de servicio" on — never a manually-typed/picked
name, so it can't be misattributed. `observaciones` is required (non-empty) to
flip the switch on (`_CrearEditarEquipoDialog` in `inventario_page.dart`). The
authorship string is kept as-is on later edits while the equipo stays out of
service (only re-stamped if it was previously missing), and cleared when the
equipo is put back in service.

**Timestamp leak gotcha:** documents read back from Firestore contain a
`Timestamp` object (`actualizado_en`, from `FieldValue.serverTimestamp()`).
`InventarioSync._paraApp` converts it to an ISO8601 string before it reaches
`InventarioData` — without this, `JsonEncoder` (used both for the local
per-client JSON cache and for solicitud files) throws "Converting object to
an encodable object failed: Instance of 'Timestamp'" the next time *anything*
gets saved after a remote sync event. If new Firestore-typed fields are ever
added to the equipo map, extend `_paraApp` accordingly.

**Listener guards** (`_attachListener`): an EMPTY snapshot from cache is
ignored (it means "nothing cached", not "no equipos" — applying it wiped the
local inventory), and metadata-only snapshots after the first are ignored
(no list replace / JSON rewrite).

**Sync status badge:** `InventarioSync.estadoNotifier`. The listener must use
`snapshots(includeMetadataChanges: true)` — without it, a snapshot that
arrives from cache and is then confirmed by the server with identical data
never fires a second event (Firestore only notifies on data changes by
default), so the badge gets stuck on "sin_conexion" forever even though sync
actually succeeded.

**Discovering a client without reimporting the Excel** (`lib/pages/buscar_cliente_nube_page.dart`,
`InventarioSync.listarClientesNube`/`descargarEquipos`, `InventarioData.cargarClienteDesdeNube`):
a technician who never imported a given client's Excel can browse/search every
`clientes/{clienteId}` doc that ANY technician has ever pushed and pull it down.
`cargarClienteDesdeNube` deliberately does not reimplement the load path — it
downloads the equipos, writes the exact same local JSON shape `_guardar()`
writes, then calls the existing `cargarCliente()`, so the downloaded client
ends up byte-for-byte in the same state (active client, listener attached via
`attachCliente`) as one already known to the device. `listarClientesNube`
fetches the whole `clientes` collection and filters client-side by name
substring rather than a Firestore prefix query — simpler and correct for this
company's client count (tens, not thousands); revisit if that ever changes.

**Solicitudes en la nube** (`lib/data/solicitudes_sync.dart`, requires the
Firebase project on the **Blaze** plan — Cloud Storage has no Spark/free tier
since 2026-02-03): mirrors the equipos pattern exactly. `subirSolicitud`
runs at the end of `NuevaSolicitudPage._guardarSolicitud` (unawaited, same
fire-and-forget-after-local-save discipline as `InventarioSync.upsertEquipo`)
and writes to `clientes/{clienteId}/solicitudes/{claveEquipo}` in Firestore +
`clientes/{clienteId}/solicitudes/{claveEquipo}/` in Storage for the photos —
**always the content-derived `InventarioSync.claveEquipo`, never a device's
local random `id`**, for the same reason equipos use it: two technicians'
devices must compute the same key for the same physical equipo. Each upload
wipes the whole Storage folder first and re-uploads every photo in `fotos`,
matching how the local ZIP is always rebuilt from scratch rather than
diffed (see the `fotos` note above) — so cloud and local never disagree
about which photos exist.

**Subidas que fallan no se pierden:** `subirSolicitud(archivoJson:)` deja
un marcador en `BTMC_SYNC/solicitudes/sin_subir_nube/<json basename>`
(contenido = token del guardado) que solo se borra si la subida termina
bien y el token sigue siendo el suyo — así una subida vieja que termina
tarde no borra el marcador de un guardado más nuevo. `reintentarPendientes`
sube lo marcado al abrir/volver a la app, al volver la red
(`connectivity_plus` en `MainNavigationPage`), cada 5 min mientras haya
pendientes (señal débil no dispara cambio de red) y tras cada subida exitosa (busca
el JSON en pendientes/ y enviadas/; si no existe, borra el marcador). Todas
las subidas pasan por una sola cola (`_enCola`) para que dos versiones de
la misma solicitud nunca mezclen fotos en Storage. `SolicitudesPage` marca
"Sin subir a la nube" con `pendientesNube`.

**Plantillas:** `PlantillasInitializer` copia los ~34 MB de assets a disco
solo cuando cambia el build (marcador `BTMC_PLANTILLAS/.build_copiado`);
en debug copia siempre. Fotos: `pickImage` con lado mayor 2048 px.

`SolicitudesPage` lists pendientes/ AND enviadas/ (since 2026-09-30 — before,
enviadas were hidden and "Subir certificados" made solicitudes vanish from
the app), with filter chips Todas / Por subir / Enviadas / Otros técnicos.
The pending badge (`contadorNotifier`) counts only pendientes/. Editing an
enviada saves it into pendientes/ and deletes the enviadas/ JSON+ZIP+xlsx.
It also shows local solicitudes (as before) plus, for the active
client, cloud solicitudes from OTHER technicians (`listarResumenNube`,
deduped against local files by `claveEquipo` so a solicitud this device
already has never appears twice, possibly with unsynced edits shadowed by a
stale cloud copy). Tapping a cloud-only entry calls
`SolicitudesSync.descargarComoArchivoLocal`, which downloads the doc + every
photo and writes them to `SolicitudesStorage.pendientesDir()` in the EXACT
same JSON+ZIP shape a local save produces, then opens it through the
ordinary `NuevaSolicitudPage(archivoJson: ...)` path — there is no separate
"cloud view mode" in that page; once downloaded, a cloud solicitud is
indistinguishable from a local one, including that saving it again re-runs
`subirSolicitud` and re-uploads.

**EMP (Error Máximo Permitido) y "no pasa calibración"** (`lib/data/emp_referencia.dart`,
`NuevaSolicitudPage._revisarTolerancia`): un punto de medición puede traer un
EMP propio (`"emp"` en su entrada del JSON de la plantilla) que sobrescribe
la tabla compartida `assets/plantillas/emp_referencia.json` — una tabla
`{"<título de sección>": [{"nominal": N, "emp": E}, …]}` que define el EMP
UNA vez por variable (ej. "TEMPERATURA AMBIENTE") en vez de repetirlo en
cada una de las ~176 plantillas que la usan. Ninguna plantilla trae EMP
todavía — se llena punto por punto con Sebastián, o por variable en la
tabla compartida cuando aplica a varios equipos por igual.

Cómo se compara: si el punto tiene `celda_lectura_2` (dos lecturas: equipo +
patrón), el error es `|equipo - patrón|`; si tiene una sola lectura, es
`|lectura - nominal|`. El chequeo corre al perder foco un campo de medición
(`FocusNode` por controller, ver `_medicionFocusNodes`/`_medicionFocusNodes2`
en `nueva_solicitud_page.dart`) — NO al guardar, para que el técnico se
entere en el momento. Si supera el EMP, un diálogo le pide confirmar que el
dato es correcto; solo si confirma, ese punto entra a `_puntosFallidos` y al
guardar el equipo queda con `no_pasa_calibracion: true` +
`no_pasa_calibracion_detalle` (qué punto(s) fallaron, texto auto-generado) +
`no_pasa_calibracion_por` (técnico, vía `TecnicoProfile`, mismo patrón que
`fuera_de_servicio_por`). Los 3 campos se envían SIEMPRE (incluso
false/vacío) para que volver a guardar una solicitud que ya pasa limpie una
marca vieja — ver la nota de `fuera_de_servicio_por` arriba sobre el mismo
criterio.

Al REABRIR una solicitud guardada (`_cargarSolicitud`), los valores ya
guardados se re-evalúan contra el EMP en silencio (`_cargaCompleta == false`
todavía) — no vuelve a preguntar, porque ya se confirmó la vez que se
guardó; el diálogo interactivo solo dispara para ediciones en vivo después
de que la carga termina.

**Búsquedas sin tildes** (`TextUtils.quitarTildes`, `lib/utils/text_utils.dart`):
todo buscador de la app (inventario, solicitudes, clientes en la nube,
autocomplete de plantillas) pasa tanto el texto escrito como el campo
comparado por `TextUtils.quitarTildes(...).toLowerCase()` antes de
`contains` — así buscar "camara" encuentra "cámara". Es la misma tabla de
tildes que ya usaba `InventarioSync` internamente para `slug`/`claveEquipo`
(movida acá para no duplicarla); un buscador nuevo debe usar esta función,
nunca comparar con `.toLowerCase()` solo.

**Decimales con coma:** los técnicos escriben mediciones con coma decimal
("2,5"), no punto — `NuevaSolicitudPage._revisarTolerancia` ya lo maneja
(`texto.replaceAll(',', '.')` antes de `double.tryParse`). Cualquier otro
parseo numérico de un campo de medición debe hacer lo mismo.

**Security rules** (`firestore.rules`): `allow read, write: if request.auth
!= null` at both the `clientes/{clienteId}` and `equipos/{equipoId}` level.
No per-technician restriction — intentional, everyone on the team works the
same clients. Deploy with `firebase deploy --only firestore:rules --project
btmc-certificados`.

## "Nueva Solicitud" flow (lib/pages/nueva_solicitud_page.dart)

There is no standalone "Nueva" tab anymore (removed 2026-09-16) and no
equipo-search inside this page — `InventarioPage` already has its own
search/filter UI, so a second one here was redundant. The only ways into
`NuevaSolicitudPage` are:
- `InventarioPage`: tap the "Crear solicitud" icon (`Icons.add_task`) on an
  equipo card → `NuevaSolicitudPage(equipoInicial: equipo)`. Hidden for
  equipos already calibrated or `fuera_de_servicio`.
- `SolicitudesPage`: tap an existing solicitud to edit it →
  `NuevaSolicitudPage(archivoJson: file)` (unchanged).

The constructor asserts one of `equipoInicial`/`archivoJson` is always
given — `_inicializar()` calls `_seleccionarEquipo(widget.equipoInicial!)`
directly when there's no `archivoJson`, skipping the old search-and-pick
step entirely. After a successful save, the page pops back to whichever
screen pushed it (no more "clear the form and stay" — that only made sense
when you could pick a *different* equipo without leaving the page).

**Mediciones are paginated one section at a time** (`_seccionMedicionActual`
+ "Anterior"/"Siguiente sección" in `_buildMediciones`), not one long flat
scroll of every section's fields. Moving between sections is deliberately
never blocked by empty fields — some points don't apply on a given visit,
and gating navigation on them would stop a technician mid-job for no real
reason. `_validar()` on save likewise never checks medicionControllers.

**Fotos (`fotos: List<File>`)** are the single source of truth for "what
the final ZIP should contain" — both newly-taken photos and, since
2026-09-24, existing ones extracted from the solicitud's ZIP on open
(`_cargarFotosExistentes`, reading from `archivo.parent` so it works for
solicitudes already moved to `enviadas/` too). Tap a thumbnail to view it
full-screen with pinch-zoom (`_verFotoCompleta`) — added so a technician can
read a nameplate/serial in an existing photo without retaking it.
`_guardar()` always rebuilds the ZIP from the current `fotos` list; it used
to special-case "no new photos → keep old ZIP untouched" when fotos hadn't
been loaded, which silently dropped every prior photo the moment exactly
one new one was added (the ZIP got created from `fotos` alone). Do not
reintroduce that branch. `_validar()` requires `fotos` non-empty
unconditionally for the same reason — the old `_fotosZipExistente`-based
exception no longer makes sense now that existing photos are always loaded.

## Certificados e inventario en Excel (lib/data/xlsx_plantilla.dart, certificado_excel.dart, inventario_excel.dart)

**Certificado:** al guardar una solicitud se genera `<mismo nombre>.xlsx`
junto al JSON en `pendientes/`: copia de la plantilla del equipo llena con
la solicitud. Compartir solicitudes (Inicio) manda ese .xlsx + el ZIP de
fotos, ya no el JSON (el .xlsx se regenera ahí desde el JSON, así también
lo tienen las solicitudes bajadas de la nube). El JSON sigue siendo la
fuente de verdad para editar/sincronizar.

**Nunca usar el paquete `excel` para escribir en una plantilla**: al
guardar reconstruye el libro y borra logo, firma, gráficos, fondo y
configuración de impresión. `XlsxPlantilla` edita el XML de las celdas
dentro del ZIP y copia todo lo demás byte a byte. Además: expande
fórmulas compartidas cuya celda maestra se pisa, borra los valores en
caché de todas las fórmulas + `fullCalcOnLoad` (si no, un visor que no
calcula mostraría el cliente/equipo de ejemplo de la plantilla) y elimina
`calcChain.xml` (queda desactualizado → Excel dice "archivo dañado").

**Dónde escribe `CertificadoExcel`:** mediciones en la hoja `MEDIDA`
(verificado: es la hoja de las `celda_lectura` en todas las plantillas con
.json); equipo/cliente/certificado/fechas/técnico en `INFORMACIÓN`,
ubicando las celdas por etiqueta ("Marca", "Solicitante:"...) y no por
posición fija, porque las plantillas no comparten disposición. Puntos
vacíos NO se escriben (la celda queda como en la plantilla). Estado
físico, lugar y temperatura/humedad ambiente no los captura la app: quedan
los de la plantilla.

`test/certificado_excel_test.dart` llena TODAS las plantillas con .json y
deja el resultado en `build/test_certificados/` para abrirlo en Excel —
correrlo al agregar o cambiar plantillas.

**Inventario:** "Exportar inventario" genera `INVENTARIO_<cliente>.xlsx`
en el MISMO formato que importa `InventarioPage._cargarExcel` (A–H
equipo, K–O fila 2 cliente) + Observaciones/Estado en I–J, así se puede
reimportar tal cual.

**Excel en la nube** (`lib/data/excel_nube.dart`): al guardar una
solicitud, el .xlsx se sube DENTRO de `SolicitudesSync._subir` (mismo
marcador/reintento que datos+fotos; si el Excel no se puede generar no se
reintenta, es fallo local) a
`certificados/{clienteId}/{claveEquipo}/<CERT> - <EQUIPO> - <SERIE>.xlsx` en
Storage; la carpeta usa `claveEquipo` (no el id local) por la misma razón
que las fotos, y se vacía antes de subir para no dejar el Excel con un
número de certificado viejo. Desde v1.1.0+7 NO hay botón "Subir
certificados a la nube": subía solo el Excel (las fotos no) y movía todo a
`enviadas/`, de donde no se podía compartir a Drive — así se perdieron en
la nube las fotos de solicitudes cuya subida automática había fallado. En
su lugar Inicio muestra un aviso con `SolicitudesSync.pendientesNube`
("N sin subir · Reintentar") solo si hay marcadores. "Compartir
solicitudes" pregunta si incluir enviadas de hoy+ayer o de 7 días (por
fecha del JSON) además de las pendientes. "Subir inventario" sube
`inventarios/{clienteId}/INVENTARIO <CLIENTE>.xlsx`. Compartir por
Drive/WhatsApp sigue disponible como botón secundario. La oficina descarga
desde Firebase console → Storage.

## Releases

**Publicar SIEMPRE con `tool/release.ps1 -Notas "..."`** (exige git limpio):
sube el build del pubspec, compila con `--dart-define=PUBLICAR_VERSION=true`,
distribuye al grupo `tecnicos` y hace commit + tag `v<version>+<build>`.

**Control de versión** (`lib/data/version_app.dart`): al abrir/volver a la
app se compara el build con `config/app.version_minima` en Firestore; si es
menor, diálogo bloqueante "Actualiza desde Firebase App Tester". Solo un
build compilado con `PUBLICAR_VERSION=true` sube ese número (las reglas solo
permiten subirlo) — así un APK de prueba compilado a mano nunca bloquea a
los técnicos antes de que tengan cómo actualizar. Sin señal nunca bloquea.
La versión instalada se ve al pie de Inicio.

Distributed via Firebase App Distribution, not manual file transfer — see
memory `btmc-certificados-firebase` for the exact command and tester group.
Always rebuild AND redistribute after touching the sync files above; a
version mismatch between phones is indistinguishable from a sync bug from the
user's side (see memory `btmc-release-process`).

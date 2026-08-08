# Migración a Neon — Inventario Distribuido de Accesorios para Mascotas

Reconstrucción completa de las **4 bases de datos** (Central + 3 sucursales)
del proyecto original de SQL Server, traducidas a PostgreSQL para correr en
**Neon**.

---

## 1. Qué se reconstruyó (ingeniería inversa)

El proyecto original no traía el script de creación de las tablas base:
sólo los scripts de *modificación* (`10_Esquema_MultiSucursal.sql` y
compañía). El resto del modelo se dedujo leyendo cada consulta del código
PHP —los `SELECT`, los `JOIN`, los `INSERT` de los procedimientos y las
columnas que las vistas `.php` leen del arreglo de resultados.

### Las 11 tablas

| Tabla | Para qué | Cómo se dedujo |
|---|---|---|
| `Sucursales` | Las 4 sedes. `EsCentral` marca la que surte | Usada en los procedimientos y en `SolicitudRepo` |
| `Categorias` | Alimento, juguetes, collares… | `ProductoRepo::categorias()` |
| `Proveedores` | De quién llega la mercancía | `ProductoRepo::proveedores()` |
| `Productos` | Catálogo maestro | `ProductoRepo::crear()` / `actualizar()` |
| `Empleados` | Personal **y** usuarios del sistema | `Auth::intentarLogin()` + `01_Ajustes_Usuarios.sql` |
| `InventarioSucursal` | Stock por (sucursal, producto) | `10_Esquema_MultiSucursal.sql` |
| `SolicitudesStock` | Requisiciones sucursal ↔ Central | `10_Esquema_MultiSucursal.sql` |
| `Movimientos` | Bitácora de todo lo que mueve stock | `INSERT` de los 6 procedimientos |
| `Ventas` | Cabecera del punto de venta | `usp_RegistrarVenta` + `VentaRepo` |
| `DetalleVenta` | Renglones de la venta | `usp_RegistrarVenta` + `VentaRepo::ultimas()` |
| `Transferencias` | El viaje físico Central → sucursal | `usp_OfertarSolicitud`, `usp_ResponderSolicitud` |

Más **2 vistas** (`vw_StockPorSucursal`, `vw_StockGlobal`), **12 funciones**
y **1 trigger**.

### Lo que se dejó fuera a propósito

- **`dbo.Inventario`** (la tabla vieja). Era el objeto defectuoso: su llave
  primaria era sólo `ProductoID`, así que las cuatro sedes escribían la
  misma fila y en cada sincronización el stock de tres se perdía. Todo el
  script 10 existía para reemplazarla por `InventarioSucursal`, con llave
  `(SucursalID, ProductoID)`. Reconstruirla en Neon sería revivir el bug.
- **Las columnas `rowguid`** y los scripts `11_Replicacion_Merge.sql` y
  `12_Permisos_Aplicacion.sql`. Eran infraestructura de la replicación de
  mezcla y del modelo de logins de SQL Server; en Neon no aplican.

---

## 2. Cómo cargarlo en Neon

### Paso 1 — Crear las 4 bases

En la consola de Neon → tu proyecto → **Databases** → *New Database*, con
estos nombres exactos (en minúsculas; Postgres complica los nombres con
mayúsculas):

```
bd_central
bd_monterrey
bd_puebla
bd_queretaro
```

### Paso 2 — Correr los scripts

En el **SQL Editor** de Neon, selecciona la base arriba a la derecha y pega
cada archivo **en este orden**, esperando a que termine cada uno:

| Orden | Archivo | ¿Dónde? |
|---|---|---|
| 1 | `01_esquema.sql` | En las 4 bases |
| 2 | `02_funciones_y_trigger.sql` | En las 4 bases |
| 3 | `03_catalogo_base.sql` | En las 4 bases |
| 4 | `04_inventario_inicial.sql` | En las 4 bases |
| 5 | `05_datos_demo.sql` *(opcional)* | En las 4 bases |
| 6 | `06_verificacion.sql` | Donde quieras revisar |

**Los archivos son idénticos para las cuatro bases.** No hay que cambiar
ninguna línea antes de correrlos — a diferencia del proyecto de SQL Server,
donde había que editar `USE BD_x` y `@SucursalLocal` en cada base.

> Si prefieres la línea de comandos:
> `psql "postgresql://usuario:password@host/bd_central?sslmode=require" -f 01_esquema.sql`

### Paso 3 — Conectar la aplicación

En `proyecto_web/config.php`, rellena las 4 constantes de arriba con lo que
te da Neon en **Connection Details**:

```php
define('NEON_HOST',     'ep-lo-que-sea-12345678.us-east-2.aws.neon.tech');
define('NEON_USUARIO',  'neondb_owner');
define('NEON_PASSWORD', 'tu_password');
```

#### Si sale «Endpoint ID is not specified»

```
SQLSTATE[08006] ERROR: Endpoint ID is not specified. Either please upgrade
the postgres client library (libpq) for SNI support or pass the endpoint ID
(first part of the domain name) as a parameter: '?options=endpoint%3D<id>'
```

**Ya está resuelto en el código** — se documenta por si te topas con él desde
otra herramienta.

Neon aloja muchos endpoints tras una misma IP y decide a cuál conectarte por
**SNI** (el nombre de servidor que viaja en el saludo TLS). La `libpq` que
trae XAMPP es anterior a ese soporte, así que no manda el nombre y el
servidor no sabe a qué base ir. El rodeo que documenta Neon es pasar el
endpoint explícito:

```
options=endpoint=ep-quiet-heart-axxjk1qg
```

`lib/Database.php` lo arma solo: toma la primera etiqueta del host y le quita
el sufijo `-pooler`. Se deriva del host en vez de configurarse aparte para que
no puedan quedar desincronizados al cambiar de endpoint.

### Usuarios

Contraseña de los cuatro: **`12345678`**

| Sucursal | Usuario |
|---|---|
| Central | `central` |
| Monterrey | `monterrey` |
| Puebla | `puebla` |
| Querétaro | `queretaro` |

---

## Estado: verificado contra Neon

Los scripts se ejecutaron en el proyecto **crimson-base-27823750**
(PostgreSQL 18.4) y quedaron instalados en las 4 bases: 11 tablas, 2 vistas,
12 funciones y el trigger en cada una, con 30 productos, 4 usuarios y 120
filas de inventario idénticas.

Después se probó el sistema completo por la interfaz web (75 comprobaciones
automatizadas más un recorrido manual):

- Login de los 4 usuarios y rechazo de contraseña incorrecta.
- Guardas de rol: Central no entra a `ventas.php` / `alertas.php`, las
  sucursales no entran a `entrada_mercancia.php` / `asignar_stock.php` /
  `producto_form.php` (403 en los seis casos). Sin sesión, redirección a
  `login.php`. POST sin token CSRF: 400.
- **Ciclo completo**: Monterrey vendió 2 piezas (10 → 4), el trigger levantó
  sola la solicitud automática, Central envió 10 (150 → 140) y Monterrey
  aceptó (4 → 14). La transferencia quedó `Completada`.
- Rechazo con reintegro, y el doble reintegro bloqueado.
- Asignación directa, entrada de mercancía, barrido de alertas y ajuste de
  umbrales.
- Las validaciones devuelven su mensaje redactado en español, con acentos:
  *"Stock insuficiente en esta sucursal para completar la venta."*

Los datos de esas pruebas se borraron después: las 4 bases quedaron en el
estado que deja `05_datos_demo.sql` (Central 4500 piezas; Monterrey 405,
Puebla 425, Querétaro 405; `Ventas`, `SolicitudesStock` y `Transferencias`
en cero).

---

## 3. La decisión importante: las 4 bases y `MODO_DEMO`

Hay que ser claro con esto porque cambia cómo se opera el sistema.

**El problema:** en SQL Server, lo que hacía que las cuatro bases fueran un
solo sistema era la **replicación de mezcla**. El Merge Agent era quien
llevaba una solicitud creada en `BD_Monterrey` hasta `BD_Central` para que
la atendieran, y quien bajaba a las sucursales el catálogo que Central daba
de alta.

**PostgreSQL no tiene replicación de mezcla.** Tiene replicación lógica,
pero es unidireccional (un publicador, varios suscriptores de sólo lectura),
no bidireccional con resolución de conflictos. No es un reemplazo.

Si las cuatro bases quedaran conectadas cada una por su lado
(`MODO_DEMO = false`), pasaría esto:

- Monterrey pediría reabasto → Central **nunca vería** la petición.
- Central daría de alta un producto → **no llegaría** a las sucursales.
- El panorama de la red mostraría siempre ceros en las otras sedes.

**La solución** (y es la que el propio código ya traía prevista, no un
invento nuevo): `config.php` define `MODO_DEMO = true`, y con eso las cuatro
sucursales resuelven a `bd_central`. La separación de datos la sigue
haciendo `SucursalID`, que es como está diseñado **todo** el modelo:
`InventarioSucursal` está particionada por sucursal, `SolicitudesStock`
guarda de qué sucursal es cada requisición, `Ventas` también. Cada usuario
sigue viendo sólo lo suyo, y el flujo completo funciona igual que antes —
de hecho mejor, porque desaparece el retraso de sincronización.

**Entonces, ¿para qué las 4 bases?** Porque el diseño distribuido es el
proyecto, y queda instalado y documentado: las cuatro existen, con el
esquema completo y los mismos datos maestros, listas para operar por
separado. Lo único que falta para activarlas es el mecanismo de sincronía,
y cuando lo tengas, se cambia **una línea**:

```php
define('MODO_DEMO', false);
```

Los dos caminos para llegar ahí, si algún día lo quieres:

- **`postgres_fdw`** — Neon lo soporta. Cada base monta como tablas
  foráneas el `InventarioSucursal` y `SolicitudesStock` de las demás. Es lo
  más cercano al comportamiento original.
- **Replicación lógica** — Central publica el catálogo maestro
  (`Productos`, `Categorias`, `Proveedores`, `Empleados`) y las tres
  sucursales lo consumen de sólo lectura. Resuelve la mitad del problema
  (el catálogo), no las requisiciones.

---

## 4. Traducción SQL Server → PostgreSQL

Lo que cambió y por qué. Es útil tenerlo a la mano si vas a escribir
consultas nuevas.

| SQL Server | PostgreSQL | Nota |
|---|---|---|
| `dbo.Tabla` | `dbo."Tabla"` | Se conservó el esquema `dbo` |
| `ProductoID` | `"ProductoID"` | **Postgres pasa a minúsculas todo identificador sin comillas.** Entrecomillar conserva el PascalCase y, con él, las claves de `$fila['ProductoID']` en PHP |
| `INT IDENTITY(1,1)` | `GENERATED BY DEFAULT AS IDENTITY` | |
| `NVARCHAR(n)` | `VARCHAR(n)` | Postgres es UTF-8 nativo |
| `DATETIME2(0)` | `TIMESTAMP(0)` | |
| `BIT` | `SMALLINT` 0/1 | **No `BOOLEAN`**: PDO devuelve el booleano de Postgres como la cadena `'f'`, que en PHP es *verdadera*. Con 0/1, el `if ($fila['Activo'])` que ya está escrito sigue siendo correcto |
| `SYSDATETIME()` | `dbo.ahora()` | Neon corre en UTC; `ahora()` devuelve hora de México, si no el corte de "ventas de hoy" se movería a las 18:00 |
| `ISNULL(a, b)` | `COALESCE(a, b)` | |
| `SELECT TOP n` | `LIMIT n` | Va al final, no pegado al `SELECT` |
| `LIKE` | `ILIKE` | SQL Server no distinguía mayúsculas por intercalación; `LIKE` de Postgres sí. `ILIKE` conserva el comportamiento |
| `N'texto'` | `'texto'` | |
| `SCOPE_IDENTITY()` | `... RETURNING "Id"` | |
| `@@ROWCOUNT` | `GET DIAGNOSTICS x = ROW_COUNT` | |
| `THROW 50001, 'msg', 1` | `RAISE EXCEPTION 'msg'` | |
| `CREATE PROCEDURE` | `CREATE FUNCTION ... RETURNS TABLE` | Funciones, no procedimientos: el PHP consume el conjunto de resultados. Se llaman con `SELECT * FROM dbo.usp_x(...)` |
| `BEGIN TRAN` / `COMMIT` | *(se eliminan)* | El cuerpo de una función ya es atómico |
| Índice filtrado | Índice parcial | Equivalente, y sin la exigencia de `QUOTED_IDENTIFIER ON` que obligaba a invocar `sqlcmd -I` |
| Trigger por conjunto (`inserted`/`deleted`) | Trigger `FOR EACH ROW` (`NEW`/`OLD`) | |
| `NOT FOR REPLICATION` | *(se elimina)* | No hay agente de replicación del que protegerse |
| `alias local` | `alias local_` | `LOCAL` es palabra reservada en Postgres |

### Un detalle que sí era un error, no sólo sintaxis

`ProductoRepo::cambiarEstado()` pasaba las solicitudes `PENDIENTE` a
`RECHAZADO` al dar de baja un producto. Pero una fila `PENDIENTE` tiene
`CantidadOfrecida = NULL`, y la restricción `CK_Sol_OfertaCoherente`
—que ya existía en el script original de SQL Server— exige que toda
solicitud fuera de `PENDIENTE` traiga cantidad. Ese `UPDATE` habría fallado
en cuanto se diera de baja un producto con solicitudes abiertas. En la
versión de Neon el `UPDATE` fija también `CantidadOfrecida = 0`.

---

## 5. Los archivos

| Archivo | Qué hace |
|---|---|
| `01_esquema.sql` | Esquema `dbo`, 11 tablas, índices, 2 vistas, función `ahora()` |
| `02_funciones_y_trigger.sql` | Las 8 funciones de negocio (`usp_*`), 2 auxiliares y el trigger de alerta |
| `03_catalogo_base.sql` | Sucursales, categorías, proveedores, 30 productos y los 4 usuarios |
| `04_inventario_inicial.sql` | Crea la fila (sucursal, producto) para todas las combinaciones, en cero |
| `05_datos_demo.sql` | *(Opcional)* Existencias de arranque, con algunas en nivel bajo para probar el flujo de alertas |
| `06_verificacion.sql` | Comprobaciones + prueba de humo del ciclo completo, que se revierte sola |
| `99_reset.sql` | ⚠ Borra todo el esquema `dbo` para reinstalar desde cero |

Los datos de `03` y `05` son **inventados**: el proyecto original no traía
volcado de datos, sólo la estructura. Son plausibles para una tienda de
accesorios de perros y gatos y se pueden sustituir por los reales sin tocar
nada más.

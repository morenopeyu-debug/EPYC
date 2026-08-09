# 🐾 EPYC — Inventario Distribuido (PHP + PostgreSQL/Neon)

### ▶ En línea: **https://epyc-inventario.duckdns.org**

| Sucursal | Usuario | Contraseña |
|---|---|---|
| Central | `central` | `12345678` |
| Monterrey | `monterrey` | `12345678` |
| Puebla | `puebla` | `12345678` |
| Querétaro | `queretaro` | `12345678` |

> Corre en el plan gratuito de Render. Si lleva rato sin visitas, la
> primera carga puede tardar ~50 segundos en despertar el contenedor.

---

Tienda de accesorios para perros y gatos con 4 sedes (Central, Monterrey,
Puebla, Querétaro). El inventario está **particionado por sucursal**: cada
sede escribe únicamente las filas que le pertenecen, y todo movimiento de
stock hacia una sucursal pasa por un flujo de solicitud / oferta /
respuesta en vez de un `UPDATE` directo.

**Arquitectura:** navegador → **DuckDNS** (nombre) → **Render** (contenedor
Docker con PHP + Apache) → **Neon** (4 bases PostgreSQL).

> **Migrado desde SQL Server.** El proyecto original corría sobre 4
> instancias de SQL Server con Replicación de Mezcla. Los scripts viejos se
> conservan en [sql/legacy_sqlserver/](sql/legacy_sqlserver/) como
> referencia; los que se usan hoy están en [sql/neon/](sql/neon/).

---

## Puesta en marcha

### 1. Base de datos

Sigue [sql/neon/00_LEEME.md](sql/neon/00_LEEME.md): crea las 4 bases en Neon
(`bd_central`, `bd_monterrey`, `bd_puebla`, `bd_queretaro`) y corre los
scripts `01` → `04` en cada una (`05` es inventario de demostración,
opcional).

### 2. PHP

1. **PHP 8.2+**
2. **pdo_pgsql** habilitado en `php.ini` — quita el `;` de estas dos líneas
   y reinicia el servidor:
   ```ini
   extension=pdo_pgsql
   extension=pgsql
   ```
   (Ya no hace falta `pdo_sqlsrv` ni el ODBC Driver de Microsoft.)

### 3. Credenciales

```
cp config.local.example.php config.local.php
```

Y en `config.local.php` pega lo que te da Neon en *Connection Details*:

```php
define('NEON_HOST',     'ep-tu-endpoint-pooler.c-4.us-east-2.aws.neon.tech');
define('NEON_USUARIO',  'neondb_owner');
define('NEON_PASSWORD', 'tu_password');
```

> ⚠ **`config.local.php` está en `.gitignore` a propósito**: es el único
> archivo con la contraseña y no debe subir a GitHub. `config.php` sí se
> versiona porque no contiene credenciales — las lee de este archivo en
> local, o de variables de entorno en la nube. Si alguna vez subes la
> contraseña por accidente, no basta con borrarla en un commit nuevo
> —queda en el historial—: rótala en Neon (*Roles → Reset password*).

> **Nota sobre Neon y `libpq`.** Si conectas desde otra herramienta y sale
> `Endpoint ID is not specified`, es porque la `libpq` de XAMPP es anterior al
> soporte de SNI y Neon no sabe a qué endpoint mandarte. `lib/Database.php` ya
> lo resuelve solo, añadiendo `options=endpoint=<id>` derivado del host. Está
> explicado en [sql/neon/00_LEEME.md](sql/neon/00_LEEME.md).

### 4. Levantar la página

```
cd proyecto_web
php -S 0.0.0.0:8000
```

Entra a `http://localhost:8000/login.php`.

### 5. Publicarlo en internet

Para que la página quede accesible desde `https://tu-nombre.duckdns.org`,
sigue [DESPLIEGUE.md](DESPLIEGUE.md): se despliega en **Render** con el
`Dockerfile` de este repositorio y **DuckDNS** le pone el nombre.

| Sucursal | Usuario | Contraseña |
|---|---|---|
| Central | `central` | `12345678` |
| Monterrey | `monterrey` | `12345678` |
| Puebla | `puebla` | `12345678` |
| Querétaro | `queretaro` | `12345678` |

Para cambiarlas: `php generar_hash.php "NuevaContraseña"` y sustituye el
hash en `sql/neon/03_catalogo_base.sql` (o directo en la tabla `Empleados`).

---

## `MODO_DEMO`: por qué está en `true`

`config.php` trae `MODO_DEMO = true`, y con eso las cuatro sucursales
resuelven a `bd_central`. **No es un atajo, es un requisito de PostgreSQL.**

En SQL Server, lo que hacía de las cuatro bases un solo sistema era la
replicación de mezcla: el Merge Agent llevaba una solicitud de Monterrey
hasta Central, y bajaba el catálogo de Central a las sucursales. PostgreSQL
no tiene ese mecanismo (su replicación lógica es unidireccional y de sólo
lectura). Con `MODO_DEMO = false`, cada base quedaría aislada: Monterrey
pediría reabasto y Central nunca vería la petición.

Con `MODO_DEMO = true` el flujo completo funciona igual que antes —y sin
retraso de sincronización—, porque la separación de datos nunca dependió de
la replicación: la hace `SucursalID`, que está en `InventarioSucursal`,
`SolicitudesStock` y `Ventas`.

Las 4 bases se crean de todas formas, con el esquema completo, listas para
operar por separado el día que se monte `postgres_fdw` entre ellas. Está
explicado a detalle en [sql/neon/00_LEEME.md](sql/neon/00_LEEME.md).

---

## Estructura del proyecto

| Archivo/carpeta | Qué hace |
|---|---|
| `bootstrap.php` | Arranque: carga `config.php`, autoload de `lib/`, sesión, valida que `pdo_pgsql` esté instalado |
| `config.php` | Conexión a Neon, `MODO_DEMO`, umbral de stock bajo |
| `lib/Database.php` | Conexión PDO por sucursal y traducción de errores de Postgres |
| `lib/Auth.php` | Login, sesión, guardas de acceso (`requerirCentral()`, `requerirSucursal()`) |
| `lib/ProductoRepo.php` | Catálogo — ABC exclusivo de Central |
| `lib/InventarioRepo.php` | Stock por sucursal, alertas, niveles |
| `lib/SolicitudRepo.php` | Flujo de requisiciones Central ↔ Sucursal |
| `lib/VentaRepo.php` | Ventas de mostrador |
| `login.php`, `logout.php`, `header.php`, `footer.php` | Sesión y layout compartido |
| `productos.php` | Catálogo + búsqueda; ABC solo Central |
| `inventario.php` | Stock local; Central registra entradas, sucursales piden reabasto |
| `ventas.php` | Punto de venta — solo sucursales |
| `alertas.php` | Panorama de stock bajo, ajuste de umbrales — solo sucursales |
| `solicitudes.php` | Bandeja de requisiciones — vista dual Central/Sucursal |
| `asignar_stock.php` | Central empuja stock sin que se lo pidan |
| `entrada_mercancia.php` | Recepción de proveedor — solo Central |
| `sql/neon/` | Scripts de creación de las 4 bases en Neon |
| `sql/legacy_sqlserver/` | Scripts originales de SQL Server (referencia histórica) |

---

## Reglas de negocio

**El ABC de productos es sólo de Central.** `Productos`, `Categorias` y
`Proveedores` son catálogo maestro. La baja es siempre lógica
(`Activo = 0`): hay referencias vivas desde `Movimientos`, `DetalleVenta` e
`InventarioSucursal`.

**Las sucursales no editan su stock a mano.** Cada sitio sólo escribe sus
propias filas de `InventarioSucursal`, así que la mercancía se mueve por el
flujo de requisiciones:

```
  [Sucursal] pide ................................. PENDIENTE
       |                                               |
       |                        [Central] ofrece (total o parcial)
       |                        y DESCUENTA su stock ......> OFERTADO
       |                                               |
       |                  [Sucursal] responde  +-------+-------+
       |                                       |               |
       |                                   ACEPTADO        RECHAZADO
       |                                (suma su stock)   (Central reintegra)
  [Central] envía directo (sin pedido previo) .....> OFERTADO
```

**La alerta de stock bajo es automática.** El trigger
`trg_InvSuc_AlertaStockBajo` levanta la requisición en cuanto una venta deja
el producto en el punto de reorden (5 unidades) o por debajo. `alertas.php`
permite además forzar el barrido y ajustar los umbrales por sucursal.

**Toda escritura de stock pasa por las funciones `usp_*` de la base.** La
validación de existencias y la transacción viven en un solo lugar y no se
pueden saltar desde una pantalla nueva.

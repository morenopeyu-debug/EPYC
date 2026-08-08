/* =====================================================================
   02_funciones_y_trigger.sql
   Lógica de negocio: los procedimientos almacenados de SQL Server
   traducidos a funciones PL/pgSQL, y el trigger de alerta de stock bajo.

   EJECUTAR EN LAS 4 BASES, después de 01_esquema.sql.

   ---------------------------------------------------------------------
   POR QUÉ ESTO VIVE EN LA BASE Y NO EN PHP
   ---------------------------------------------------------------------
   Toda escritura de stock pasa por aquí. La aplicación NO hace UPDATE
   sobre InventarioSucursal directamente (salvo los umbrales de reorden,
   que no mueven existencias): así la validación de stock y la
   transaccionalidad viven en un solo lugar y no se pueden saltar desde
   una pantalla nueva o desde una consulta a mano.

   ---------------------------------------------------------------------
   EQUIVALENCIAS DE TRADUCCIÓN
   ---------------------------------------------------------------------
   CREATE PROCEDURE       -> CREATE FUNCTION ... RETURNS TABLE(...)
                             Se usan FUNCIONES, no PROCEDURES, porque el
                             código PHP consume el conjunto de resultados
                             que devolvían (SolicitudID, VentaID, ...).
                             Se invocan con  SELECT * FROM dbo.usp_x(...)
   BEGIN TRAN / COMMIT    -> se eliminan: en Postgres el cuerpo de una
                             función ya es atómico. Si algo lanza
                             excepción, todo lo hecho dentro se revierte.
   THROW 50001, 'msg', 1  -> RAISE EXCEPTION 'msg'   (SQLSTATE P0001)
   SCOPE_IDENTITY()       -> INSERT ... RETURNING ... INTO
   @@ROWCOUNT             -> GET DIAGNOSTICS ... ROW_COUNT
   ISNULL(a, b)           -> COALESCE(a, b)
   SYSDATETIME()          -> dbo.ahora()
   NOT FOR REPLICATION    -> se elimina: no había replicación que filtrar.
   ===================================================================== */

SET search_path TO dbo, public;


/* =====================================================================
   HELPERS
   ===================================================================== */

/* ---------------------------------------------------------------------
   Devuelve el SucursalID de la sede central.
   Sustituye al  SELECT TOP 1 ... WHERE EsCentral = 1  repetido en cada
   procedimiento del script original.
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION dbo.fn_sucursal_central()
RETURNS INTEGER
LANGUAGE sql
STABLE
AS $$
    SELECT "SucursalID"
      FROM dbo."Sucursales"
     WHERE "EsCentral" = 1
     ORDER BY "SucursalID"
     LIMIT 1;
$$;


/* ---------------------------------------------------------------------
   Garantiza que exista la fila (sucursal, producto).
   Así la UI siempre tiene dónde escribir y las consultas no dependen de
   LEFT JOIN + COALESCE.
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION dbo.usp_invsuc_asegurar_fila(
    p_sucursalid  INTEGER,
    p_productoid  INTEGER
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO dbo."InventarioSucursal"
        ("SucursalID", "ProductoID", "Stock", "StockMinimo", "StockObjetivo")
    SELECT p_sucursalid, p_productoid, 0, 5, 20
      FROM dbo."Productos" p
     WHERE p."ProductoID" = p_productoid
    ON CONFLICT ("SucursalID", "ProductoID") DO NOTHING;
END;
$$;


/* =====================================================================
   1. ENTRADA DE MERCANCÍA   (rol Central)
   Recepción de producto nuevo o reabastecimiento del proveedor.
   Es el único punto por donde el stock ENTRA a la red.
   ===================================================================== */
CREATE OR REPLACE FUNCTION dbo.usp_entrada_mercancia(
    p_productoid  INTEGER,
    p_cantidad    INTEGER,
    p_empleadoid  INTEGER,
    p_referencia  VARCHAR DEFAULT NULL
)
RETURNS TABLE ("StockResultante" INTEGER)
LANGUAGE plpgsql
AS $$
DECLARE
    v_central  INTEGER;
    v_stock    INTEGER;
BEGIN
    IF p_cantidad <= 0 THEN
        RAISE EXCEPTION 'La cantidad a recibir debe ser mayor que cero.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM dbo."Productos"
                    WHERE "ProductoID" = p_productoid AND "Activo" = 1) THEN
        RAISE EXCEPTION 'El producto no existe o está dado de baja.';
    END IF;

    v_central := dbo.fn_sucursal_central();

    PERFORM dbo.usp_invsuc_asegurar_fila(v_central, p_productoid);

    UPDATE dbo."InventarioSucursal"
       SET "Stock"               = "Stock" + p_cantidad,
           "UltimaActualizacion" = dbo.ahora()
     WHERE "SucursalID" = v_central AND "ProductoID" = p_productoid
    RETURNING "Stock" INTO v_stock;

    INSERT INTO dbo."Movimientos"
        ("ProductoID", "TipoMovimiento", "Cantidad", "SucursalOrigen",
         "SucursalDestino", "EmpleadoID", "Referencia")
    VALUES
        (p_productoid, 'Entrada', p_cantidad, NULL,
         v_central, p_empleadoid, COALESCE(p_referencia, 'Entrada de mercancía'));

    RETURN QUERY SELECT v_stock;
END;
$$;


/* =====================================================================
   2. SOLICITUD DE REABASTECIMIENTO   (rol Sucursal)
   La usan tanto el trigger de stock bajo como la captura manual.
   Devuelve el SolicitudID, o 0 si ya había una solicitud abierta.
   ===================================================================== */
CREATE OR REPLACE FUNCTION dbo.usp_solicitar_reabastecimiento(
    p_sucursalid  INTEGER,
    p_productoid  INTEGER,
    p_cantidad    INTEGER DEFAULT NULL,   -- NULL => hasta StockObjetivo
    p_empleadoid  INTEGER DEFAULT NULL,
    p_origen      VARCHAR DEFAULT 'MANUAL',
    p_comentario  VARCHAR DEFAULT NULL
)
RETURNS TABLE ("SolicitudID" INTEGER)
LANGUAGE plpgsql
AS $$
DECLARE
    v_stock_actual  INTEGER;
    v_objetivo      INTEGER;
    v_cantidad      INTEGER := p_cantidad;
    v_nuevo_id      INTEGER;
BEGIN
    IF EXISTS (SELECT 1 FROM dbo."Sucursales"
                WHERE "SucursalID" = p_sucursalid AND "EsCentral" = 1) THEN
        RAISE EXCEPTION 'Central no se solicita mercancía a sí misma; usa la entrada de mercancía.';
    END IF;

    -- Ya hay una petición viva para ese producto: no se duplica.
    IF EXISTS (SELECT 1 FROM dbo."SolicitudesStock"
                WHERE "SucursalID" = p_sucursalid
                  AND "ProductoID" = p_productoid
                  AND "Estado" IN ('PENDIENTE', 'OFERTADO')) THEN
        RETURN QUERY SELECT 0;
        RETURN;
    END IF;

    SELECT "Stock", "StockObjetivo"
      INTO v_stock_actual, v_objetivo
      FROM dbo."InventarioSucursal"
     WHERE "SucursalID" = p_sucursalid AND "ProductoID" = p_productoid;

    IF v_stock_actual IS NULL THEN
        PERFORM dbo.usp_invsuc_asegurar_fila(p_sucursalid, p_productoid);

        SELECT "Stock", "StockObjetivo"
          INTO v_stock_actual, v_objetivo
          FROM dbo."InventarioSucursal"
         WHERE "SucursalID" = p_sucursalid AND "ProductoID" = p_productoid;
    END IF;

    IF v_cantidad IS NULL THEN
        v_cantidad := v_objetivo - v_stock_actual;
    END IF;

    IF v_cantidad <= 0 THEN
        v_cantidad := 1;
    END IF;

    -- El alias "sol" no es adorno: esta función declara una columna de
    -- salida llamada "SolicitudID" (RETURNS TABLE), y PL/pgSQL la trata
    -- como variable. Un RETURNING "SolicitudID" a secas sería ambiguo;
    -- calificarlo con el alias deja claro que es la columna de la tabla.
    INSERT INTO dbo."SolicitudesStock" AS sol
        ("SucursalID", "ProductoID", "CantidadSolicitada", "Estado", "Origen",
         "StockAlSolicitar", "EmpleadoSolicitaID", "ComentarioSucursal")
    VALUES
        (p_sucursalid, p_productoid, v_cantidad, 'PENDIENTE', p_origen,
         v_stock_actual, p_empleadoid, p_comentario)
    RETURNING sol."SolicitudID" INTO v_nuevo_id;

    RETURN QUERY SELECT v_nuevo_id;
END;
$$;


/* =====================================================================
   3. OFERTA DE CENTRAL   (rol Central)
   Central responde una solicitud PENDIENTE. Puede ofrecer menos de lo
   pedido si no le alcanza el stock — ése es el caso de "envío parcial".

   Central DESCUENTA aquí, no al aceptar: la mercancía sale físicamente
   del almacén central al momento del envío. Si la sucursal rechaza, el
   stock se reintegra con usp_reintegrar_solicitud.
   ===================================================================== */
CREATE OR REPLACE FUNCTION dbo.usp_ofertar_solicitud(
    p_solicitudid  INTEGER,
    p_cantidad     INTEGER,
    p_empleadoid   INTEGER,
    p_comentario   VARCHAR DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_central       INTEGER;
    v_productoid    INTEGER;
    v_sucursalid    INTEGER;
    v_estado        VARCHAR(20);
    v_stock_central INTEGER;
BEGIN
    v_central := dbo.fn_sucursal_central();

    SELECT "ProductoID", "SucursalID", "Estado"
      INTO v_productoid, v_sucursalid, v_estado
      FROM dbo."SolicitudesStock"
     WHERE "SolicitudID" = p_solicitudid;

    IF v_productoid IS NULL THEN
        RAISE EXCEPTION 'La solicitud no existe.';
    END IF;

    IF v_estado <> 'PENDIENTE' THEN
        RAISE EXCEPTION 'Sólo se puede ofertar sobre una solicitud PENDIENTE.';
    END IF;

    IF p_cantidad <= 0 THEN
        RAISE EXCEPTION 'La cantidad a enviar debe ser mayor que cero.';
    END IF;

    SELECT "Stock" INTO v_stock_central
      FROM dbo."InventarioSucursal"
     WHERE "SucursalID" = v_central AND "ProductoID" = v_productoid;

    IF COALESCE(v_stock_central, 0) < p_cantidad THEN
        RAISE EXCEPTION 'Central no tiene stock suficiente para esa cantidad.';
    END IF;

    -- Central escribe SU propia fila de inventario.
    UPDATE dbo."InventarioSucursal"
       SET "Stock"               = "Stock" - p_cantidad,
           "UltimaActualizacion" = dbo.ahora()
     WHERE "SucursalID" = v_central AND "ProductoID" = v_productoid;

    UPDATE dbo."SolicitudesStock"
       SET "CantidadOfrecida"  = p_cantidad,
           "Estado"            = 'OFERTADO',
           "EmpleadoAtiendeID" = p_empleadoid,
           "ComentarioCentral" = p_comentario,
           "FechaOferta"       = dbo.ahora()
     WHERE "SolicitudID" = p_solicitudid;

    INSERT INTO dbo."Transferencias"
        ("ProductoID", "Cantidad", "SucursalOrigen", "SucursalDestino",
         "Estado", "EmpleadoID", "SolicitudID")
    VALUES
        (v_productoid, p_cantidad, v_central, v_sucursalid,
         'Pendiente', p_empleadoid, p_solicitudid);

    INSERT INTO dbo."Movimientos"
        ("ProductoID", "TipoMovimiento", "Cantidad", "SucursalOrigen",
         "SucursalDestino", "EmpleadoID", "Referencia")
    VALUES
        (v_productoid, 'Salida', p_cantidad, v_central, v_sucursalid, p_empleadoid,
         'Envío a sucursal — solicitud #' || p_solicitudid::text);
END;
$$;


/* =====================================================================
   4. ENVÍO DIRECTO DE CENTRAL   (rol Central)
   "Asignación y transferencia" sin que la sucursal haya pedido nada.

   Se modela como una solicitud que nace ya OFERTADA, para que la
   sucursal la confirme por el mismo camino y el stock nunca se
   incremente desde fuera del sitio dueño de la fila.
   ===================================================================== */
CREATE OR REPLACE FUNCTION dbo.usp_asignar_stock_sucursal(
    p_productoid  INTEGER,
    p_sucursalid  INTEGER,
    p_cantidad    INTEGER,
    p_empleadoid  INTEGER,
    p_comentario  VARCHAR DEFAULT NULL
)
RETURNS TABLE ("SolicitudID" INTEGER)
LANGUAGE plpgsql
AS $$
DECLARE
    v_central        INTEGER;
    v_stock_central  INTEGER;
    v_nuevo_id       INTEGER;
BEGIN
    v_central := dbo.fn_sucursal_central();

    IF p_sucursalid = v_central THEN
        RAISE EXCEPTION 'El destino debe ser una sucursal distinta de Central.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM dbo."Sucursales" WHERE "SucursalID" = p_sucursalid) THEN
        RAISE EXCEPTION 'La sucursal destino no existe.';
    END IF;

    IF p_cantidad <= 0 THEN
        RAISE EXCEPTION 'La cantidad a asignar debe ser mayor que cero.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM dbo."Productos"
                    WHERE "ProductoID" = p_productoid AND "Activo" = 1) THEN
        RAISE EXCEPTION 'El producto no existe o está dado de baja.';
    END IF;

    IF EXISTS (SELECT 1 FROM dbo."SolicitudesStock"
                WHERE "SucursalID" = p_sucursalid
                  AND "ProductoID" = p_productoid
                  AND "Estado" IN ('PENDIENTE', 'OFERTADO')) THEN
        RAISE EXCEPTION 'Esa sucursal ya tiene un movimiento abierto de este producto. Atiéndelo antes de mandar más.';
    END IF;

    SELECT "Stock" INTO v_stock_central
      FROM dbo."InventarioSucursal"
     WHERE "SucursalID" = v_central AND "ProductoID" = p_productoid;

    IF COALESCE(v_stock_central, 0) < p_cantidad THEN
        RAISE EXCEPTION 'Central no tiene stock suficiente para esa asignación.';
    END IF;

    UPDATE dbo."InventarioSucursal"
       SET "Stock"               = "Stock" - p_cantidad,
           "UltimaActualizacion" = dbo.ahora()
     WHERE "SucursalID" = v_central AND "ProductoID" = p_productoid;

    -- Alias "sol" por la misma razón que en usp_solicitar_reabastecimiento:
    -- "SolicitudID" es también la columna de salida de esta función.
    INSERT INTO dbo."SolicitudesStock" AS sol
        ("SucursalID", "ProductoID", "CantidadSolicitada", "CantidadOfrecida",
         "Estado", "Origen", "EmpleadoAtiendeID", "ComentarioCentral", "FechaOferta")
    VALUES
        (p_sucursalid, p_productoid, p_cantidad, p_cantidad,
         'OFERTADO', 'ENVIO_CENTRAL', p_empleadoid,
         COALESCE(p_comentario, 'Asignación directa de Central'), dbo.ahora())
    RETURNING sol."SolicitudID" INTO v_nuevo_id;

    INSERT INTO dbo."Transferencias"
        ("ProductoID", "Cantidad", "SucursalOrigen", "SucursalDestino",
         "Estado", "EmpleadoID", "SolicitudID")
    VALUES
        (p_productoid, p_cantidad, v_central, p_sucursalid,
         'Pendiente', p_empleadoid, v_nuevo_id);

    INSERT INTO dbo."Movimientos"
        ("ProductoID", "TipoMovimiento", "Cantidad", "SucursalOrigen",
         "SucursalDestino", "EmpleadoID", "Referencia")
    VALUES
        (p_productoid, 'Transferencia', p_cantidad, v_central, p_sucursalid, p_empleadoid,
         'Asignación directa — solicitud #' || v_nuevo_id::text);

    RETURN QUERY SELECT v_nuevo_id;
END;
$$;


/* =====================================================================
   5. RESPUESTA DE LA SUCURSAL   (rol Sucursal)
   Aceptar  -> el stock entra oficialmente al inventario de la sucursal.
   Rechazar -> queda para que Central reintegre lo que ya había apartado.
   ===================================================================== */
CREATE OR REPLACE FUNCTION dbo.usp_responder_solicitud(
    p_solicitudid  INTEGER,
    p_aceptar      SMALLINT,
    p_empleadoid   INTEGER,
    p_comentario   VARCHAR DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_sucursalid  INTEGER;
    v_productoid  INTEGER;
    v_cantidad    INTEGER;
    v_estado      VARCHAR(20);
    v_central     INTEGER;
BEGIN
    SELECT "SucursalID", "ProductoID", "CantidadOfrecida", "Estado"
      INTO v_sucursalid, v_productoid, v_cantidad, v_estado
      FROM dbo."SolicitudesStock"
     WHERE "SolicitudID" = p_solicitudid;

    IF v_sucursalid IS NULL THEN
        RAISE EXCEPTION 'La solicitud no existe.';
    END IF;

    IF v_estado <> 'OFERTADO' THEN
        RAISE EXCEPTION 'Sólo se puede responder una solicitud en estado OFERTADO.';
    END IF;

    v_central := dbo.fn_sucursal_central();

    IF p_aceptar = 1 THEN
        -- La sucursal escribe SU propia fila de inventario.
        PERFORM dbo.usp_invsuc_asegurar_fila(v_sucursalid, v_productoid);

        UPDATE dbo."InventarioSucursal"
           SET "Stock"               = "Stock" + v_cantidad,
               "UltimaActualizacion" = dbo.ahora()
         WHERE "SucursalID" = v_sucursalid AND "ProductoID" = v_productoid;

        UPDATE dbo."SolicitudesStock"
           SET "Estado"             = 'ACEPTADO',
               "FechaRespuesta"     = dbo.ahora(),
               "ComentarioSucursal" = p_comentario
         WHERE "SolicitudID" = p_solicitudid;

        UPDATE dbo."Transferencias"
           SET "Estado" = 'Completada'
         WHERE "SolicitudID" = p_solicitudid AND "Estado" = 'Pendiente';

        INSERT INTO dbo."Movimientos"
            ("ProductoID", "TipoMovimiento", "Cantidad", "SucursalOrigen",
             "SucursalDestino", "EmpleadoID", "Referencia")
        VALUES
            (v_productoid, 'Entrada', v_cantidad, v_central, v_sucursalid, p_empleadoid,
             'Recepción aceptada — solicitud #' || p_solicitudid::text);
    ELSE
        UPDATE dbo."SolicitudesStock"
           SET "Estado"             = 'RECHAZADO',
               "FechaRespuesta"     = dbo.ahora(),
               "ComentarioSucursal" = p_comentario
         WHERE "SolicitudID" = p_solicitudid;

        UPDATE dbo."Transferencias"
           SET "Estado" = 'Rechazada'
         WHERE "SolicitudID" = p_solicitudid AND "Estado" = 'Pendiente';
    END IF;
END;
$$;


/* =====================================================================
   6. REINTEGRO   (rol Central)
   La sucursal rechazó: la mercancía apartada regresa al almacén central.
   ===================================================================== */
CREATE OR REPLACE FUNCTION dbo.usp_reintegrar_solicitud(
    p_solicitudid  INTEGER,
    p_empleadoid   INTEGER
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_productoid     INTEGER;
    v_cantidad       INTEGER;
    v_estado         VARCHAR(20);
    v_ya_reintegrado SMALLINT;
    v_central        INTEGER;
BEGIN
    SELECT "ProductoID", "CantidadOfrecida", "Estado", "StockReintegrado"
      INTO v_productoid, v_cantidad, v_estado, v_ya_reintegrado
      FROM dbo."SolicitudesStock"
     WHERE "SolicitudID" = p_solicitudid;

    IF v_productoid IS NULL THEN
        RAISE EXCEPTION 'La solicitud no existe.';
    END IF;

    IF v_estado <> 'RECHAZADO' THEN
        RAISE EXCEPTION 'Sólo se reintegra el stock de una solicitud RECHAZADA.';
    END IF;

    IF v_ya_reintegrado = 1 THEN
        RAISE EXCEPTION 'El stock de esta solicitud ya fue reintegrado.';
    END IF;

    v_central := dbo.fn_sucursal_central();

    PERFORM dbo.usp_invsuc_asegurar_fila(v_central, v_productoid);

    UPDATE dbo."InventarioSucursal"
       SET "Stock"               = "Stock" + v_cantidad,
           "UltimaActualizacion" = dbo.ahora()
     WHERE "SucursalID" = v_central AND "ProductoID" = v_productoid;

    UPDATE dbo."SolicitudesStock"
       SET "StockReintegrado" = 1
     WHERE "SolicitudID" = p_solicitudid;

    INSERT INTO dbo."Movimientos"
        ("ProductoID", "TipoMovimiento", "Cantidad", "SucursalOrigen",
         "SucursalDestino", "EmpleadoID", "Referencia")
    VALUES
        (v_productoid, 'Entrada', v_cantidad, NULL, v_central, p_empleadoid,
         'Reintegro por rechazo — solicitud #' || p_solicitudid::text);
END;
$$;


/* =====================================================================
   7. VENTA   (rol Sucursal)
   Descuenta stock de la sucursal y registra Venta + DetalleVenta.
   El trigger de stock bajo se encarga de la alerta si toca.
   ===================================================================== */
CREATE OR REPLACE FUNCTION dbo.usp_registrar_venta(
    p_sucursalid  INTEGER,
    p_productoid  INTEGER,
    p_cantidad    INTEGER,
    p_empleadoid  INTEGER
)
RETURNS TABLE ("VentaID" INTEGER, "Total" NUMERIC, "StockResultante" INTEGER)
LANGUAGE plpgsql
AS $$
DECLARE
    v_precio        NUMERIC(18,2);
    v_activo        SMALLINT;
    v_stock_actual  INTEGER;
    v_venta_id      INTEGER;
    v_total         NUMERIC(18,2);
    v_stock_final   INTEGER;
BEGIN
    IF p_cantidad <= 0 THEN
        RAISE EXCEPTION 'La cantidad vendida debe ser mayor que cero.';
    END IF;

    SELECT "PrecioUnitario", "Activo"
      INTO v_precio, v_activo
      FROM dbo."Productos"
     WHERE "ProductoID" = p_productoid;

    IF v_precio IS NULL THEN
        RAISE EXCEPTION 'El producto no existe.';
    END IF;

    IF v_activo = 0 THEN
        RAISE EXCEPTION 'El producto está dado de baja y no puede venderse.';
    END IF;

    SELECT "Stock" INTO v_stock_actual
      FROM dbo."InventarioSucursal"
     WHERE "SucursalID" = p_sucursalid AND "ProductoID" = p_productoid;

    IF COALESCE(v_stock_actual, 0) < p_cantidad THEN
        RAISE EXCEPTION 'Stock insuficiente en esta sucursal para completar la venta.';
    END IF;

    v_total := v_precio * p_cantidad;

    -- Alias "vta": "VentaID" es también columna de salida de esta función.
    INSERT INTO dbo."Ventas" AS vta ("Fecha", "EmpleadoID", "Total", "SucursalID")
    VALUES (dbo.ahora(), p_empleadoid, v_total, p_sucursalid)
    RETURNING vta."VentaID" INTO v_venta_id;

    INSERT INTO dbo."DetalleVenta" ("VentaID", "ProductoID", "Cantidad", "PrecioUnitario")
    VALUES (v_venta_id, p_productoid, p_cantidad, v_precio);

    -- Este UPDATE es el que puede disparar trg_invsuc_alerta_stock_bajo.
    UPDATE dbo."InventarioSucursal"
       SET "Stock"               = "Stock" - p_cantidad,
           "UltimaActualizacion" = dbo.ahora()
     WHERE "SucursalID" = p_sucursalid AND "ProductoID" = p_productoid
    RETURNING "Stock" INTO v_stock_final;

    INSERT INTO dbo."Movimientos"
        ("ProductoID", "TipoMovimiento", "Cantidad", "SucursalOrigen",
         "SucursalDestino", "EmpleadoID", "Referencia")
    VALUES
        (p_productoid, 'Venta', p_cantidad, p_sucursalid, NULL, p_empleadoid,
         'Venta #' || v_venta_id::text);

    RETURN QUERY SELECT v_venta_id, v_total, v_stock_final;
END;
$$;


/* =====================================================================
   8. BARRIDO MANUAL DE ALERTAS
   El trigger cubre el flujo normal; esto sirve para la carga inicial o
   si alguien tocó el inventario por fuera de la aplicación.
   ===================================================================== */
CREATE OR REPLACE FUNCTION dbo.usp_generar_alertas_stock_bajo(
    p_sucursalid  INTEGER,
    p_empleadoid  INTEGER DEFAULT NULL
)
RETURNS TABLE ("AlertasGeneradas" INTEGER)
LANGUAGE plpgsql
AS $$
DECLARE
    v_generadas INTEGER;
BEGIN
    INSERT INTO dbo."SolicitudesStock"
        ("SucursalID", "ProductoID", "CantidadSolicitada", "Estado", "Origen",
         "StockAlSolicitar", "EmpleadoSolicitaID")
    SELECT inv."SucursalID",
           inv."ProductoID",
           GREATEST(inv."StockObjetivo" - inv."Stock", 1),
           'PENDIENTE',
           'AUTOMATICA',
           inv."Stock",
           p_empleadoid
      FROM dbo."InventarioSucursal" inv
      JOIN dbo."Productos" p ON p."ProductoID" = inv."ProductoID" AND p."Activo" = 1
     WHERE inv."SucursalID" = p_sucursalid
       AND inv."Stock" <= inv."StockMinimo"
       AND NOT EXISTS (SELECT 1
                         FROM dbo."SolicitudesStock" s
                        WHERE s."SucursalID" = inv."SucursalID"
                          AND s."ProductoID" = inv."ProductoID"
                          AND s."Estado" IN ('PENDIENTE', 'OFERTADO'));

    GET DIAGNOSTICS v_generadas = ROW_COUNT;

    RETURN QUERY SELECT v_generadas;
END;
$$;


/* =====================================================================
   9. TRIGGER DE ALERTA AUTOMÁTICA DE STOCK BAJO

   Levanta sola la requisición hacia Central cuando una venta deja el
   producto en el punto de reorden o por debajo.

   En SQL Server el trigger era por CONJUNTO (tablas inserted/deleted) y
   llevaba NOT FOR REPLICATION para no dispararse cuando el Merge Agent
   aplicaba cambios ajenos. Aquí es FOR EACH ROW —más simple y directo—
   y no necesita esa cláusula porque no hay agente de replicación
   escribiendo por detrás.

   Las tres condiciones que importan y por qué:
     · el stock BAJÓ (no subió): un reabasto no debe pedir más reabasto
     · quedó <= StockMinimo   : cruzó el punto de reorden
     · la sede no es Central  : Central se reabastece con el proveedor
   ===================================================================== */
CREATE OR REPLACE FUNCTION dbo.trg_invsuc_alerta_stock_bajo()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- Sin cambio de existencias no hay nada que evaluar (por ejemplo,
    -- cuando alertas.php sólo ajusta los umbrales de reorden).
    IF NEW."Stock" IS NOT DISTINCT FROM OLD."Stock" THEN
        RETURN NEW;
    END IF;

    IF NEW."Stock" >= OLD."Stock" THEN
        RETURN NEW;                       -- fue subiendo: no es alerta
    END IF;

    IF NEW."Stock" > NEW."StockMinimo" THEN
        RETURN NEW;                       -- todavía por encima del reorden
    END IF;

    IF EXISTS (SELECT 1 FROM dbo."Sucursales"
                WHERE "SucursalID" = NEW."SucursalID" AND "EsCentral" = 1) THEN
        RETURN NEW;                       -- Central se surte con el proveedor
    END IF;

    IF NOT EXISTS (SELECT 1 FROM dbo."Productos"
                    WHERE "ProductoID" = NEW."ProductoID" AND "Activo" = 1) THEN
        RETURN NEW;                       -- producto dado de baja
    END IF;

    IF EXISTS (SELECT 1 FROM dbo."SolicitudesStock"
                WHERE "SucursalID" = NEW."SucursalID"
                  AND "ProductoID" = NEW."ProductoID"
                  AND "Estado" IN ('PENDIENTE', 'OFERTADO')) THEN
        RETURN NEW;                       -- ya hay una petición viva
    END IF;

    INSERT INTO dbo."SolicitudesStock"
        ("SucursalID", "ProductoID", "CantidadSolicitada", "Estado", "Origen", "StockAlSolicitar")
    VALUES
        (NEW."SucursalID",
         NEW."ProductoID",
         GREATEST(NEW."StockObjetivo" - NEW."Stock", 1),
         'PENDIENTE',
         'AUTOMATICA',
         NEW."Stock");

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS "trg_InvSuc_AlertaStockBajo" ON dbo."InventarioSucursal";

CREATE TRIGGER "trg_InvSuc_AlertaStockBajo"
    AFTER UPDATE ON dbo."InventarioSucursal"
    FOR EACH ROW
    EXECUTE FUNCTION dbo.trg_invsuc_alerta_stock_bajo();


DO $$ BEGIN
    RAISE NOTICE '=====================================================';
    RAISE NOTICE ' [OK] Funciones y trigger instalados.';
    RAISE NOTICE ' Siguiente paso: 03_catalogo_base.sql';
    RAISE NOTICE '=====================================================';
END $$;

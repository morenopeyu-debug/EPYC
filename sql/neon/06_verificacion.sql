/* =====================================================================
   06_verificacion.sql
   Comprueba que la base quedó completa y que la lógica responde.

   EJECUTAR EN CADA BASE que quieras revisar. No modifica nada
   (la prueba de humo del final se revierte sola).
   ===================================================================== */

SET search_path TO dbo, public;


/* ---------------------------------------------------------------------
   1. ¿Están las 11 tablas?
   --------------------------------------------------------------------- */
SELECT table_name AS "Tabla"
  FROM information_schema.tables
 WHERE table_schema = 'dbo' AND table_type = 'BASE TABLE'
 ORDER BY table_name;
-- Esperado: Categorias, DetalleVenta, Empleados, InventarioSucursal,
--           Movimientos, Productos, Proveedores, SolicitudesStock,
--           Sucursales, Transferencias, Ventas   (11 filas)


/* ---------------------------------------------------------------------
   2. ¿Están las 2 vistas y las 12 funciones?
   --------------------------------------------------------------------- */
SELECT table_name AS "Vista"
  FROM information_schema.views
 WHERE table_schema = 'dbo'
 ORDER BY table_name;

SELECT p.proname AS "Funcion",
       pg_get_function_arguments(p.oid) AS "Parametros"
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'dbo'
 ORDER BY p.proname;


/* ---------------------------------------------------------------------
   3. ¿Está armado el trigger de alerta?
   --------------------------------------------------------------------- */
SELECT tgname AS "Trigger", tgenabled AS "Habilitado"
  FROM pg_trigger
 WHERE tgrelid = 'dbo."InventarioSucursal"'::regclass
   AND NOT tgisinternal;


/* ---------------------------------------------------------------------
   4. Conteos de datos
   --------------------------------------------------------------------- */
SELECT 'Sucursales'          AS "Tabla", COUNT(*) AS "Filas" FROM dbo."Sucursales"
UNION ALL SELECT 'Categorias',           COUNT(*) FROM dbo."Categorias"
UNION ALL SELECT 'Proveedores',          COUNT(*) FROM dbo."Proveedores"
UNION ALL SELECT 'Productos',            COUNT(*) FROM dbo."Productos"
UNION ALL SELECT 'Empleados',            COUNT(*) FROM dbo."Empleados"
UNION ALL SELECT 'InventarioSucursal',   COUNT(*) FROM dbo."InventarioSucursal"
UNION ALL SELECT 'SolicitudesStock',     COUNT(*) FROM dbo."SolicitudesStock"
UNION ALL SELECT 'Ventas',               COUNT(*) FROM dbo."Ventas"
UNION ALL SELECT 'Movimientos',          COUNT(*) FROM dbo."Movimientos"
ORDER BY 1;


/* ---------------------------------------------------------------------
   5. Panorama de la red — es la misma consulta que pinta asignar_stock.php
   --------------------------------------------------------------------- */
SELECT  p."Nombre" AS "Producto",
        SUM(CASE WHEN inv."SucursalID" = 1 THEN inv."Stock" ELSE 0 END) AS "Central",
        SUM(CASE WHEN inv."SucursalID" = 2 THEN inv."Stock" ELSE 0 END) AS "Monterrey",
        SUM(CASE WHEN inv."SucursalID" = 3 THEN inv."Stock" ELSE 0 END) AS "Puebla",
        SUM(CASE WHEN inv."SucursalID" = 4 THEN inv."Stock" ELSE 0 END) AS "Queretaro",
        SUM(inv."Stock")                                                AS "Total"
  FROM  dbo."Productos" p
  JOIN  dbo."InventarioSucursal" inv ON inv."ProductoID" = p."ProductoID"
 WHERE  p."Activo" = 1
 GROUP BY p."ProductoID", p."Nombre"
 ORDER BY p."Nombre";


/* ---------------------------------------------------------------------
   6. Productos en nivel bajo por sucursal (lo que muestra alertas.php)
   --------------------------------------------------------------------- */
SELECT  s."Nombre"  AS "Sucursal",
        p."Nombre"  AS "Producto",
        inv."Stock",
        inv."StockMinimo" AS "PuntoReorden"
  FROM  dbo."InventarioSucursal" inv
  JOIN  dbo."Sucursales" s ON s."SucursalID" = inv."SucursalID"
  JOIN  dbo."Productos"  p ON p."ProductoID" = inv."ProductoID"
 WHERE  s."EsCentral" = 0
   AND  p."Activo" = 1
   AND  inv."Stock" <= inv."StockMinimo"
 ORDER BY s."Nombre", p."Nombre";


/* =====================================================================
   7. PRUEBA DE HUMO DEL FLUJO COMPLETO

   Recorre el ciclo entero —venta, alerta automática, oferta de Central,
   aceptación de la sucursal— y al final REVIERTE todo con ROLLBACK, así
   que la base queda exactamente como estaba.

   Corre este bloque completo, de BEGIN a ROLLBACK, de una sola vez.
   ===================================================================== */

BEGIN;

DO $$
DECLARE
    v_producto     INTEGER := 1;   -- Croquetas adulto raza pequeña
    v_sucursal     INTEGER := 2;   -- Monterrey
    v_solicitud    INTEGER;
    v_stock_previo INTEGER;
    v_stock_final  INTEGER;
    v_venta        RECORD;
BEGIN
    -- Punto de partida: dejar a Monterrey con 6 piezas, justo encima
    -- del punto de reorden (5), y sin solicitudes abiertas.
    UPDATE dbo."SolicitudesStock"
       SET "Estado" = 'ACEPTADO', "CantidadOfrecida" = COALESCE("CantidadOfrecida", 0)
     WHERE "SucursalID" = v_sucursal AND "ProductoID" = v_producto
       AND "Estado" IN ('PENDIENTE', 'OFERTADO');

    UPDATE dbo."InventarioSucursal"
       SET "Stock" = 6
     WHERE "SucursalID" = v_sucursal AND "ProductoID" = v_producto;

    -- Y asegurar que Central tenga con qué surtir, por si se saltó el
    -- 05_datos_demo.sql y el almacén central está en cero.
    UPDATE dbo."InventarioSucursal"
       SET "Stock" = GREATEST("Stock", 50)
     WHERE "SucursalID" = 1 AND "ProductoID" = v_producto;

    -- (a) VENTA de 2 piezas -> queda en 4, por debajo del reorden.
    SELECT * INTO v_venta
      FROM dbo.usp_registrar_venta(v_sucursal, v_producto, 2, 2);

    RAISE NOTICE '(a) Venta #% por $% — stock resultante: %',
                 v_venta."VentaID", v_venta."Total", v_venta."StockResultante";

    IF v_venta."StockResultante" <> 4 THEN
        RAISE EXCEPTION 'FALLA: se esperaba stock 4 y quedó %', v_venta."StockResultante";
    END IF;

    -- (b) El TRIGGER debió levantar la solicitud automática solo.
    SELECT "SolicitudID" INTO v_solicitud
      FROM dbo."SolicitudesStock"
     WHERE "SucursalID" = v_sucursal AND "ProductoID" = v_producto
       AND "Estado" = 'PENDIENTE' AND "Origen" = 'AUTOMATICA'
     ORDER BY "SolicitudID" DESC
     LIMIT 1;

    IF v_solicitud IS NULL THEN
        RAISE EXCEPTION 'FALLA: el trigger no generó la solicitud automática.';
    END IF;

    RAISE NOTICE '(b) Trigger OK — solicitud automática #%', v_solicitud;

    -- (c) CENTRAL oferta 10 piezas (sale de su almacén).
    SELECT "Stock" INTO v_stock_previo
      FROM dbo."InventarioSucursal"
     WHERE "SucursalID" = 1 AND "ProductoID" = v_producto;

    PERFORM dbo.usp_ofertar_solicitud(v_solicitud, 10, 1, 'Prueba de humo');

    SELECT "Stock" INTO v_stock_final
      FROM dbo."InventarioSucursal"
     WHERE "SucursalID" = 1 AND "ProductoID" = v_producto;

    IF v_stock_final <> v_stock_previo - 10 THEN
        RAISE EXCEPTION 'FALLA: Central no descontó al ofertar (% -> %)', v_stock_previo, v_stock_final;
    END IF;

    RAISE NOTICE '(c) Central ofertó 10 — su stock pasó de % a %', v_stock_previo, v_stock_final;

    -- (d) La SUCURSAL acepta: 4 + 10 = 14.
    PERFORM dbo.usp_responder_solicitud(v_solicitud, 1::smallint, 2, 'Recibido completo');

    SELECT "Stock" INTO v_stock_final
      FROM dbo."InventarioSucursal"
     WHERE "SucursalID" = v_sucursal AND "ProductoID" = v_producto;

    IF v_stock_final <> 14 THEN
        RAISE EXCEPTION 'FALLA: se esperaba stock 14 en la sucursal y quedó %', v_stock_final;
    END IF;

    RAISE NOTICE '(d) Sucursal aceptó — stock final: %', v_stock_final;

    -- (e) La transferencia debió cerrarse.
    IF NOT EXISTS (SELECT 1 FROM dbo."Transferencias"
                    WHERE "SolicitudID" = v_solicitud AND "Estado" = 'Completada') THEN
        RAISE EXCEPTION 'FALLA: la transferencia no quedó Completada.';
    END IF;

    RAISE NOTICE '(e) Transferencia Completada.';
    RAISE NOTICE '--------------------------------------------';
    RAISE NOTICE ' TODAS LAS PRUEBAS PASARON. Se revierte todo.';
    RAISE NOTICE '--------------------------------------------';
END $$;

ROLLBACK;

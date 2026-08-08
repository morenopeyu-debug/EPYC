/* =====================================================================
   05_datos_demo.sql   (OPCIONAL)
   Existencias de arranque, para que el sistema se pueda probar de
   inmediato en lugar de partir con todo en cero.

   EJECUTAR EN LAS 4 BASES, después de 04_inventario_inicial.sql.
   Si prefieres capturar tú el inventario desde la pantalla de
   "Entrada de mercancía", SÁLTATE este archivo por completo.

   ---------------------------------------------------------------------
   QUÉ DEJA MONTADO
   ---------------------------------------------------------------------
   Central     : 150 piezas de cada producto (el almacén que surte).
   Sucursales  : cantidades variadas y deterministas, calculadas a partir
                 del ProductoID. Algunas quedan A PROPÓSITO en 5 o menos
                 para que la pantalla de Alertas tenga qué mostrar y se
                 pueda probar el flujo completo:

                     Alertas -> "Revisar y generar solicitudes faltantes"
                             -> Central atiende en Solicitudes
                             -> la sucursal acepta o rechaza

   ---------------------------------------------------------------------
   POR QUÉ ESTO NO DISPARA EL TRIGGER
   ---------------------------------------------------------------------
   trg_InvSuc_AlertaStockBajo sólo reacciona cuando el stock BAJA. Aquí
   todo sube desde cero, así que la carga inicial no genera una avalancha
   de solicitudes automáticas: los productos quedan visibles en alerta y
   es el encargado quien decide pedirlos.

   Es idempotente: vuelve a fijar los mismos números, no los acumula.
   ===================================================================== */

SET search_path TO dbo, public;


/* 1. Existencias por sede. */
UPDATE dbo."InventarioSucursal" inv
   SET "Stock" = CASE inv."SucursalID"
                     WHEN 1 THEN 150                              -- Central
                     WHEN 2 THEN 3 + (inv."ProductoID" * 7)  % 28 -- Monterrey
                     WHEN 3 THEN 2 + (inv."ProductoID" * 11) % 25 -- Puebla
                     WHEN 4 THEN 1 + (inv."ProductoID" * 5)  % 30 -- Querétaro
                     ELSE 0
                 END,
       "UltimaActualizacion" = dbo.ahora();


/* 2. Bitácora de la carga inicial, para que el inventario no aparezca
      con existencias que ningún movimiento explica. */
INSERT INTO dbo."Movimientos"
    ("ProductoID", "TipoMovimiento", "Cantidad", "SucursalOrigen",
     "SucursalDestino", "EmpleadoID", "Referencia")
SELECT inv."ProductoID",
       'Ajuste',
       inv."Stock",
       NULL,
       inv."SucursalID",
       1,
       'Carga inicial de inventario'
  FROM dbo."InventarioSucursal" inv
 WHERE inv."Stock" > 0
   AND NOT EXISTS (SELECT 1
                     FROM dbo."Movimientos" m
                    WHERE m."ProductoID"      = inv."ProductoID"
                      AND m."SucursalDestino" = inv."SucursalID"
                      AND m."Referencia"      = 'Carga inicial de inventario');


DO $$
DECLARE
    v_alerta INTEGER;
    v_total  INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_alerta
      FROM dbo."InventarioSucursal" inv
      JOIN dbo."Sucursales" s ON s."SucursalID" = inv."SucursalID"
     WHERE s."EsCentral" = 0 AND inv."Stock" <= inv."StockMinimo";

    SELECT SUM("Stock") INTO v_total FROM dbo."InventarioSucursal";

    RAISE NOTICE '=====================================================';
    RAISE NOTICE ' [OK] Inventario de demostración cargado.';
    RAISE NOTICE '      Piezas en la red : %', v_total;
    RAISE NOTICE '      En nivel bajo    : % (sucursales)', v_alerta;
    RAISE NOTICE ' Siguiente paso: 06_verificacion.sql';
    RAISE NOTICE '=====================================================';
END $$;

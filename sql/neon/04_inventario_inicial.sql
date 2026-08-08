/* =====================================================================
   04_inventario_inicial.sql
   Crea la fila (sucursal, producto) para TODAS las combinaciones.

   EJECUTAR EN LAS 4 BASES, después de 03_catalogo_base.sql.

   ---------------------------------------------------------------------
   POR QUÉ SEMBRAR FILAS EN CERO
   ---------------------------------------------------------------------
   Es la PARTE 4.2 del viejo sql/10_Esquema_MultiSucursal.sql. Con la
   fila ya creada, la interfaz siempre tiene dónde escribir y las
   consultas no dependen de LEFT JOIN + COALESCE para saber que un
   producto existe pero está agotado.

   No hay migración de la vieja dbo.Inventario que hacer: aquella tabla
   era el objeto defectuoso (PK de una sola columna, escrita por los
   cuatro sitios) que esta reconstrucción reemplaza. El stock real entra
   por 05_datos_demo.sql o por la pantalla de entrada de mercancía.

   Umbrales 5 / 20 para todo el catálogo: alerta a las 5 unidades,
   reabastecer hasta 20. Ambos son ajustables después —Central al dar de
   alta un producto, y cada sucursal desde alertas.php.
   ===================================================================== */

SET search_path TO dbo, public;

INSERT INTO dbo."InventarioSucursal"
    ("SucursalID", "ProductoID", "Stock", "StockMinimo", "StockObjetivo")
SELECT s."SucursalID",
       p."ProductoID",
       0,
       5,
       20
  FROM dbo."Sucursales" s
 CROSS JOIN dbo."Productos" p
ON CONFLICT ("SucursalID", "ProductoID") DO NOTHING;


DO $$
DECLARE
    v_filas INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_filas FROM dbo."InventarioSucursal";
    RAISE NOTICE '=====================================================';
    RAISE NOTICE ' [OK] InventarioSucursal tiene % filas (sucursal, producto).', v_filas;
    RAISE NOTICE ' Siguiente paso (opcional): 05_datos_demo.sql';
    RAISE NOTICE '=====================================================';
END $$;

/* =====================================================================
   13_Normalizar_Umbrales.sql
   Deja el punto de reorden en 5 unidades para todo el catálogo.

   EJECUTAR EN: BD_Central   (recuerda la opción -I en sqlcmd)

   ---------------------------------------------------------------------
   POR QUÉ
   ---------------------------------------------------------------------
   El requerimiento es explícito: la alerta se dispara cuando la cantidad
   de un producto en la sucursal es <= 5 unidades.

   Pero los datos de siembra originales traían un Productos.StockMinimo
   distinto por producto (5, 8, 10, 15, 20), y la migración del script 10
   copió esos valores a InventarioSucursal.StockMinimo. Resultado: cada
   producto alertaba con un umbral propio, y en pantalla se veía sin
   sentido —"Churus" marcaba nivel bajo con 10 piezas (su umbral era 20)
   mientras "Rascador torre 3 niveles" no marcaba nada con 8 (su umbral
   era 5).

   Este script unifica el criterio en 5 unidades, que es lo que pide el
   proyecto. Las columnas SIGUEN siendo ajustables: Central puede fijar
   otro punto de reorden al dar de alta un producto, y cada sucursal
   puede afinar el suyo desde alertas.php. Lo que se corrige aquí es el
   punto de partida.
   ===================================================================== */

USE BD_Central;
GO

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

DECLARE @umbral   INT = 5;    -- <= 5 unidades dispara la alerta
DECLARE @objetivo INT = 20;   -- reabastecer hasta esta cantidad

PRINT '--- Antes ---';
SELECT p.Nombre                     AS Producto,
       p.StockMinimo                AS UmbralCatalogo,
       MIN(i.StockMinimo)           AS UmbralMin,
       MAX(i.StockMinimo)           AS UmbralMax
  FROM dbo.Productos p
  JOIN dbo.InventarioSucursal i ON i.ProductoID = p.ProductoID
 GROUP BY p.Nombre, p.StockMinimo
 ORDER BY p.Nombre;


/* 1. Umbral por sucursal: el que realmente gobierna la alerta. */
UPDATE dbo.InventarioSucursal
   SET StockMinimo   = @umbral,
       StockObjetivo = @objetivo
 WHERE StockMinimo <> @umbral
    OR StockObjetivo <> @objetivo;

PRINT '[OK] InventarioSucursal: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' filas normalizadas';


/* 2. Umbral del catálogo maestro.
      Hay que alinearlo también: usp_InvSuc_AsegurarFila y el alta de
      productos siembran las filas nuevas a partir de Productos.StockMinimo.
      Si se dejara en 20, el desajuste volvería en cuanto se creara la
      fila de un producto en una sucursal nueva. */
UPDATE dbo.Productos
   SET StockMinimo = @umbral
 WHERE StockMinimo <> @umbral;

PRINT '[OK] Productos: ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' umbrales de catálogo alineados';
GO


/* 3. Las solicitudes automáticas que se hayan generado con el umbral
      viejo y que ya NO correspondan (el stock está por encima de 5) se
      cierran, para que Central no surta pedidos que nacieron de un
      criterio equivocado. Sólo se tocan las PENDIENTE: si Central ya
      despachó (OFERTADO) la mercancía va en camino y se respeta. */
UPDATE s
   SET s.Estado             = N'RECHAZADO',
       s.FechaRespuesta     = SYSDATETIME(),
       s.ComentarioSucursal = N'Cerrada al unificar el punto de reorden en 5 unidades.'
  FROM dbo.SolicitudesStock s
  JOIN dbo.InventarioSucursal i
    ON i.SucursalID = s.SucursalID AND i.ProductoID = s.ProductoID
 WHERE s.Estado = N'PENDIENTE'
   AND s.Origen = N'AUTOMATICA'
   AND i.Stock  > i.StockMinimo;

PRINT '[OK] ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' alertas obsoletas cerradas';
GO


PRINT '';
PRINT '--- Después ---';
SELECT p.Nombre              AS Producto,
       i.SucursalID,
       i.Stock,
       i.StockMinimo         AS PuntoReorden,
       CASE WHEN i.Stock <= i.StockMinimo THEN 'ALERTA' ELSE '' END AS Estado
  FROM dbo.InventarioSucursal i
  JOIN dbo.Productos p ON p.ProductoID = i.ProductoID
 WHERE i.Stock > 0
 ORDER BY p.Nombre, i.SucursalID;
GO

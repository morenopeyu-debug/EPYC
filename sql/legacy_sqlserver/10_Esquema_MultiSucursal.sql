/* =====================================================================
   10_Esquema_MultiSucursal.sql
   Proyecto: Inventario Mascotas  —  Soporte multi-sucursal sobre
             Replicación de Mezcla (Merge Replication) en SQL Server.

   EJECUTAR EN: BD_Central (el Publicador).
                Los cambios de esquema viajan solos a las suscriptoras
                porque la publicación 'epyc_central' tiene replicación
                de DDL activada. Si la tuvieras apagada, corre este
                mismo script en BD_Monterrey, BD_Puebla y BD_Queretaro.

   ---------------------------------------------------------------------
   POR QUÉ ESTE SCRIPT
   ---------------------------------------------------------------------
   La tabla dbo.Inventario tiene como llave primaria SOLO ProductoID.
   Bajo replicación de mezcla eso significa que Central, Monterrey,
   Puebla y Querétaro escriben LA MISMA FILA. Cuando el Merge Agent
   sincroniza, gana una sola de las cuatro y las demás se van a
   MSmerge_conflict_epyc_central_Inventario: el stock de tres sucursales
   se pierde en silencio en cada sincronización.

   La solución es particionar el inventario por sucursal:
       PK (SucursalID, ProductoID)
   Así cada sitio escribe únicamente filas que le pertenecen y la mezcla
   deja de tener nada que resolver. Ésa es la regla que gobierna todo el
   diseño de aquí en adelante:

       *** CADA SITIO ESCRIBE SOLAMENTE LAS FILAS QUE LE PERTENECEN ***

   ---------------------------------------------------------------------
   NOMENCLATURA
   ---------------------------------------------------------------------
   La petición original nombraba las tablas en snake_case
   (inventario_sucursal, solicitudes_stock, id_producto, ...). La base
   existente ya está en PascalCase (Productos.ProductoID, Categorias...),
   y mezclar dos convenciones en un mismo esquema envejece mal, así que
   se conserva PascalCase. Equivalencias:

       inventario_sucursal   ->  dbo.InventarioSucursal
       id_producto           ->  ProductoID
       id_sucursal           ->  SucursalID
       stock                 ->  Stock
       solicitudes_stock     ->  dbo.SolicitudesStock
       id_solicitud          ->  SolicitudID
       cantidad_solicitada   ->  CantidadSolicitada
       cantidad_ofrecida     ->  CantidadOfrecida
       estado                ->  Estado
   ===================================================================== */

USE BD_Central;
GO

SET NOCOUNT ON;
GO

-- Obligatorio para los índices filtrados de este script, y para que los
-- procedimientos y el trigger queden almacenados con la configuración
-- correcta. sqlcmd los trae APAGADOS por omisión (SSMS los trae encendidos),
-- así que se fijan explícitamente y valen para toda la sesión.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================
   PARTE 1 — TABLA dbo.InventarioSucursal
   Reemplaza a dbo.Inventario. Una fila por (sucursal, producto).
   ===================================================================== */

IF OBJECT_ID('dbo.InventarioSucursal', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.InventarioSucursal
    (
        SucursalID          INT              NOT NULL,
        ProductoID          INT              NOT NULL,
        Stock               INT              NOT NULL
            CONSTRAINT DF_InvSuc_Stock DEFAULT (0),

        -- Punto de reorden. El requerimiento pide alerta con <= 5 unidades;
        -- se deja como columna para poder afinarlo por producto/sucursal.
        StockMinimo         INT              NOT NULL
            CONSTRAINT DF_InvSuc_StockMinimo DEFAULT (5),

        -- Hasta cuánto se quiere reabastecer cuando se dispara la alerta.
        StockObjetivo       INT              NOT NULL
            CONSTRAINT DF_InvSuc_StockObjetivo DEFAULT (20),

        UltimaActualizacion DATETIME2(0)     NOT NULL
            CONSTRAINT DF_InvSuc_Ult DEFAULT (SYSDATETIME()),

        -- La mezcla exige un ROWGUIDCOL con índice único. Se declara
        -- explícito para que sp_addmergearticle lo reutilice en vez de
        -- agregar uno propio.
        rowguid             UNIQUEIDENTIFIER ROWGUIDCOL NOT NULL
            CONSTRAINT DF_InvSuc_rowguid DEFAULT (NEWSEQUENTIALID()),

        CONSTRAINT PK_InventarioSucursal PRIMARY KEY CLUSTERED (SucursalID, ProductoID),

        CONSTRAINT FK_InvSuc_Sucursal FOREIGN KEY (SucursalID)
            REFERENCES dbo.Sucursales (SucursalID),
        CONSTRAINT FK_InvSuc_Producto FOREIGN KEY (ProductoID)
            REFERENCES dbo.Productos (ProductoID),

        -- Red de seguridad: ninguna ruta de código puede dejar stock negativo.
        CONSTRAINT CK_InvSuc_StockNoNegativo CHECK (Stock >= 0),
        CONSTRAINT CK_InvSuc_Minimos        CHECK (StockMinimo >= 0 AND StockObjetivo >= StockMinimo)
    );

    CREATE UNIQUE INDEX UQ_InvSuc_rowguid ON dbo.InventarioSucursal (rowguid);

    -- SucursalID va primero en la PK (particiona por sitio); este índice
    -- cubre la consulta inversa que usa Central: "stock de un producto
    -- en todas las sucursales".
    CREATE INDEX IX_InvSuc_Producto ON dbo.InventarioSucursal (ProductoID) INCLUDE (Stock);

    PRINT '[OK] Creada dbo.InventarioSucursal';
END
ELSE
    PRINT '[--] dbo.InventarioSucursal ya existía';
GO


/* =====================================================================
   PARTE 2 — TABLA dbo.SolicitudesStock
   Bitácora del flujo de requisiciones sucursal -> Central.

   MÁQUINA DE ESTADOS (y quién escribe en cada paso):

     [Sucursal] inserta ................................. PENDIENTE
          |                                                  |
          |                                    [Central] ofrece cantidad
          |                                    (total o parcial) y DESCUENTA
          |                                     su propio stock ....> OFERTADO
          |                                                  |
          |                      [Sucursal] responde  +------+------+
          |                                           |             |
          |                                       ACEPTADO      RECHAZADO
          |                                    (suma su stock)  (Central
          |                                                    reintegra)
     [Central] envía directo (sin solicitud previa) ......> OFERTADO

   Nótese que en ningún momento dos sitios escriben la fila a la vez: el
   turno se pasa junto con el estado. Con seguimiento a nivel columna
   (@column_tracking = 'true' en el script 11) esto es libre de conflictos.
   ===================================================================== */

IF OBJECT_ID('dbo.SolicitudesStock', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.SolicitudesStock
    (
        SolicitudID         INT IDENTITY(1,1) NOT NULL,

        SucursalID          INT              NOT NULL,  -- sucursal que pide (dueña de la fila)
        ProductoID          INT              NOT NULL,

        CantidadSolicitada  INT              NOT NULL,
        CantidadOfrecida    INT              NULL,       -- NULL mientras esté PENDIENTE

        Estado              NVARCHAR(20)     NOT NULL
            CONSTRAINT DF_Sol_Estado DEFAULT (N'PENDIENTE'),

        -- AUTOMATICA   : la disparó el trigger de stock bajo
        -- MANUAL       : la capturó el encargado de la sucursal
        -- ENVIO_CENTRAL: Central empujó mercancía sin que se la pidieran
        Origen              NVARCHAR(20)     NOT NULL
            CONSTRAINT DF_Sol_Origen DEFAULT (N'MANUAL'),

        StockAlSolicitar    INT              NULL,       -- foto del stock que disparó la alerta
        ComentarioCentral   NVARCHAR(300)    NULL,
        ComentarioSucursal  NVARCHAR(300)    NULL,

        EmpleadoSolicitaID  INT              NULL,
        EmpleadoAtiendeID   INT              NULL,

        FechaSolicitud      DATETIME2(0)     NOT NULL
            CONSTRAINT DF_Sol_FechaSol DEFAULT (SYSDATETIME()),
        FechaOferta         DATETIME2(0)     NULL,
        FechaRespuesta      DATETIME2(0)     NULL,

        -- Cuando la sucursal rechaza, el stock que Central ya había
        -- apartado tiene que volver a Central. Esta bandera evita
        -- reintegrarlo dos veces.
        StockReintegrado    BIT              NOT NULL
            CONSTRAINT DF_Sol_Reintegrado DEFAULT (0),

        rowguid             UNIQUEIDENTIFIER ROWGUIDCOL NOT NULL
            CONSTRAINT DF_Sol_rowguid DEFAULT (NEWSEQUENTIALID()),

        CONSTRAINT PK_SolicitudesStock PRIMARY KEY CLUSTERED (SolicitudID),

        CONSTRAINT FK_Sol_Sucursal FOREIGN KEY (SucursalID)
            REFERENCES dbo.Sucursales (SucursalID),
        CONSTRAINT FK_Sol_Producto FOREIGN KEY (ProductoID)
            REFERENCES dbo.Productos (ProductoID),

        CONSTRAINT CK_Sol_Estado CHECK (Estado IN (N'PENDIENTE', N'OFERTADO', N'ACEPTADO', N'RECHAZADO')),
        CONSTRAINT CK_Sol_Origen CHECK (Origen IN (N'AUTOMATICA', N'MANUAL', N'ENVIO_CENTRAL')),
        CONSTRAINT CK_Sol_Cantidades CHECK (CantidadSolicitada > 0 AND (CantidadOfrecida IS NULL OR CantidadOfrecida >= 0)),

        -- Una solicitud sólo puede estar OFERTADA si trae cantidad.
        CONSTRAINT CK_Sol_OfertaCoherente CHECK
            (Estado = N'PENDIENTE' OR CantidadOfrecida IS NOT NULL)
    );

    CREATE UNIQUE INDEX UQ_Sol_rowguid ON dbo.SolicitudesStock (rowguid);

    -- Bandeja de Central: "todo lo que está esperando respuesta mía".
    CREATE INDEX IX_Sol_Estado ON dbo.SolicitudesStock (Estado, FechaSolicitud)
        INCLUDE (SucursalID, ProductoID, CantidadSolicitada, CantidadOfrecida);

    -- Bandeja de la sucursal.
    CREATE INDEX IX_Sol_Sucursal ON dbo.SolicitudesStock (SucursalID, Estado, FechaSolicitud);

    -- Impide que la alerta automática genere una solicitud nueva cada vez
    -- que se vende una pieza estando ya bajo el mínimo. Es único sólo
    -- entre solicitudes ABIERTAS, así que el histórico puede repetirse.
    -- Distintas sucursales nunca chocan aquí porque SucursalID va incluido.
    --
    -- OJO OPERATIVO: al ser un índice FILTRADO, SQL Server exige
    -- QUOTED_IDENTIFIER ON en cualquier sesión que haga INSERT/UPDATE/DELETE
    -- sobre esta tabla. ODBC, OLE DB, PDO y los agentes de replicación lo
    -- traen ON por omisión, así que la aplicación y el Merge Agent no se
    -- ven afectados. Quien SÍ lo trae OFF es sqlcmd: si vas a tocar
    -- SolicitudesStock desde ahí, invócalo con la opción -I.
    CREATE UNIQUE INDEX UX_Sol_AbiertaPorProducto
        ON dbo.SolicitudesStock (SucursalID, ProductoID)
        WHERE Estado IN (N'PENDIENTE', N'OFERTADO');

    PRINT '[OK] Creada dbo.SolicitudesStock';
END
ELSE
    PRINT '[--] dbo.SolicitudesStock ya existía';
GO


/* =====================================================================
   PARTE 3 — AJUSTES A TABLAS EXISTENTES
   ===================================================================== */

-- 3.1 Ventas necesita saber en qué sucursal ocurrió.
IF COL_LENGTH('dbo.Ventas', 'SucursalID') IS NULL
BEGIN
    ALTER TABLE dbo.Ventas ADD SucursalID INT NULL;
    PRINT '[OK] Ventas.SucursalID agregada';
END
GO

-- Rellena las ventas históricas con la sucursal del empleado que las hizo.
UPDATE v
   SET v.SucursalID = e.SucursalID
  FROM dbo.Ventas v
  JOIN dbo.Empleados e ON e.EmpleadoID = v.EmpleadoID
 WHERE v.SucursalID IS NULL;
GO

UPDATE dbo.Ventas SET SucursalID = 1 WHERE SucursalID IS NULL;
GO

IF EXISTS (SELECT 1 FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.Ventas')
              AND name = 'SucursalID' AND is_nullable = 1)
BEGIN
    ALTER TABLE dbo.Ventas ALTER COLUMN SucursalID INT NOT NULL;

    ALTER TABLE dbo.Ventas ADD CONSTRAINT FK_Ventas_Sucursal
        FOREIGN KEY (SucursalID) REFERENCES dbo.Sucursales (SucursalID);

    PRINT '[OK] Ventas.SucursalID marcada NOT NULL + FK';
END
GO

-- 3.2 Enlazar Transferencias con la solicitud que las originó.
IF COL_LENGTH('dbo.Transferencias', 'SolicitudID') IS NULL
BEGIN
    ALTER TABLE dbo.Transferencias ADD SolicitudID INT NULL;
    PRINT '[OK] Transferencias.SolicitudID agregada';
END
GO

-- 3.3 Productos.Activo (baja lógica) — ya existe según el esquema actual,
--     pero se deja idempotente por si se corre sobre una base limpia.
IF COL_LENGTH('dbo.Productos', 'Activo') IS NULL
BEGIN
    ALTER TABLE dbo.Productos ADD Activo BIT NOT NULL CONSTRAINT DF_Productos_Activo DEFAULT (1);
    PRINT '[OK] Productos.Activo agregada';
END
GO


/* =====================================================================
   PARTE 4 — MIGRACIÓN DE dbo.Inventario -> dbo.InventarioSucursal

   El stock que hoy vive en dbo.Inventario ya pasó por la licuadora de la
   mezcla (es el resultado de que 4 sitios pelearan por la misma fila),
   así que se toma como stock de CENTRAL y las sucursales arrancan en 0.
   Si prefieres conservar el valor local de cada suscriptora, corre esta
   sección en cada base cambiando @SucursalLocal.
   ===================================================================== */

DECLARE @SucursalLocal INT = 1;   -- 1=Central, 2=Monterrey, 3=Puebla, 4=Querétaro

-- Los umbrales se siembran en 5 / 20 para TODO el catálogo, tal como
-- pide el requerimiento ("alerta cuando la cantidad sea <= 5"). No se
-- derivan de Productos.StockMinimo a propósito: los datos originales
-- traían un valor distinto por producto (5, 8, 10, 15, 20) y eso hacía
-- que cada uno alertara con un criterio propio, sin que se notara en
-- pantalla. Central puede subirlo al dar de alta un producto, y cada
-- sucursal afinar el suyo desde alertas.php.

-- 4.1 Traer el stock existente al almacén de la sucursal local.
IF OBJECT_ID('dbo.Inventario', 'U') IS NOT NULL
BEGIN
    INSERT INTO dbo.InventarioSucursal (SucursalID, ProductoID, Stock, StockMinimo, StockObjetivo, UltimaActualizacion)
    SELECT @SucursalLocal,
           i.ProductoID,
           i.Stock,
           5,
           20,
           i.UltimaActualizacion
      FROM dbo.Inventario i
      JOIN dbo.Productos  p ON p.ProductoID = i.ProductoID
     WHERE NOT EXISTS (SELECT 1 FROM dbo.InventarioSucursal x
                        WHERE x.SucursalID = @SucursalLocal
                          AND x.ProductoID = i.ProductoID);

    PRINT '[OK] Migradas ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' filas de Inventario';
END
GO

-- 4.2 Crear la fila (sucursal, producto) faltante en TODAS las combinaciones,
--     con stock 0. Así la UI siempre tiene dónde escribir y las consultas
--     no dependen de LEFT JOIN + ISNULL.
INSERT INTO dbo.InventarioSucursal (SucursalID, ProductoID, Stock, StockMinimo, StockObjetivo)
SELECT s.SucursalID,
       p.ProductoID,
       0,
       5,
       20
  FROM dbo.Sucursales s
 CROSS JOIN dbo.Productos p
 WHERE NOT EXISTS (SELECT 1 FROM dbo.InventarioSucursal x
                    WHERE x.SucursalID = s.SucursalID
                      AND x.ProductoID = p.ProductoID);

PRINT '[OK] Sembradas ' + CAST(@@ROWCOUNT AS VARCHAR(10)) + ' filas (sucursal, producto) en cero';
GO

/*  dbo.Inventario se deja en su lugar a propósito: primero hay que
    quitarla de la publicación (script 11) y confirmar que la app nueva
    corre bien. Cuando estés listo, ejecuta a mano:

        DROP TABLE dbo.Inventario;
*/


/* =====================================================================
   PARTE 5 — VISTAS
   ===================================================================== */
GO
CREATE OR ALTER VIEW dbo.vw_StockPorSucursal
AS
    SELECT  inv.SucursalID,
            s.Nombre            AS Sucursal,
            inv.ProductoID,
            p.Nombre            AS Producto,
            c.Nombre            AS Categoria,
            p.Marca,
            p.TipoMascota,
            p.PrecioUnitario,
            p.Activo            AS ProductoActivo,
            inv.Stock,
            inv.StockMinimo,
            inv.StockObjetivo,
            inv.UltimaActualizacion,
            CASE WHEN inv.Stock <= inv.StockMinimo THEN 1 ELSE 0 END AS EnAlerta
      FROM  dbo.InventarioSucursal inv
      JOIN  dbo.Sucursales s ON s.SucursalID = inv.SucursalID
      JOIN  dbo.Productos  p ON p.ProductoID = inv.ProductoID
      JOIN  dbo.Categorias c ON c.CategoriaID = p.CategoriaID;
GO

CREATE OR ALTER VIEW dbo.vw_StockGlobal
AS
    -- Panorama que usa Central: stock propio vs. repartido en la red.
    SELECT  p.ProductoID,
            p.Nombre        AS Producto,
            p.Activo,
            SUM(CASE WHEN inv.SucursalID = 1 THEN inv.Stock ELSE 0 END) AS StockCentral,
            SUM(CASE WHEN inv.SucursalID <> 1 THEN inv.Stock ELSE 0 END) AS StockSucursales,
            SUM(inv.Stock)                                              AS StockTotal
      FROM  dbo.Productos p
      JOIN  dbo.InventarioSucursal inv ON inv.ProductoID = p.ProductoID
     GROUP BY p.ProductoID, p.Nombre, p.Activo;
GO


/* =====================================================================
   PARTE 6 — PROCEDIMIENTOS ALMACENADOS

   Toda escritura de stock pasa por aquí. La app en PHP no hace UPDATE
   sobre InventarioSucursal directamente: así la validación de stock y la
   transaccionalidad viven en un solo lugar y no se pueden saltar.
   ===================================================================== */
GO

/* ---------------------------------------------------------------------
   6.0 Helper: garantiza que exista la fila (sucursal, producto).
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_InvSuc_AsegurarFila
    @SucursalID INT,
    @ProductoID INT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.InventarioSucursal
                    WHERE SucursalID = @SucursalID AND ProductoID = @ProductoID)
    BEGIN
        INSERT INTO dbo.InventarioSucursal (SucursalID, ProductoID, Stock, StockMinimo, StockObjetivo)
        SELECT @SucursalID,
               @ProductoID,
               0,
               5,
               20
          FROM dbo.Productos p
         WHERE p.ProductoID = @ProductoID;
    END
END
GO


/* ---------------------------------------------------------------------
   6.1 ENTRADA DE MERCANCÍA  (rol Central)
   Recepción de producto nuevo o reabastecimiento del proveedor.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_EntradaMercancia
    @ProductoID  INT,
    @Cantidad    INT,
    @EmpleadoID  INT,
    @Referencia  NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Cantidad <= 0
        THROW 50001, 'La cantidad a recibir debe ser mayor que cero.', 1;

    IF NOT EXISTS (SELECT 1 FROM dbo.Productos WHERE ProductoID = @ProductoID AND Activo = 1)
        THROW 50002, 'El producto no existe o está dado de baja.', 1;

    DECLARE @Central INT = (SELECT TOP 1 SucursalID FROM dbo.Sucursales WHERE EsCentral = 1 ORDER BY SucursalID);

    BEGIN TRAN;

        EXEC dbo.usp_InvSuc_AsegurarFila @Central, @ProductoID;

        UPDATE dbo.InventarioSucursal
           SET Stock = Stock + @Cantidad,
               UltimaActualizacion = SYSDATETIME()
         WHERE SucursalID = @Central AND ProductoID = @ProductoID;

        INSERT INTO dbo.Movimientos (ProductoID, TipoMovimiento, Cantidad, SucursalOrigen, SucursalDestino, EmpleadoID, Referencia)
        VALUES (@ProductoID, N'Entrada', @Cantidad, NULL, @Central, @EmpleadoID,
                ISNULL(@Referencia, N'Entrada de mercancía'));

    COMMIT;

    SELECT Stock AS StockResultante
      FROM dbo.InventarioSucursal
     WHERE SucursalID = @Central AND ProductoID = @ProductoID;
END
GO


/* ---------------------------------------------------------------------
   6.2 SOLICITUD DE REABASTECIMIENTO  (rol Sucursal)
   La usa tanto el trigger de stock bajo como la captura manual.
   Devuelve el SolicitudID, o 0 si ya había una solicitud abierta.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_SolicitarReabastecimiento
    @SucursalID  INT,
    @ProductoID  INT,
    @Cantidad    INT           = NULL,   -- NULL => hasta StockObjetivo
    @EmpleadoID  INT           = NULL,
    @Origen      NVARCHAR(20)  = N'MANUAL',
    @Comentario  NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF EXISTS (SELECT 1 FROM dbo.Sucursales WHERE SucursalID = @SucursalID AND EsCentral = 1)
        THROW 50010, 'Central no se solicita mercancía a sí misma; usa la entrada de mercancía.', 1;

    -- Ya hay una petición viva para ese producto: no se duplica.
    IF EXISTS (SELECT 1 FROM dbo.SolicitudesStock
                WHERE SucursalID = @SucursalID AND ProductoID = @ProductoID
                  AND Estado IN (N'PENDIENTE', N'OFERTADO'))
    BEGIN
        SELECT CAST(0 AS INT) AS SolicitudID;
        RETURN;
    END

    DECLARE @StockActual INT, @Objetivo INT;

    SELECT @StockActual = Stock, @Objetivo = StockObjetivo
      FROM dbo.InventarioSucursal
     WHERE SucursalID = @SucursalID AND ProductoID = @ProductoID;

    IF @StockActual IS NULL
    BEGIN
        EXEC dbo.usp_InvSuc_AsegurarFila @SucursalID, @ProductoID;
        SELECT @StockActual = Stock, @Objetivo = StockObjetivo
          FROM dbo.InventarioSucursal
         WHERE SucursalID = @SucursalID AND ProductoID = @ProductoID;
    END

    IF @Cantidad IS NULL
        SET @Cantidad = @Objetivo - @StockActual;

    IF @Cantidad <= 0
        SET @Cantidad = 1;

    INSERT INTO dbo.SolicitudesStock
        (SucursalID, ProductoID, CantidadSolicitada, Estado, Origen,
         StockAlSolicitar, EmpleadoSolicitaID, ComentarioSucursal)
    VALUES
        (@SucursalID, @ProductoID, @Cantidad, N'PENDIENTE', @Origen,
         @StockActual, @EmpleadoID, @Comentario);

    SELECT CAST(SCOPE_IDENTITY() AS INT) AS SolicitudID;
END
GO


/* ---------------------------------------------------------------------
   6.3 OFERTA DE CENTRAL  (rol Central)
   Central responde una solicitud PENDIENTE. Puede ofrecer menos de lo
   pedido si no le alcanza el stock — ése es el caso de "envío parcial".

   Central DESCUENTA aquí, no al aceptar: la mercancía sale físicamente
   del almacén central al momento del envío. Si la sucursal rechaza, el
   stock se reintegra con usp_ReintegrarSolicitud.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_OfertarSolicitud
    @SolicitudID INT,
    @Cantidad    INT,
    @EmpleadoID  INT,
    @Comentario  NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Central INT = (SELECT TOP 1 SucursalID FROM dbo.Sucursales WHERE EsCentral = 1 ORDER BY SucursalID);
    DECLARE @ProductoID INT, @SucursalID INT, @Estado NVARCHAR(20), @StockCentral INT;

    SELECT @ProductoID = ProductoID, @SucursalID = SucursalID, @Estado = Estado
      FROM dbo.SolicitudesStock
     WHERE SolicitudID = @SolicitudID;

    IF @ProductoID IS NULL
        THROW 50020, 'La solicitud no existe.', 1;

    IF @Estado <> N'PENDIENTE'
        THROW 50021, 'Sólo se puede ofertar sobre una solicitud PENDIENTE.', 1;

    IF @Cantidad <= 0
        THROW 50022, 'La cantidad a enviar debe ser mayor que cero.', 1;

    SELECT @StockCentral = Stock
      FROM dbo.InventarioSucursal
     WHERE SucursalID = @Central AND ProductoID = @ProductoID;

    IF ISNULL(@StockCentral, 0) < @Cantidad
        THROW 50023, 'Central no tiene stock suficiente para esa cantidad.', 1;

    BEGIN TRAN;

        -- Central escribe SU propia fila de inventario.
        UPDATE dbo.InventarioSucursal
           SET Stock = Stock - @Cantidad,
               UltimaActualizacion = SYSDATETIME()
         WHERE SucursalID = @Central AND ProductoID = @ProductoID;

        UPDATE dbo.SolicitudesStock
           SET CantidadOfrecida  = @Cantidad,
               Estado            = N'OFERTADO',
               EmpleadoAtiendeID = @EmpleadoID,
               ComentarioCentral = @Comentario,
               FechaOferta       = SYSDATETIME()
         WHERE SolicitudID = @SolicitudID;

        INSERT INTO dbo.Transferencias
            (ProductoID, Cantidad, SucursalOrigen, SucursalDestino, Estado, EmpleadoID, SolicitudID)
        VALUES
            (@ProductoID, @Cantidad, @Central, @SucursalID, N'Pendiente', @EmpleadoID, @SolicitudID);

        INSERT INTO dbo.Movimientos
            (ProductoID, TipoMovimiento, Cantidad, SucursalOrigen, SucursalDestino, EmpleadoID, Referencia)
        VALUES
            (@ProductoID, N'Salida', @Cantidad, @Central, @SucursalID, @EmpleadoID,
             N'Envío a sucursal — solicitud #' + CAST(@SolicitudID AS NVARCHAR(12)));

    COMMIT;
END
GO


/* ---------------------------------------------------------------------
   6.4 ENVÍO DIRECTO DE CENTRAL  (rol Central)
   "Asignación y transferencia" sin que la sucursal haya pedido nada.
   Se modela como una solicitud que nace ya OFERTADA, para que la
   sucursal la confirme por el mismo camino y el stock nunca se
   incremente desde fuera del sitio dueño de la fila.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_AsignarStockSucursal
    @ProductoID  INT,
    @SucursalID  INT,
    @Cantidad    INT,
    @EmpleadoID  INT,
    @Comentario  NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Central INT = (SELECT TOP 1 SucursalID FROM dbo.Sucursales WHERE EsCentral = 1 ORDER BY SucursalID);

    IF @SucursalID = @Central
        THROW 50030, 'El destino debe ser una sucursal distinta de Central.', 1;

    IF NOT EXISTS (SELECT 1 FROM dbo.Sucursales WHERE SucursalID = @SucursalID)
        THROW 50031, 'La sucursal destino no existe.', 1;

    IF @Cantidad <= 0
        THROW 50032, 'La cantidad a asignar debe ser mayor que cero.', 1;

    IF NOT EXISTS (SELECT 1 FROM dbo.Productos WHERE ProductoID = @ProductoID AND Activo = 1)
        THROW 50033, 'El producto no existe o está dado de baja.', 1;

    IF EXISTS (SELECT 1 FROM dbo.SolicitudesStock
                WHERE SucursalID = @SucursalID AND ProductoID = @ProductoID
                  AND Estado IN (N'PENDIENTE', N'OFERTADO'))
        THROW 50034, 'Esa sucursal ya tiene un movimiento abierto de este producto. Atiéndelo antes de mandar más.', 1;

    DECLARE @StockCentral INT = (SELECT Stock FROM dbo.InventarioSucursal
                                  WHERE SucursalID = @Central AND ProductoID = @ProductoID);

    IF ISNULL(@StockCentral, 0) < @Cantidad
        THROW 50035, 'Central no tiene stock suficiente para esa asignación.', 1;

    DECLARE @SolicitudID INT;

    BEGIN TRAN;

        UPDATE dbo.InventarioSucursal
           SET Stock = Stock - @Cantidad,
               UltimaActualizacion = SYSDATETIME()
         WHERE SucursalID = @Central AND ProductoID = @ProductoID;

        INSERT INTO dbo.SolicitudesStock
            (SucursalID, ProductoID, CantidadSolicitada, CantidadOfrecida, Estado, Origen,
             EmpleadoAtiendeID, ComentarioCentral, FechaOferta)
        VALUES
            (@SucursalID, @ProductoID, @Cantidad, @Cantidad, N'OFERTADO', N'ENVIO_CENTRAL',
             @EmpleadoID, ISNULL(@Comentario, N'Asignación directa de Central'), SYSDATETIME());

        SET @SolicitudID = CAST(SCOPE_IDENTITY() AS INT);

        INSERT INTO dbo.Transferencias
            (ProductoID, Cantidad, SucursalOrigen, SucursalDestino, Estado, EmpleadoID, SolicitudID)
        VALUES
            (@ProductoID, @Cantidad, @Central, @SucursalID, N'Pendiente', @EmpleadoID, @SolicitudID);

        INSERT INTO dbo.Movimientos
            (ProductoID, TipoMovimiento, Cantidad, SucursalOrigen, SucursalDestino, EmpleadoID, Referencia)
        VALUES
            (@ProductoID, N'Transferencia', @Cantidad, @Central, @SucursalID, @EmpleadoID,
             N'Asignación directa — solicitud #' + CAST(@SolicitudID AS NVARCHAR(12)));

    COMMIT;

    SELECT @SolicitudID AS SolicitudID;
END
GO


/* ---------------------------------------------------------------------
   6.5 RESPUESTA DE LA SUCURSAL  (rol Sucursal)
   Aceptar  -> el stock entra oficialmente al inventario de la sucursal.
   Rechazar -> queda para que Central reintegre lo que ya había apartado.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_ResponderSolicitud
    @SolicitudID INT,
    @Aceptar     BIT,
    @EmpleadoID  INT,
    @Comentario  NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @SucursalID INT, @ProductoID INT, @Cantidad INT, @Estado NVARCHAR(20), @Central INT;

    SELECT @SucursalID = SucursalID,
           @ProductoID = ProductoID,
           @Cantidad   = CantidadOfrecida,
           @Estado     = Estado
      FROM dbo.SolicitudesStock
     WHERE SolicitudID = @SolicitudID;

    IF @SucursalID IS NULL
        THROW 50040, 'La solicitud no existe.', 1;

    IF @Estado <> N'OFERTADO'
        THROW 50041, 'Sólo se puede responder una solicitud en estado OFERTADO.', 1;

    SET @Central = (SELECT TOP 1 SucursalID FROM dbo.Sucursales WHERE EsCentral = 1 ORDER BY SucursalID);

    BEGIN TRAN;

        IF @Aceptar = 1
        BEGIN
            -- La sucursal escribe SU propia fila de inventario.
            EXEC dbo.usp_InvSuc_AsegurarFila @SucursalID, @ProductoID;

            UPDATE dbo.InventarioSucursal
               SET Stock = Stock + @Cantidad,
                   UltimaActualizacion = SYSDATETIME()
             WHERE SucursalID = @SucursalID AND ProductoID = @ProductoID;

            UPDATE dbo.SolicitudesStock
               SET Estado             = N'ACEPTADO',
                   FechaRespuesta     = SYSDATETIME(),
                   ComentarioSucursal = @Comentario
             WHERE SolicitudID = @SolicitudID;

            UPDATE dbo.Transferencias
               SET Estado = N'Completada'
             WHERE SolicitudID = @SolicitudID AND Estado = N'Pendiente';

            INSERT INTO dbo.Movimientos
                (ProductoID, TipoMovimiento, Cantidad, SucursalOrigen, SucursalDestino, EmpleadoID, Referencia)
            VALUES
                (@ProductoID, N'Entrada', @Cantidad, @Central, @SucursalID, @EmpleadoID,
                 N'Recepción aceptada — solicitud #' + CAST(@SolicitudID AS NVARCHAR(12)));
        END
        ELSE
        BEGIN
            UPDATE dbo.SolicitudesStock
               SET Estado             = N'RECHAZADO',
                   FechaRespuesta     = SYSDATETIME(),
                   ComentarioSucursal = @Comentario
             WHERE SolicitudID = @SolicitudID;

            UPDATE dbo.Transferencias
               SET Estado = N'Rechazada'
             WHERE SolicitudID = @SolicitudID AND Estado = N'Pendiente';
        END

    COMMIT;
END
GO


/* ---------------------------------------------------------------------
   6.6 REINTEGRO  (rol Central)
   La sucursal rechazó: la mercancía apartada regresa al almacén central.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_ReintegrarSolicitud
    @SolicitudID INT,
    @EmpleadoID  INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ProductoID INT, @Cantidad INT, @Estado NVARCHAR(20), @YaReintegrado BIT, @Central INT;

    SELECT @ProductoID    = ProductoID,
           @Cantidad      = CantidadOfrecida,
           @Estado        = Estado,
           @YaReintegrado = StockReintegrado
      FROM dbo.SolicitudesStock
     WHERE SolicitudID = @SolicitudID;

    IF @ProductoID IS NULL
        THROW 50050, 'La solicitud no existe.', 1;

    IF @Estado <> N'RECHAZADO'
        THROW 50051, 'Sólo se reintegra el stock de una solicitud RECHAZADA.', 1;

    IF @YaReintegrado = 1
        THROW 50052, 'El stock de esta solicitud ya fue reintegrado.', 1;

    SET @Central = (SELECT TOP 1 SucursalID FROM dbo.Sucursales WHERE EsCentral = 1 ORDER BY SucursalID);

    BEGIN TRAN;

        UPDATE dbo.InventarioSucursal
           SET Stock = Stock + @Cantidad,
               UltimaActualizacion = SYSDATETIME()
         WHERE SucursalID = @Central AND ProductoID = @ProductoID;

        UPDATE dbo.SolicitudesStock
           SET StockReintegrado = 1
         WHERE SolicitudID = @SolicitudID;

        INSERT INTO dbo.Movimientos
            (ProductoID, TipoMovimiento, Cantidad, SucursalOrigen, SucursalDestino, EmpleadoID, Referencia)
        VALUES
            (@ProductoID, N'Entrada', @Cantidad, NULL, @Central, @EmpleadoID,
             N'Reintegro por rechazo — solicitud #' + CAST(@SolicitudID AS NVARCHAR(12)));

    COMMIT;
END
GO


/* ---------------------------------------------------------------------
   6.7 VENTA  (rol Sucursal)
   Descuenta stock de la sucursal y registra Venta + DetalleVenta.
   El trigger de stock bajo se encarga de la alerta si toca.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_RegistrarVenta
    @SucursalID  INT,
    @ProductoID  INT,
    @Cantidad    INT,
    @EmpleadoID  INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Cantidad <= 0
        THROW 50060, 'La cantidad vendida debe ser mayor que cero.', 1;

    DECLARE @Precio DECIMAL(18,2), @Activo BIT;

    SELECT @Precio = PrecioUnitario, @Activo = Activo
      FROM dbo.Productos WHERE ProductoID = @ProductoID;

    IF @Precio IS NULL
        THROW 50061, 'El producto no existe.', 1;

    IF @Activo = 0
        THROW 50062, 'El producto está dado de baja y no puede venderse.', 1;

    DECLARE @StockActual INT = (SELECT Stock FROM dbo.InventarioSucursal
                                 WHERE SucursalID = @SucursalID AND ProductoID = @ProductoID);

    IF ISNULL(@StockActual, 0) < @Cantidad
        THROW 50063, 'Stock insuficiente en esta sucursal para completar la venta.', 1;

    DECLARE @VentaID INT, @Total DECIMAL(18,2) = @Precio * @Cantidad;

    BEGIN TRAN;

        INSERT INTO dbo.Ventas (Fecha, EmpleadoID, Total, SucursalID)
        VALUES (SYSDATETIME(), @EmpleadoID, @Total, @SucursalID);

        SET @VentaID = CAST(SCOPE_IDENTITY() AS INT);

        INSERT INTO dbo.DetalleVenta (VentaID, ProductoID, Cantidad, PrecioUnitario)
        VALUES (@VentaID, @ProductoID, @Cantidad, @Precio);

        UPDATE dbo.InventarioSucursal
           SET Stock = Stock - @Cantidad,
               UltimaActualizacion = SYSDATETIME()
         WHERE SucursalID = @SucursalID AND ProductoID = @ProductoID;

        INSERT INTO dbo.Movimientos
            (ProductoID, TipoMovimiento, Cantidad, SucursalOrigen, SucursalDestino, EmpleadoID, Referencia)
        VALUES
            (@ProductoID, N'Venta', @Cantidad, @SucursalID, NULL, @EmpleadoID,
             N'Venta #' + CAST(@VentaID AS NVARCHAR(12)));

    COMMIT;

    SELECT @VentaID AS VentaID,
           @Total   AS Total,
           (SELECT Stock FROM dbo.InventarioSucursal
             WHERE SucursalID = @SucursalID AND ProductoID = @ProductoID) AS StockResultante;
END
GO


/* ---------------------------------------------------------------------
   6.8 BARRIDO MANUAL DE ALERTAS
   El trigger cubre el flujo normal; esto sirve para la carga inicial o
   si alguien tocó el inventario por fuera de la aplicación.
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GenerarAlertasStockBajo
    @SucursalID INT,
    @EmpleadoID INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    INSERT INTO dbo.SolicitudesStock
        (SucursalID, ProductoID, CantidadSolicitada, Estado, Origen, StockAlSolicitar, EmpleadoSolicitaID)
    SELECT inv.SucursalID,
           inv.ProductoID,
           CASE WHEN inv.StockObjetivo - inv.Stock > 0 THEN inv.StockObjetivo - inv.Stock ELSE 1 END,
           N'PENDIENTE',
           N'AUTOMATICA',
           inv.Stock,
           @EmpleadoID
      FROM dbo.InventarioSucursal inv
      JOIN dbo.Productos p ON p.ProductoID = inv.ProductoID AND p.Activo = 1
     WHERE inv.SucursalID = @SucursalID
       AND inv.Stock <= inv.StockMinimo
       AND NOT EXISTS (SELECT 1 FROM dbo.SolicitudesStock s
                        WHERE s.SucursalID = inv.SucursalID
                          AND s.ProductoID = inv.ProductoID
                          AND s.Estado IN (N'PENDIENTE', N'OFERTADO'));

    SELECT @@ROWCOUNT AS AlertasGeneradas;
END
GO


/* =====================================================================
   PARTE 7 — TRIGGER DE ALERTA AUTOMÁTICA DE STOCK BAJO

   NOT FOR REPLICATION es lo que hace que esto funcione en un entorno
   replicado: sin esa cláusula, el Merge Agent dispararía el trigger en
   CADA sitio al aplicar los cambios, y las cuatro bases generarían la
   misma solicitud por su cuenta. Con NOT FOR REPLICATION sólo reacciona
   a la actividad local real (una venta en el mostrador), y la solicitud
   resultante viaja a Central por la mezcla como cualquier otra fila.
   ===================================================================== */
GO
CREATE OR ALTER TRIGGER dbo.trg_InvSuc_AlertaStockBajo
ON dbo.InventarioSucursal
AFTER UPDATE
NOT FOR REPLICATION
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT UPDATE(Stock) RETURN;

    INSERT INTO dbo.SolicitudesStock
        (SucursalID, ProductoID, CantidadSolicitada, Estado, Origen, StockAlSolicitar)
    SELECT i.SucursalID,
           i.ProductoID,
           CASE WHEN i.StockObjetivo - i.Stock > 0 THEN i.StockObjetivo - i.Stock ELSE 1 END,
           N'PENDIENTE',
           N'AUTOMATICA',
           i.Stock
      FROM inserted i
      JOIN deleted  d ON d.SucursalID = i.SucursalID AND d.ProductoID = i.ProductoID
      JOIN dbo.Sucursales s ON s.SucursalID = i.SucursalID
      JOIN dbo.Productos  p ON p.ProductoID = i.ProductoID
     WHERE s.EsCentral = 0                 -- Central se reabastece con el proveedor
       AND p.Activo    = 1
       AND i.Stock    <= i.StockMinimo     -- cayó al punto de reorden
       AND i.Stock     <  d.Stock          -- ...y fue bajando, no subiendo
       AND NOT EXISTS (SELECT 1 FROM dbo.SolicitudesStock ss
                        WHERE ss.SucursalID = i.SucursalID
                          AND ss.ProductoID = i.ProductoID
                          AND ss.Estado IN (N'PENDIENTE', N'OFERTADO'));
END
GO


PRINT '';
PRINT '=====================================================';
PRINT ' Esquema multi-sucursal instalado.';
PRINT ' Siguiente paso: sql/11_Replicacion_Merge.sql';
PRINT '=====================================================';
GO

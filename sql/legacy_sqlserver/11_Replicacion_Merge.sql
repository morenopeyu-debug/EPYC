/* =====================================================================
   11_Replicacion_Merge.sql
   Publica las tablas nuevas en la publicación de mezcla 'epyc_central'
   y corrige los problemas de replicación del esquema anterior.

   EJECUTAR EN: BD_Central (el Publicador), con una cuenta miembro de
                sysadmin o de db_owner sobre la base publicada.

   ---------------------------------------------------------------------
   QUÉ ARREGLA ESTE SCRIPT
   ---------------------------------------------------------------------
   1. Publica InventarioSucursal y SolicitudesStock.
   2. Retira dbo.Inventario de la publicación (su PK de una sola columna
      es justo la que provoca los conflictos).
   3. Activa el rango automático de identidades en las tablas donde las
      sucursales insertan. Sin esto, Monterrey y Puebla generan el mismo
      VentaID/MovimientoID y chocan en la primera sincronización.
   4. Enciende seguimiento a nivel COLUMNA en SolicitudesStock, para que
      cuando Central escriba Estado/CantidadOfrecida y la sucursal escriba
      ComentarioSucursal, la mezcla no lo tome como conflicto de fila.

   IMPORTANTE: agregar artículos invalida el snapshot. Al final hay que
   regenerarlo y dejar que cada suscriptora se reinicialice. Programa
   esto en una ventana de mantenimiento, no a media jornada.
   ===================================================================== */

USE BD_Central;
GO

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

DECLARE @publicacion SYSNAME = N'epyc_central';

/* ---------------------------------------------------------------------
   PASO 0 — Verificación previa
   --------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sysmergepublications WHERE name = @publicacion)
BEGIN
    RAISERROR('No existe la publicación %s en esta base. Revisa el nombre con: SELECT name FROM sysmergepublications;', 16, 1, @publicacion);
    RETURN;
END

PRINT '--- Artículos publicados ANTES del cambio ---';
SELECT a.name AS Articulo, a.column_tracking, a.identity_support
  FROM sysmergearticles a
  JOIN sysmergepublications p ON p.pubid = a.pubid
 WHERE p.name = @publicacion
 ORDER BY a.name;
GO


/* =====================================================================
   PASO 1 — Asegurar que la publicación replique cambios de esquema

   Con esto activo, el ALTER TABLE del script 10 (Ventas.SucursalID,
   Transferencias.SolicitudID) viaja solo a las tres suscriptoras.
   ===================================================================== */
EXEC sp_changemergepublication
     @publication  = N'epyc_central',
     @property     = N'replicate_ddl',
     @value        = 1;
GO
PRINT '[OK] replicate_ddl = 1';
GO


/* =====================================================================
   PASO 2 — Publicar dbo.InventarioSucursal

   Sin @column_tracking porque el conflicto real ya lo resolvió la PK
   compuesta: cada sitio escribe filas distintas. El resolutor por
   omisión (prioridad del suscriptor) queda como red de seguridad.

   Si algún día necesitas que dos sitios sumen sobre el MISMO renglón,
   el resolutor apropiado sería el aditivo — está comentado abajo.
   ===================================================================== */
IF NOT EXISTS (SELECT 1 FROM sysmergearticles a
                 JOIN sysmergepublications p ON p.pubid = a.pubid
                WHERE p.name = N'epyc_central' AND a.name = N'InventarioSucursal')
BEGIN
    EXEC sp_addmergearticle
         @publication               = N'epyc_central',
         @article                   = N'InventarioSucursal',
         @source_object             = N'InventarioSucursal',
         @source_owner              = N'dbo',
         @type                      = N'table',
         @column_tracking           = N'false',
         @subscriber_upload_options = 0,          -- bidireccional: la sucursal sube sus cambios
         @allow_interactive_resolver= N'false',
         @check_permissions         = 0,
         @force_invalidate_snapshot = 1,
         @force_reinit_subscription = 1;

    -- Resolutor aditivo (NO recomendado con PK compuesta; se deja documentado):
    -- EXEC sp_changemergearticle
    --      @publication = N'epyc_central', @article = N'InventarioSucursal',
    --      @property = N'article_resolver',
    --      @value = N'Microsoft SQL Server Additive Conflict Resolver',
    --      @resolver_info = N'Stock',
    --      @force_invalidate_snapshot = 1, @force_reinit_subscription = 1;

    PRINT '[OK] Artículo InventarioSucursal publicado';
END
ELSE
    PRINT '[--] InventarioSucursal ya estaba publicado';
GO


/* =====================================================================
   PASO 3 — Publicar dbo.SolicitudesStock

   Aquí SÍ va @column_tracking = 'true'. Es la única tabla del modelo
   donde dos sitios tocan la misma fila (Central pone CantidadOfrecida y
   Estado; la sucursal pone ComentarioSucursal y luego Estado). Con
   seguimiento por columna, la mezcla sólo pelea si ambos modificaron
   exactamente la misma columna, cosa que la máquina de estados evita.

   @identityrangemanagementoption = 'auto' reparte SolicitudID en rangos
   disjuntos: Central 1..100000, cada suscriptora su propio bloque de
   10000. Así dos sucursales nunca generan el mismo folio.
   ===================================================================== */
IF NOT EXISTS (SELECT 1 FROM sysmergearticles a
                 JOIN sysmergepublications p ON p.pubid = a.pubid
                WHERE p.name = N'epyc_central' AND a.name = N'SolicitudesStock')
BEGIN
    EXEC sp_addmergearticle
         @publication                   = N'epyc_central',
         @article                       = N'SolicitudesStock',
         @source_object                 = N'SolicitudesStock',
         @source_owner                  = N'dbo',
         @type                          = N'table',
         @column_tracking               = N'true',
         @subscriber_upload_options     = 0,
         @allow_interactive_resolver    = N'false',
         @check_permissions             = 0,
         @identityrangemanagementoption = N'auto',
         @pub_identity_range            = 100000,  -- bloque del Publicador
         @identity_range                = 10000,   -- bloque de cada Suscriptor
         @threshold                     = 80,      -- % consumido antes de pedir otro bloque
         @force_invalidate_snapshot     = 1,
         @force_reinit_subscription     = 1;

    PRINT '[OK] Artículo SolicitudesStock publicado (identity range auto)';
END
ELSE
    PRINT '[--] SolicitudesStock ya estaba publicado';
GO


/* =====================================================================
   PASO 4 — Rango de identidades en las tablas que YA estaban publicadas

   Ventas, Movimientos y Transferencias reciben inserciones desde las
   sucursales. Si su identidad no está particionada, dos sitios generan la
   misma llave y la fila perdedora se va al log de conflictos.

   OJO: Movimientos y Transferencias ya traían administración automática,
   pero con un rango de apenas 1000 valores por sitio —se agota en una
   temporada de trabajo normal y obliga al Merge Agent a repartir bloques
   nuevos todo el tiempo. Por eso el cursor NO filtra por identity_support:
   pasa por todas y deja los rangos en 100000 / 10000.
   ===================================================================== */
DECLARE @art SYSNAME;
DECLARE @tablas TABLE (nombre SYSNAME);

INSERT INTO @tablas (nombre) VALUES (N'Ventas'), (N'Movimientos'), (N'Transferencias');

DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT t.nombre
      FROM @tablas t
      JOIN sysmergearticles a ON a.name = t.nombre
      JOIN sysmergepublications p ON p.pubid = a.pubid
     WHERE p.name = N'epyc_central';

OPEN cur;
FETCH NEXT FROM cur INTO @art;

WHILE @@FETCH_STATUS = 0
BEGIN
    PRINT '  -> Configurando rango de identidad en ' + @art;

    EXEC sp_changemergearticle
         @publication = N'epyc_central', @article = @art,
         @property = N'identityrangemanagementoption', @value = N'auto',
         @force_invalidate_snapshot = 1, @force_reinit_subscription = 1;

    EXEC sp_changemergearticle
         @publication = N'epyc_central', @article = @art,
         @property = N'pub_identity_range', @value = 100000,
         @force_invalidate_snapshot = 1, @force_reinit_subscription = 1;

    EXEC sp_changemergearticle
         @publication = N'epyc_central', @article = @art,
         @property = N'identity_range', @value = 10000,
         @force_invalidate_snapshot = 1, @force_reinit_subscription = 1;

    EXEC sp_changemergearticle
         @publication = N'epyc_central', @article = @art,
         @property = N'threshold', @value = 80,
         @force_invalidate_snapshot = 1, @force_reinit_subscription = 1;

    FETCH NEXT FROM cur INTO @art;
END

CLOSE cur;
DEALLOCATE cur;
GO
PRINT '[OK] Rangos de identidad configurados';
GO


/* =====================================================================
   PASO 5 — Seguimiento por columna en el catálogo maestro

   Productos/Categorias/Proveedores los edita sólo Central, pero si
   alguna vez dos sitios tocan el mismo producto (por ejemplo, Central
   cambia el precio mientras alguien más corrige la marca), con
   seguimiento por columna ambos cambios sobreviven.
   ===================================================================== */
DECLARE @artc SYSNAME;

DECLARE curc CURSOR LOCAL FAST_FORWARD FOR
    SELECT a.name
      FROM sysmergearticles a
      JOIN sysmergepublications p ON p.pubid = a.pubid
     WHERE p.name = N'epyc_central'
       AND a.name IN (N'Productos', N'Categorias', N'Proveedores', N'Empleados')
       AND a.column_tracking = 0;

OPEN curc;
FETCH NEXT FROM curc INTO @artc;

WHILE @@FETCH_STATUS = 0
BEGIN
    PRINT '  -> column_tracking = true en ' + @artc;

    EXEC sp_changemergearticle
         @publication = N'epyc_central', @article = @artc,
         @property = N'column_tracking', @value = N'true',
         @force_invalidate_snapshot = 1, @force_reinit_subscription = 1;

    FETCH NEXT FROM curc INTO @artc;
END

CLOSE curc;
DEALLOCATE curc;
GO


/* =====================================================================
   PASO 6 — Retirar dbo.Inventario de la publicación

   Es la tabla defectuosa: PK de una sola columna, escrita por los cuatro
   sitios. Se saca de la publicación; la tabla física sigue ahí hasta que
   confirmes que la aplicación nueva funciona y la borres a mano.
   ===================================================================== */
IF EXISTS (SELECT 1 FROM sysmergearticles a
             JOIN sysmergepublications p ON p.pubid = a.pubid
            WHERE p.name = N'epyc_central' AND a.name = N'Inventario')
BEGIN
    EXEC sp_dropmergearticle
         @publication               = N'epyc_central',
         @article                   = N'Inventario',
         @force_invalidate_snapshot = 1,
         @force_reinit_subscription = 1;

    PRINT '[OK] Artículo Inventario retirado de la publicación';
END
ELSE
    PRINT '[--] Inventario no estaba publicado';
GO


/* =====================================================================
   PASO 7 — Regenerar el snapshot

   Las suscriptoras se reinicializarán en su próxima sincronización.
   Vigila el avance en el Monitor de Replicación.
   ===================================================================== */
EXEC sp_startpublication_snapshot @publication = N'epyc_central';
GO
PRINT '[OK] Generación de snapshot iniciada';
GO


/* =====================================================================
   PASO 8 — Verificación
   ===================================================================== */
PRINT '';
PRINT '--- Artículos publicados DESPUÉS del cambio ---';
SELECT a.name                AS Articulo,
       CASE a.column_tracking  WHEN 1 THEN 'columna' ELSE 'fila' END AS Seguimiento,
       CASE a.identity_support WHEN 1 THEN 'auto'    ELSE 'manual' END AS RangoIdentidad
  FROM sysmergearticles a
  JOIN sysmergepublications p ON p.pubid = a.pubid
 WHERE p.name = N'epyc_central'
 ORDER BY a.name;
GO

PRINT '';
PRINT '--- Suscripciones ---';
SELECT subscriber_server, db_name, subscription_type, status
  FROM sysmergesubscriptions
 WHERE subscriber_server IS NOT NULL;
GO

/* ---------------------------------------------------------------------
   CONSULTAS ÚTILES PARA EL DÍA A DÍA
   ---------------------------------------------------------------------

   -- ¿Hubo conflictos en la última mezcla?
   EXEC sp_showpendingchanges;

   SELECT * FROM MSmerge_conflicts_info ORDER BY conflict_time DESC;

   -- Conflictos concretos de la tabla vieja de inventario (deberían
   -- dejar de crecer una vez retirado el artículo):
   SELECT * FROM MSmerge_conflict_epyc_central_Inventario;

   -- Rango de identidad vigente en cada sitio:
   SELECT * FROM MSmerge_identity_range;

   -- Forzar una sincronización desde el suscriptor (línea de comandos):
   --   replmerg.exe -Publisher <SRV> -PublisherDB BD_Central
   --                -Publication epyc_central -Subscriber <SRV_SUC>
   --                -SubscriberDB BD_Monterrey -SubscriptionType 1
   --------------------------------------------------------------------- */

PRINT '';
PRINT '=====================================================';
PRINT ' Replicación actualizada.';
PRINT ' Espera a que las 3 suscriptoras se reinicialicen';
PRINT ' antes de usar la aplicación en modo distribuido.';
PRINT '=====================================================';
GO

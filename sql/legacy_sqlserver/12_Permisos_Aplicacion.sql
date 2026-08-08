/* =====================================================================
   12_Permisos_Aplicacion.sql
   Permisos mínimos para la cuenta con la que se conecta la aplicación.

   EJECUTAR EN: cada base (BD_Central, BD_Monterrey, BD_Puebla,
                BD_Queretaro) ajustando @usuario si en esa sede el login
                se llama distinto (link_user en las suscriptoras).

   La aplicación NO necesita permisos de DDL. Todas las escrituras de
   stock pasan por procedimientos almacenados, así que basta con:
     - lectura sobre las tablas y vistas
     - EXECUTE sobre los procedimientos usp_*
     - escritura directa sólo donde la app la usa (niveles de reorden)
   ===================================================================== */

USE BD_Central;   -- <<< cambia según la base donde lo ejecutes
GO

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
GO

DECLARE @usuario SYSNAME = N'link_user';   -- <<< 'link_user' en las suscriptoras
DECLARE @sql NVARCHAR(MAX) = N'';

-- El usuario de base debe existir; si no, se crea a partir del login.
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @usuario)
BEGIN
    IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @usuario)
    BEGIN
        SET @sql = N'CREATE USER ' + QUOTENAME(@usuario) + N' FOR LOGIN ' + QUOTENAME(@usuario) + N';';
        EXEC sp_executesql @sql;
        PRINT '[OK] Usuario de base creado: ' + @usuario;
    END
    ELSE
    BEGIN
        RAISERROR('No existe el login %s en el servidor. Créalo antes de correr este script.', 16, 1, @usuario);
        RETURN;
    END
END

-- Lectura general (catálogo, inventario, bitácoras, vistas).
SET @sql = N'ALTER ROLE db_datareader ADD MEMBER ' + QUOTENAME(@usuario) + N';';
EXEC sp_executesql @sql;

-- Escritura directa: la app sólo la ejerce sobre Productos (catálogo,
-- desde Central) y sobre los umbrales de InventarioSucursal. El resto
-- del movimiento de stock entra por los procedimientos.
SET @sql = N'ALTER ROLE db_datawriter ADD MEMBER ' + QUOTENAME(@usuario) + N';';
EXEC sp_executesql @sql;

PRINT '[OK] Roles de lectura/escritura asignados';
GO


/* Permiso de ejecución sobre los procedimientos de la aplicación. */
DECLARE @usuario SYSNAME = N'link_user';   -- <<< mismo valor que arriba
DECLARE @sql NVARCHAR(MAX) = N'';

SELECT @sql = @sql + N'GRANT EXECUTE ON OBJECT::' + QUOTENAME(s.name) + N'.' + QUOTENAME(p.name)
                   + N' TO ' + QUOTENAME(@usuario) + N';' + CHAR(13)
  FROM sys.procedures p
  JOIN sys.schemas    s ON s.schema_id = p.schema_id
 WHERE p.name LIKE 'usp[_]%';

IF @sql = N''
BEGIN
    RAISERROR('No se encontraron procedimientos usp_*. ¿Corriste antes 10_Esquema_MultiSucursal.sql?', 16, 1);
    RETURN;
END

EXEC sp_executesql @sql;
PRINT '[OK] EXECUTE otorgado sobre los procedimientos usp_*';
GO


/* Verificación: qué puede hacer el usuario. */
DECLARE @usuario SYSNAME = N'link_user';

SELECT  o.name                AS Objeto,
        o.type_desc           AS Tipo,
        dp.permission_name    AS Permiso,
        dp.state_desc         AS Estado
  FROM  sys.database_permissions dp
  JOIN  sys.objects o ON o.object_id = dp.major_id
  JOIN  sys.database_principals u ON u.principal_id = dp.grantee_principal_id
 WHERE  u.name = @usuario
 ORDER BY o.name;
GO

-- =====================================================================
-- Ejecutar en BD_Central (debería propagarse a las 3 sucursales
-- por la replicación que ya configuraste, igual que tu prueba
-- con la categoría "Prueba Replicación").
--
-- Verifica después de correr esto que los 4 usuarios aparezcan también
-- en BD_Monterrey, BD_Puebla y BD_Queretaro. Si NO aparecen (porque
-- Empleados no quedó incluido en la publicación), corre el mismo
-- INSERT de abajo manualmente en esas 3 bases.
-- =====================================================================
USE BD_Central;
GO

-- El hash de PHP (password_hash) es un string, no binario -> cambiamos el tipo
ALTER TABLE Empleados ALTER COLUMN PasswordHash VARCHAR(255) NOT NULL;
GO

-- Baja lógica de productos (no se borran físicamente para no romper
-- las referencias en Movimientos/Ventas/DetalleVenta)
ALTER TABLE Productos ADD Activo BIT NOT NULL DEFAULT 1;
GO

-- Los 4 usuarios, uno por sucursal.
-- IMPORTANTE: sustituye 'HASH_...' por el resultado real de
-- generar_hash.php (viene en el proyecto). NO pongas la contraseña
-- en texto plano aquí.
SET IDENTITY_INSERT Empleados ON;
INSERT INTO Empleados (EmpleadoID, Nombre, Puesto, SucursalID, NombreUsuario, PasswordHash, Rol, Activo) VALUES
(1, 'Usuario Central',   'Administrador',      1, 'central',   'HASH_CENTRAL_AQUI',   'Admin',    1),
(2, 'Usuario Monterrey', 'Encargado sucursal', 2, 'monterrey', 'HASH_MONTERREY_AQUI', 'Vendedor', 1),
(3, 'Usuario Puebla',    'Encargado sucursal', 3, 'puebla',    'HASH_PUEBLA_AQUI',    'Vendedor', 1),
(4, 'Usuario Queretaro', 'Encargado sucursal', 4, 'queretaro', 'HASH_QUERETARO_AQUI', 'Vendedor', 1);
SET IDENTITY_INSERT Empleados OFF;
GO

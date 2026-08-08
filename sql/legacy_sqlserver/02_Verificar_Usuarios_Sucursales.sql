-- =====================================================================
-- Correr esto en cada sucursal (BD_Monterrey, BD_Puebla, BD_Queretaro)
-- para confirmar que los 4 usuarios llegaron por replicación desde
-- BD_Central. Si la consulta de abajo NO devuelve 4 filas, corre el
-- INSERT manual que sigue (contraseña para los 4: 12345678).
-- =====================================================================

SELECT EmpleadoID, NombreUsuario, SucursalID, Rol, Activo
FROM Empleados;

-- Si faltan filas, descomenta y corre esto (ajusta la BD con USE):
/*
SET IDENTITY_INSERT Empleados ON;
IF NOT EXISTS (SELECT 1 FROM Empleados WHERE EmpleadoID = 1)
INSERT INTO Empleados (EmpleadoID, Nombre, Puesto, SucursalID, NombreUsuario, PasswordHash, Rol, Activo) VALUES
(1, 'Usuario Central', 'Administrador', 1, 'central', '$2y$10$m4evZ72ObcB25wM4dswdPueEmOnB3WRJGwpsEQgzEDINqOduU3ybW', 'Admin', 1);
IF NOT EXISTS (SELECT 1 FROM Empleados WHERE EmpleadoID = 2)
INSERT INTO Empleados (EmpleadoID, Nombre, Puesto, SucursalID, NombreUsuario, PasswordHash, Rol, Activo) VALUES
(2, 'Usuario Monterrey', 'Encargado sucursal', 2, 'monterrey', '$2y$10$m4evZ72ObcB25wM4dswdPueEmOnB3WRJGwpsEQgzEDINqOduU3ybW', 'Vendedor', 1);
IF NOT EXISTS (SELECT 1 FROM Empleados WHERE EmpleadoID = 3)
INSERT INTO Empleados (EmpleadoID, Nombre, Puesto, SucursalID, NombreUsuario, PasswordHash, Rol, Activo) VALUES
(3, 'Usuario Puebla', 'Encargado sucursal', 3, 'puebla', '$2y$10$m4evZ72ObcB25wM4dswdPueEmOnB3WRJGwpsEQgzEDINqOduU3ybW', 'Vendedor', 1);
IF NOT EXISTS (SELECT 1 FROM Empleados WHERE EmpleadoID = 4)
INSERT INTO Empleados (EmpleadoID, Nombre, Puesto, SucursalID, NombreUsuario, PasswordHash, Rol, Activo) VALUES
(4, 'Usuario Queretaro', 'Encargado sucursal', 4, 'queretaro', '$2y$10$m4evZ72ObcB25wM4dswdPueEmOnB3WRJGwpsEQgzEDINqOduU3ybW', 'Vendedor', 1);
SET IDENTITY_INSERT Empleados OFF;
*/

-- NOTA: si al insertar da el error "Implicit conversion from data type
-- varchar to varbinary", significa que esa base todavia no tiene el
-- ajuste de columna. Corre primero (una sola vez, en esa misma base):
-- ALTER TABLE Empleados ALTER COLUMN PasswordHash VARCHAR(255) NOT NULL;

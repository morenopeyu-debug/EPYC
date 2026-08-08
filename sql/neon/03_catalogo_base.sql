/* =====================================================================
   03_catalogo_base.sql
   Datos maestros: sucursales, categorías, proveedores, catálogo de
   productos y usuarios de la aplicación.

   EJECUTAR EN LAS 4 BASES, después de 02_funciones_y_trigger.sql.

   ---------------------------------------------------------------------
   POR QUÉ VA IDÉNTICO EN LAS CUATRO
   ---------------------------------------------------------------------
   En SQL Server, Productos / Categorias / Proveedores / Empleados eran
   catálogo maestro que Central publicaba y la replicación de mezcla
   copiaba a las otras tres. Aquí se siembra el mismo contenido, con los
   MISMOS ID, en las cuatro bases: así un ProductoID significa lo mismo
   en Monterrey que en Central, que es lo que la aplicación da por hecho.

   Todos los INSERT son idempotentes (ON CONFLICT DO NOTHING): se puede
   volver a correr el script sin duplicar nada.

   ---------------------------------------------------------------------
   USUARIOS Y CONTRASEÑA
   ---------------------------------------------------------------------
   Los cuatro usuarios entran con la contraseña:  12345678
   El hash es el mismo bcrypt que ya traía el proyecto
   (sql/02_Verificar_Usuarios_Sucursales.sql), así que las credenciales
   que ya usabas siguen sirviendo.

   Para cambiar una contraseña, genera el hash con el script del
   proyecto y sustitúyelo aquí:

       php generar_hash.php "TuContraseñaNueva"
   ===================================================================== */

SET search_path TO dbo, public;


/* =====================================================================
   1. SUCURSALES  —  ID fijos: el código y config.php los referencian
                     por número.
   ===================================================================== */
INSERT INTO dbo."Sucursales" ("SucursalID", "Nombre", "Ciudad", "Direccion", "Telefono", "EsCentral") VALUES
    (1, 'Central',   'Ciudad de México', 'Av. Central 100, Col. Almacén',  '55-1000-0001', 1),
    (2, 'Monterrey', 'Monterrey',        'Av. Constitución 250, Centro',   '81-2000-0002', 0),
    (3, 'Puebla',    'Puebla',           'Blvd. 5 de Mayo 410, Centro',    '22-3000-0003', 0),
    (4, 'Querétaro', 'Querétaro',        'Av. Zaragoza 88, Centro',        '44-4000-0004', 0)
ON CONFLICT ("SucursalID") DO NOTHING;


/* =====================================================================
   2. CATEGORÍAS
   ===================================================================== */
INSERT INTO dbo."Categorias" ("CategoriaID", "Nombre", "Descripcion") VALUES
    (1, 'Alimento',              'Croquetas, latas y premios'),
    (2, 'Juguetes',              'Pelotas, mordederas y peluches'),
    (3, 'Collares y correas',    'Collares, arneses, correas y placas'),
    (4, 'Camas y descanso',      'Camas, cojines y mantas'),
    (5, 'Higiene y limpieza',    'Shampoo, arena, toallitas y bolsas'),
    (6, 'Comederos y bebederos', 'Platos, fuentes y dispensadores'),
    (7, 'Transportadoras',       'Jaulas, bolsas y mochilas de viaje'),
    (8, 'Rascadores',            'Rascadores y torres para gato')
ON CONFLICT ("CategoriaID") DO NOTHING;


/* =====================================================================
   3. PROVEEDORES
   ===================================================================== */
INSERT INTO dbo."Proveedores" ("ProveedorID", "Nombre", "Contacto", "Telefono", "Correo") VALUES
    (1, 'Distribuidora PetMax',      'Laura Ibarra',   '55-5555-1010', 'ventas@petmax.mx'),
    (2, 'Mascotas del Norte S.A.',   'Raúl Treviño',   '81-8181-2020', 'contacto@mascnorte.mx'),
    (3, 'Importadora AnimalCare',    'Sofía Ruiz',     '55-4444-3030', 'compras@animalcare.mx'),
    (4, 'Juguetería Canina MX',      'Diego Salgado',  '33-3333-4040', 'pedidos@jugcanina.mx'),
    (5, 'Higiene Pet Solutions',     'Ana Villalobos', '22-2222-5050', 'ana@higienepet.mx')
ON CONFLICT ("ProveedorID") DO NOTHING;


/* =====================================================================
   4. PRODUCTOS  —  catálogo de la tienda de accesorios para perros y gatos.

   "StockMinimo" arranca en 5 para todo el catálogo: es el criterio que
   pide el proyecto (alerta cuando quedan <= 5 unidades) y es justo lo
   que venía a corregir el viejo sql/13_Normalizar_Umbrales.sql, donde
   cada producto alertaba con un umbral distinto (5, 8, 10, 15, 20) y en
   pantalla no se entendía por qué.
   ===================================================================== */
INSERT INTO dbo."Productos"
    ("ProductoID", "Nombre", "CategoriaID", "ProveedorID", "TipoMascota", "Marca", "Talla", "PrecioUnitario", "StockMinimo", "Activo")
VALUES
    ( 1, 'Croquetas adulto raza pequeña 2 kg', 1, 1, 'Perro', 'NutriCan',    '2 kg',    289.00, 5, 1),
    ( 2, 'Croquetas gato adulto 1.5 kg',       1, 1, 'Gato',  'FelisPro',    '1.5 kg',  245.50, 5, 1),
    ( 3, 'Churus atún 4 piezas',               1, 3, 'Gato',  'Inaba',       '4 pzas',   68.00, 5, 1),
    ( 4, 'Premios entrenamiento pollo 200 g',  1, 1, 'Perro', 'NutriCan',    '200 g',    89.90, 5, 1),
    ( 5, 'Lata alimento húmedo res 385 g',     1, 2, 'Perro', 'CarniPet',    '385 g',    42.00, 5, 1),

    ( 6, 'Pelota de hule resistente',          2, 4, 'Perro', 'DogPlay',     'Mediana', 119.00, 5, 1),
    ( 7, 'Mordedera cuerda trenzada',          2, 4, 'Perro', 'DogPlay',     'Grande',   95.00, 5, 1),
    ( 8, 'Ratón de peluche con catnip',        2, 4, 'Gato',  'MiauToys',    'Chica',    55.00, 5, 1),
    ( 9, 'Varita con plumas interactiva',      2, 4, 'Gato',  'MiauToys',    'Única',    72.50, 5, 1),
    (10, 'Kong rellenable clásico',            2, 3, 'Perro', 'Kong',        'Mediana', 289.00, 5, 1),

    (11, 'Collar nylon ajustable',             3, 2, 'Perro', 'PetGear',     'Mediano', 149.00, 5, 1),
    (12, 'Arnés antitirones acolchado',        3, 2, 'Perro', 'PetGear',     'Grande',  349.00, 5, 1),
    (13, 'Correa retráctil 5 m',               3, 2, 'Perro', 'PetGear',     '5 m',     329.00, 5, 1),
    (14, 'Collar gato con cascabel',           3, 2, 'Gato',  'FelisPro',    'Chico',    79.00, 5, 1),
    (15, 'Placa de identificación grabada',    3, 3, 'Ambos', 'IDPet',       'Única',    65.00, 5, 1),

    (16, 'Cama redonda felpa',                 4, 1, 'Ambos', 'SleepyPet',   'Mediana', 459.00, 5, 1),
    (17, 'Colchoneta impermeable',             4, 1, 'Perro', 'SleepyPet',   'Grande',  399.00, 5, 1),
    (18, 'Manta polar suave',                  4, 1, 'Ambos', 'SleepyPet',   'Única',   189.00, 5, 1),

    (19, 'Shampoo hipoalergénico 500 ml',      5, 5, 'Ambos', 'HigienePet',  '500 ml',  159.00, 5, 1),
    (20, 'Arena aglutinante 5 kg',             5, 5, 'Gato',  'CleanCat',    '5 kg',    179.00, 5, 1),
    (21, 'Toallitas húmedas 80 piezas',        5, 5, 'Ambos', 'HigienePet',  '80 pzas',  85.00, 5, 1),
    (22, 'Bolsas biodegradables 120 piezas',   5, 5, 'Perro', 'CleanDog',    '120 pzas', 99.00, 5, 1),

    (23, 'Plato doble acero inoxidable',       6, 3, 'Ambos', 'PetGear',     'Mediano', 229.00, 5, 1),
    (24, 'Fuente de agua automática 2 L',      6, 3, 'Ambos', 'AquaPet',     '2 L',     649.00, 5, 1),
    (25, 'Dispensador de croquetas 3 kg',      6, 1, 'Ambos', 'PetGear',     '3 kg',    499.00, 5, 1),

    (26, 'Transportadora rígida chica',        7, 2, 'Ambos', 'TravelPet',   'Chica',   699.00, 5, 1),
    (27, 'Mochila transportadora ventilada',   7, 2, 'Gato',  'TravelPet',   'Mediana', 899.00, 5, 1),

    (28, 'Rascador torre 3 niveles',           8, 4, 'Gato',  'MiauToys',    'Grande', 1249.00, 5, 1),
    (29, 'Rascador de cartón horizontal',      8, 4, 'Gato',  'MiauToys',    'Chico',   139.00, 5, 1),
    (30, 'Poste rascador con juguete',         8, 4, 'Gato',  'MiauToys',    'Mediano', 429.00, 5, 1)
ON CONFLICT ("ProductoID") DO NOTHING;


/* =====================================================================
   5. EMPLEADOS / USUARIOS  —  uno por sucursal.

   Contraseña de los cuatro: 12345678
   ===================================================================== */
INSERT INTO dbo."Empleados"
    ("EmpleadoID", "Nombre", "Puesto", "SucursalID", "NombreUsuario", "PasswordHash", "Rol", "Activo")
VALUES
    (1, 'Usuario Central',   'Administrador',      1, 'central',
        '$2y$10$m4evZ72ObcB25wM4dswdPueEmOnB3WRJGwpsEQgzEDINqOduU3ybW', 'Admin',    1),
    (2, 'Usuario Monterrey', 'Encargado sucursal', 2, 'monterrey',
        '$2y$10$m4evZ72ObcB25wM4dswdPueEmOnB3WRJGwpsEQgzEDINqOduU3ybW', 'Vendedor', 1),
    (3, 'Usuario Puebla',    'Encargado sucursal', 3, 'puebla',
        '$2y$10$m4evZ72ObcB25wM4dswdPueEmOnB3WRJGwpsEQgzEDINqOduU3ybW', 'Vendedor', 1),
    (4, 'Usuario Queretaro', 'Encargado sucursal', 4, 'queretaro',
        '$2y$10$m4evZ72ObcB25wM4dswdPueEmOnB3WRJGwpsEQgzEDINqOduU3ybW', 'Vendedor', 1)
ON CONFLICT ("EmpleadoID") DO NOTHING;


/* =====================================================================
   6. RESINCRONIZAR LOS CONTADORES DE IDENTIDAD

   Los INSERT de arriba traen el ID escrito a mano (equivalente al
   SET IDENTITY_INSERT ON de SQL Server). Postgres no entera de eso a la
   secuencia, así que el próximo alta automática intentaría el ID 1 y
   chocaría. Esto adelanta cada secuencia al máximo ya usado.
   ===================================================================== */
SELECT setval(pg_get_serial_sequence('dbo."Categorias"',  'CategoriaID'),
              COALESCE((SELECT MAX("CategoriaID")  FROM dbo."Categorias"),  1), true);

SELECT setval(pg_get_serial_sequence('dbo."Proveedores"', 'ProveedorID'),
              COALESCE((SELECT MAX("ProveedorID") FROM dbo."Proveedores"), 1), true);

SELECT setval(pg_get_serial_sequence('dbo."Productos"',   'ProductoID'),
              COALESCE((SELECT MAX("ProductoID")  FROM dbo."Productos"),   1), true);

SELECT setval(pg_get_serial_sequence('dbo."Empleados"',   'EmpleadoID'),
              COALESCE((SELECT MAX("EmpleadoID")  FROM dbo."Empleados"),   1), true);


DO $$ BEGIN
    RAISE NOTICE '=====================================================';
    RAISE NOTICE ' [OK] Catálogo base sembrado.';
    RAISE NOTICE ' Siguiente paso: 04_inventario_inicial.sql';
    RAISE NOTICE '=====================================================';
END $$;

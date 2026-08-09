<?php
/**
 * Catálogo maestro de productos.
 *
 * Solo Central escribe aquí. Las sucursales leen el catálogo.
 * La baja es SIEMPRE lógica (Productos.Activo = 0): hay referencias
 * vivas desde Movimientos, DetalleVenta e InventarioSucursal.
 *
 * NOTA SOBRE LAS COMILLAS EN LOS IDENTIFICADORES
 * ----------------------------------------------
 * PostgreSQL pasa a minúsculas todo identificador que no vaya entre
 * comillas dobles. El esquema conserva el PascalCase de SQL Server
 * ("ProductoID"), así que las consultas lo escriben entrecomillado: es
 * lo que mantiene intactas las claves de los arreglos que devuelve PDO
 * y, con ellas, todas las vistas .php sin tocar.
 */
final class ProductoRepo
{
    public function __construct(private PDO $pdo) {}

    /**
     * Catálogo con el stock de una sucursal concreta.
     *
     * @param array{buscar?:string, categoria?:int, tipo?:string, soloActivos?:bool} $filtros
     */
    public function listar(int $sucursalId, array $filtros = []): array
    {
        $sql = 'SELECT  p."ProductoID",
                        p."Nombre",
                        p."CategoriaID",
                        c."Nombre"       AS "Categoria",
                        p."TipoMascota",
                        p."Marca",
                        p."Talla",
                        p."PrecioUnitario",
                        p."Activo",
                        COALESCE(inv."Stock", 0)                        AS "Stock",
                        COALESCE(inv."StockMinimo", CAST(:umbral AS INTEGER)) AS "StockMinimo"
                  FROM  dbo."Productos" p
                  JOIN  dbo."Categorias" c
                    ON  c."CategoriaID" = p."CategoriaID"
             LEFT JOIN  dbo."InventarioSucursal" inv
                    ON  inv."ProductoID" = p."ProductoID"
                   AND  inv."SucursalID" = :sucursal
                 WHERE  1 = 1';

        $params = [
            'sucursal' => $sucursalId,
            'umbral'   => UMBRAL_STOCK_BAJO,
        ];

        if (!empty($filtros['buscar'])) {
            // ILIKE, no LIKE: en SQL Server la intercalación por omisión
            // no distinguía mayúsculas y la búsqueda del catálogo tampoco
            // debe hacerlo aquí.
            $sql .= ' AND p."Nombre" ILIKE :buscar';
            $params['buscar'] = '%' . $filtros['buscar'] . '%';
        }

        if (!empty($filtros['categoria'])) {
            $sql .= ' AND p."CategoriaID" = :categoria';
            $params['categoria'] = (int) $filtros['categoria'];
        }

        if (!empty($filtros['tipo'])) {
            $sql .= ' AND p."TipoMascota" = :tipo';
            $params['tipo'] = $filtros['tipo'];
        }

        if (!empty($filtros['soloActivos'])) {
            $sql .= ' AND p."Activo" = 1';
        }

        $sql .= ' ORDER BY p."Activo" DESC, p."Nombre"';

        $stmt = $this->pdo->prepare($sql);
        $stmt->execute($params);

        return $stmt->fetchAll();
    }

    /** Productos activos con existencias en la sucursal — para vender. */
    public function conStockEn(int $sucursalId): array
    {
        $sql = 'SELECT  p."ProductoID", p."Nombre", p."Marca", p."PrecioUnitario",
                        inv."Stock", inv."StockMinimo"
                  FROM  dbo."InventarioSucursal" inv
                  JOIN  dbo."Productos" p ON p."ProductoID" = inv."ProductoID"
                 WHERE  inv."SucursalID" = :sucursal
                   AND  p."Activo" = 1
                   AND  inv."Stock" > 0
              ORDER BY  p."Nombre"';

        $stmt = $this->pdo->prepare($sql);
        $stmt->execute(['sucursal' => $sucursalId]);

        return $stmt->fetchAll();
    }

    public function obtener(int $productoId): ?array
    {
        $stmt = $this->pdo->prepare('SELECT * FROM dbo."Productos" WHERE "ProductoID" = ?');
        $stmt->execute([$productoId]);

        return $stmt->fetch() ?: null;
    }

    /** Alta. Devuelve el ProductoID nuevo y siembra su fila de inventario. */
    public function crear(array $datos): int
    {
        $this->pdo->beginTransaction();

        try {
            // RETURNING sustituye al OUTPUT ... INTO @tabla de SQL Server.
            // Aquel rodeo existía porque dbo.Productos, al ser artículo de
            // la replicación de mezcla, cargaba triggers y SQL Server
            // prohíbe OUTPUT sin INTO sobre tablas con triggers. En
            // Postgres nada de eso aplica: RETURNING funciona sin más.
            $sql = 'INSERT INTO dbo."Productos"
                        ("Nombre", "CategoriaID", "ProveedorID", "TipoMascota", "Marca",
                         "Talla", "PrecioUnitario", "StockMinimo", "Activo")
                    VALUES (:nombre, :categoria, :proveedor, :tipo, :marca,
                            :talla, :precio, :stock_minimo, 1)
                    RETURNING "ProductoID"';

            $stmt = $this->pdo->prepare($sql);
            $stmt->execute([
                'nombre'       => $datos['nombre'],
                'categoria'    => $datos['categoria'],
                // El formulario manda 0 cuando no hay proveedor elegido;
                // 0 no existe en Proveedores y reventaría la llave foránea
                // con un mensaje incomprensible.
                'proveedor'    => $datos['proveedor'] > 0 ? $datos['proveedor'] : null,
                'tipo'         => $datos['tipo_mascota'],
                'marca'        => $datos['marca'] !== '' ? $datos['marca'] : null,
                'talla'        => $datos['talla'] !== '' ? $datos['talla'] : null,
                'precio'       => $datos['precio'],
                'stock_minimo' => $datos['stock_minimo'],
            ]);

            $productoId = (int) $stmt->fetchColumn();
            $stmt->closeCursor();

            // Una fila (sucursal, producto) en cero para las cuatro sedes,
            // para que el producto nuevo aparezca desde el primer día en
            // los tableros de inventario de todas.
            $this->pdo->prepare(
                'INSERT INTO dbo."InventarioSucursal"
                     ("SucursalID", "ProductoID", "Stock", "StockMinimo", "StockObjetivo")
                 SELECT s."SucursalID", :producto, 0, :minimo, :objetivo
                   FROM dbo."Sucursales" s
                 ON CONFLICT ("SucursalID", "ProductoID") DO NOTHING'
            )->execute([
                'producto'  => $productoId,
                'minimo'    => $datos['stock_minimo'] > 0 ? $datos['stock_minimo'] : UMBRAL_STOCK_BAJO,
                'objetivo'  => $datos['stock_minimo'] > 0 ? $datos['stock_minimo'] * 4 : 20,
            ]);

            $this->pdo->commit();

            return $productoId;
        } catch (Throwable $e) {
            $this->pdo->rollBack();
            throw $e;
        }
    }

    /** Modificación de datos generales. No toca stock. */
    public function actualizar(int $productoId, array $datos): void
    {
        $sql = 'UPDATE dbo."Productos"
                   SET "Nombre"         = :nombre,
                       "CategoriaID"    = :categoria,
                       "ProveedorID"    = :proveedor,
                       "TipoMascota"    = :tipo,
                       "Marca"          = :marca,
                       "Talla"          = :talla,
                       "PrecioUnitario" = :precio,
                       "StockMinimo"    = :stock_minimo
                 WHERE "ProductoID"     = :id';

        $this->pdo->prepare($sql)->execute([
            'nombre'       => $datos['nombre'],
            'categoria'    => $datos['categoria'],
            'proveedor'    => $datos['proveedor'] > 0 ? $datos['proveedor'] : null,
            'tipo'         => $datos['tipo_mascota'],
            'marca'        => $datos['marca'] !== '' ? $datos['marca'] : null,
            'talla'        => $datos['talla'] !== '' ? $datos['talla'] : null,
            'precio'       => $datos['precio'],
            'stock_minimo' => $datos['stock_minimo'],
            'id'           => $productoId,
        ]);
    }

    /**
     * Baja lógica / reactivación. Nunca DELETE.
     *
     * Al dar de baja se cierran las solicitudes abiertas del producto
     * para que no queden requisiciones huérfanas esperando respuesta.
     */
    public function cambiarEstado(int $productoId, bool $activo): void
    {
        $this->pdo->beginTransaction();

        try {
            $this->pdo
                 ->prepare('UPDATE dbo."Productos" SET "Activo" = ? WHERE "ProductoID" = ?')
                 ->execute([$activo ? 1 : 0, $productoId]);

            if (!$activo) {
                $this->pdo->prepare(
                    'UPDATE dbo."SolicitudesStock"
                        SET "Estado"             = \'RECHAZADO\',
                            "CantidadOfrecida"   = COALESCE("CantidadOfrecida", 0),
                            "FechaRespuesta"     = dbo.ahora(),
                            "ComentarioSucursal" = \'Cancelada: el producto fue dado de baja del catálogo.\'
                      WHERE "ProductoID" = ? AND "Estado" = \'PENDIENTE\''
                )->execute([$productoId]);
            }

            $this->pdo->commit();
        } catch (Throwable $e) {
            $this->pdo->rollBack();
            throw $e;
        }
    }

    /** ¿Hay envíos en tránsito de este producto? Bloquea la baja. */
    public function tieneEnviosAbiertos(int $productoId): bool
    {
        $stmt = $this->pdo->prepare(
            'SELECT COUNT(*) FROM dbo."SolicitudesStock"
              WHERE "ProductoID" = ? AND "Estado" = \'OFERTADO\''
        );
        $stmt->execute([$productoId]);

        return (int) $stmt->fetchColumn() > 0;
    }

    public function categorias(): array
    {
        return $this->pdo
            ->query('SELECT "CategoriaID", "Nombre" FROM dbo."Categorias" ORDER BY "Nombre"')
            ->fetchAll();
    }

    public function proveedores(): array
    {
        return $this->pdo
            ->query('SELECT "ProveedorID", "Nombre" FROM dbo."Proveedores" ORDER BY "Nombre"')
            ->fetchAll();
    }
}

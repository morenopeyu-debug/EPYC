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

    /**
     * Alta. Devuelve el ProductoID nuevo y siembra su fila de inventario
     * en cero para las cuatro sedes, así el producto aparece desde el
     * primer día en los tableros de todas.
     *
     * El código del producto no se captura: sale del identificador que
     * asigna la base (columna IDENTITY) y se muestra con codigo_producto().
     *
     * Va todo en UNA sentencia, por la misma razón que cambiarEstado():
     * el endpoint "-pooler" de Neon no conserva la conexión de servidor
     * entre las sentencias de una transacción de cliente, y el COMMIT se
     * perdía —el alta decía «Producto dado de alta» y no guardaba nada—.
     * Una CTE que modifica datos es atómica por sí sola.
     */
    public function crear(array $datos): int
    {
        $sql = 'WITH nuevo AS (
                    INSERT INTO dbo."Productos"
                        ("Nombre", "CategoriaID", "ProveedorID", "TipoMascota", "Marca",
                         "Talla", "PrecioUnitario", "StockMinimo", "Activo")
                    VALUES (:nombre, :categoria, :proveedor, :tipo, :marca,
                            :talla, :precio, :stock_minimo, 1)
                 RETURNING "ProductoID"
                ), inventario AS (
                    INSERT INTO dbo."InventarioSucursal"
                        ("SucursalID", "ProductoID", "Stock", "StockMinimo", "StockObjetivo")
                    SELECT s."SucursalID", n."ProductoID", 0, :minimo, :objetivo
                      FROM dbo."Sucursales" s
                     CROSS JOIN nuevo n
                    ON CONFLICT ("SucursalID", "ProductoID") DO NOTHING
                )
                SELECT "ProductoID" FROM nuevo';

        $stmt = $this->pdo->prepare($sql);
        $stmt->execute([
            'nombre'       => $datos['nombre'],
            'categoria'    => $datos['categoria'],
            // El formulario manda 0 cuando no hay proveedor elegido; 0 no
            // existe en Proveedores y reventaría la llave foránea con un
            // mensaje incomprensible.
            'proveedor'    => $datos['proveedor'] > 0 ? $datos['proveedor'] : null,
            'tipo'         => $datos['tipo_mascota'],
            'marca'        => $datos['marca'] !== '' ? $datos['marca'] : null,
            'talla'        => $datos['talla'] !== '' ? $datos['talla'] : null,
            'precio'       => $datos['precio'],
            'stock_minimo' => $datos['stock_minimo'],
            'minimo'       => $datos['stock_minimo'] > 0 ? $datos['stock_minimo'] : UMBRAL_STOCK_BAJO,
            'objetivo'     => $datos['stock_minimo'] > 0 ? $datos['stock_minimo'] * 4 : 20,
        ]);

        $productoId = (int) $stmt->fetchColumn();
        $stmt->closeCursor();

        return $productoId;
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
     * Baja lógica / reactivación. NUNCA se borra el renglón.
     *
     * La baja es siempre lógica ("Activo" = 0) porque hay referencias
     * vivas al producto desde Movimientos, DetalleVenta, Transferencias
     * e InventarioSucursal: un DELETE rompería el histórico de ventas.
     *
     * Al dar de baja se cierran además las solicitudes PENDIENTES del
     * producto, para no dejar requisiciones huérfanas esperando una
     * respuesta que ya no va a llegar.
     *
     * POR QUÉ TODO VA EN UNA SOLA SENTENCIA
     * -------------------------------------
     * Antes esto eran dos UPDATE dentro de beginTransaction()/commit(),
     * y fallaba en el servidor con:
     *
     *     current transaction is aborted, commands ignored until
     *     end of transaction block
     *
     * El host de Neon configurado es el endpoint "-pooler", que es
     * PgBouncer en modo transacción: no garantiza que las sentencias de
     * una transacción abierta desde el cliente caigan en la misma
     * conexión de servidor. La segunda llegaba a otra conexión y el
     * COMMIT se perdía.
     *
     * Con una CTE que modifica datos, las dos escrituras viajan en UNA
     * sentencia. PostgreSQL la ejecuta dentro de su propia transacción
     * implícita, así que la atomicidad se conserva sin depender de que
     * el pooler mantenga el estado entre viajes.
     */
    public function cambiarEstado(int $productoId, bool $activo): void
    {
        if ($activo) {
            // Reactivar no toca solicitudes: basta un UPDATE.
            $this->pdo
                 ->prepare('UPDATE dbo."Productos" SET "Activo" = 1 WHERE "ProductoID" = ?')
                 ->execute([$productoId]);
            return;
        }

        // La CTE que modifica datos se ejecuta siempre, aunque el UPDATE
        // exterior no encuentre ninguna solicitud que cerrar.
        $sql = 'WITH baja AS (
                    UPDATE dbo."Productos"
                       SET "Activo" = 0
                     WHERE "ProductoID" = :id
                 RETURNING "ProductoID"
                )
                UPDATE dbo."SolicitudesStock" s
                   SET "Estado"             = \'RECHAZADO\',
                       "CantidadOfrecida"   = COALESCE(s."CantidadOfrecida", 0),
                       "FechaRespuesta"     = dbo.ahora(),
                       "ComentarioSucursal" = \'Cancelada: el producto fue dado de baja del catálogo.\'
                  FROM baja
                 WHERE s."ProductoID" = baja."ProductoID"
                   AND s."Estado"     = \'PENDIENTE\'';

        $this->pdo->prepare($sql)->execute(['id' => $productoId]);
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

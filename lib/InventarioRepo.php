<?php
/**
 * Inventario particionado por sucursal (dbo."InventarioSucursal").
 *
 * Toda escritura de stock se delega a las funciones almacenadas: ahí
 * viven la validación de existencias y la transacción que mantiene
 * consistentes stock, movimientos y transferencias. La aplicación no
 * hace UPDATE directo sobre el stock en ningún punto — la única
 * excepción es ajustarNiveles(), que toca umbrales, no existencias.
 *
 * En SQL Server esas funciones se invocaban con EXEC dbo.usp_x @A = ?.
 * En PostgreSQL son funciones que devuelven un conjunto de resultados,
 * así que se llaman con SELECT * FROM dbo.usp_x(?, ?, ...).
 */
final class InventarioRepo
{
    public function __construct(private PDO $pdo) {}

    /** Stock de una sucursal, con marca de alerta por fila. */
    public function porSucursal(int $sucursalId, string $buscar = '', bool $soloAlertas = false): array
    {
        $sql = 'SELECT  inv."ProductoID",
                        p."Nombre"       AS "Producto",
                        p."Marca",
                        c."Nombre"       AS "Categoria",
                        p."PrecioUnitario",
                        inv."Stock",
                        inv."StockMinimo",
                        inv."StockObjetivo",
                        inv."UltimaActualizacion",
                        CASE WHEN inv."Stock" <= inv."StockMinimo" THEN 1 ELSE 0 END AS "EnAlerta",
                        (SELECT s."Estado"
                           FROM dbo."SolicitudesStock" s
                          WHERE s."SucursalID" = inv."SucursalID"
                            AND s."ProductoID" = inv."ProductoID"
                            AND s."Estado" IN (\'PENDIENTE\', \'OFERTADO\')
                       ORDER BY s."FechaSolicitud" DESC
                          LIMIT 1) AS "EstadoSolicitud"
                  FROM  dbo."InventarioSucursal" inv
                  JOIN  dbo."Productos"  p ON p."ProductoID"  = inv."ProductoID"
                  JOIN  dbo."Categorias" c ON c."CategoriaID" = p."CategoriaID"
                 WHERE  inv."SucursalID" = :sucursal
                   AND  p."Activo" = 1';

        $params = ['sucursal' => $sucursalId];

        if ($buscar !== '') {
            $sql .= ' AND p."Nombre" ILIKE :buscar';
            $params['buscar'] = '%' . $buscar . '%';
        }

        if ($soloAlertas) {
            $sql .= ' AND inv."Stock" <= inv."StockMinimo"';
        }

        $sql .= ' ORDER BY "EnAlerta" DESC, p."Nombre"';

        $stmt = $this->pdo->prepare($sql);
        $stmt->execute($params);

        return $stmt->fetchAll();
    }

    /** Vista global para Central: cuánto hay de cada producto y dónde. */
    public function panoramaGlobal(string $buscar = ''): array
    {
        $sql = 'SELECT  p."ProductoID",
                        p."Nombre" AS "Producto",
                        p."Activo",
                        SUM(CASE WHEN inv."SucursalID" = 1 THEN inv."Stock" ELSE 0 END) AS "Central",
                        SUM(CASE WHEN inv."SucursalID" = 2 THEN inv."Stock" ELSE 0 END) AS "Monterrey",
                        SUM(CASE WHEN inv."SucursalID" = 3 THEN inv."Stock" ELSE 0 END) AS "Puebla",
                        SUM(CASE WHEN inv."SucursalID" = 4 THEN inv."Stock" ELSE 0 END) AS "Queretaro",
                        SUM(inv."Stock") AS "Total"
                  FROM  dbo."Productos" p
                  JOIN  dbo."InventarioSucursal" inv ON inv."ProductoID" = p."ProductoID"
                 WHERE  p."Activo" = 1';

        $params = [];

        if ($buscar !== '') {
            $sql .= ' AND p."Nombre" ILIKE :buscar';
            $params['buscar'] = '%' . $buscar . '%';
        }

        $sql .= ' GROUP BY p."ProductoID", p."Nombre", p."Activo" ORDER BY p."Nombre"';

        $stmt = $this->pdo->prepare($sql);
        $stmt->execute($params);

        return $stmt->fetchAll();
    }

    public function stockDe(int $sucursalId, int $productoId): int
    {
        $stmt = $this->pdo->prepare(
            'SELECT "Stock" FROM dbo."InventarioSucursal"
              WHERE "SucursalID" = ? AND "ProductoID" = ?'
        );
        $stmt->execute([$sucursalId, $productoId]);

        $valor = $stmt->fetchColumn();

        return $valor === false ? 0 : (int) $valor;
    }

    /** Cuántos productos de la sucursal están en o por debajo del mínimo. */
    public function contarAlertas(int $sucursalId): int
    {
        $stmt = $this->pdo->prepare(
            'SELECT COUNT(*)
               FROM dbo."InventarioSucursal" inv
               JOIN dbo."Productos" p ON p."ProductoID" = inv."ProductoID"
              WHERE inv."SucursalID" = ? AND p."Activo" = 1
                AND inv."Stock" <= inv."StockMinimo"'
        );
        $stmt->execute([$sucursalId]);

        return (int) $stmt->fetchColumn();
    }

    // ----------------------------------------------------------------
    // Escrituras (vía funciones almacenadas)
    // ----------------------------------------------------------------

    /** Recepción de mercancía en el almacén central. */
    public function entradaMercancia(int $productoId, int $cantidad, int $empleadoId, ?string $referencia = null): int
    {
        $stmt = $this->pdo->prepare(
            'SELECT * FROM dbo.usp_entrada_mercancia(?, ?, ?, ?)'
        );
        $stmt->execute([$productoId, $cantidad, $empleadoId, $referencia]);

        $fila = $stmt->fetch();
        $stmt->closeCursor();

        return (int) ($fila['StockResultante'] ?? 0);
    }

    /**
     * Central asigna stock a una sucursal.
     *
     * Descuenta de Central y deja el envío EN TRÁNSITO: la sucursal
     * destino lo confirma, que es la única autorizada a incrementar su
     * propio inventario. Así el modelo sigue cumpliendo la regla de que
     * cada sitio escribe solamente las filas que le pertenecen.
     */
    public function asignarASucursal(int $productoId, int $sucursalId, int $cantidad, int $empleadoId, ?string $comentario = null): int
    {
        $stmt = $this->pdo->prepare(
            'SELECT * FROM dbo.usp_asignar_stock_sucursal(?, ?, ?, ?, ?)'
        );
        $stmt->execute([$productoId, $sucursalId, $cantidad, $empleadoId, $comentario]);

        $fila = $stmt->fetch();
        $stmt->closeCursor();

        return (int) ($fila['SolicitudID'] ?? 0);
    }

    /** Barrido manual de alertas: genera las requisiciones faltantes. */
    public function generarAlertas(int $sucursalId, int $empleadoId): int
    {
        $stmt = $this->pdo->prepare(
            'SELECT * FROM dbo.usp_generar_alertas_stock_bajo(?, ?)'
        );
        $stmt->execute([$sucursalId, $empleadoId]);

        $fila = $stmt->fetch();
        $stmt->closeCursor();

        return (int) ($fila['AlertasGeneradas'] ?? 0);
    }

    /** Ajuste del punto de reorden y del objetivo de reabastecimiento. */
    public function ajustarNiveles(int $sucursalId, int $productoId, int $minimo, int $objetivo): void
    {
        if ($minimo < 0 || $objetivo < $minimo) {
            throw new InvalidArgumentException('El objetivo debe ser mayor o igual que el mínimo.');
        }

        $this->pdo->prepare(
            'UPDATE dbo."InventarioSucursal"
                SET "StockMinimo" = ?, "StockObjetivo" = ?
              WHERE "SucursalID" = ? AND "ProductoID" = ?'
        )->execute([$minimo, $objetivo, $sucursalId, $productoId]);
    }
}

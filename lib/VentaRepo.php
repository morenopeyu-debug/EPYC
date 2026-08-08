<?php
/**
 * Simulación de ventas en mostrador.
 *
 * La venta descuenta el stock de la sucursal que la registra. Si con eso
 * el producto queda en el punto de reorden o por debajo, el trigger
 * trg_InvSuc_AlertaStockBajo levanta sola la requisición hacia Central.
 */
final class VentaRepo
{
    public function __construct(private PDO $pdo) {}

    /**
     * Registra la venta y devuelve folio, total y stock resultante.
     *
     * @return array{VentaID:int, Total:string, StockResultante:int}
     */
    public function registrar(int $sucursalId, int $productoId, int $cantidad, int $empleadoId): array
    {
        $stmt = $this->pdo->prepare(
            'SELECT * FROM dbo.usp_registrar_venta(?, ?, ?, ?)'
        );
        $stmt->execute([$sucursalId, $productoId, $cantidad, $empleadoId]);

        $fila = $stmt->fetch();
        $stmt->closeCursor();

        return [
            'VentaID'         => (int) ($fila['VentaID'] ?? 0),
            'Total'           => (string) ($fila['Total'] ?? '0'),
            'StockResultante' => (int) ($fila['StockResultante'] ?? 0),
        ];
    }

    /** Últimas ventas de la sucursal, para dar contexto en la pantalla. */
    public function ultimas(int $sucursalId, int $limite = 15): array
    {
        $limite = max(1, min($limite, 200));

        $sql = 'SELECT v."VentaID",
                       v."Fecha",
                       v."Total",
                       p."Nombre"  AS "Producto",
                       d."Cantidad",
                       d."PrecioUnitario",
                       e."Nombre"  AS "Empleado"
                  FROM dbo."Ventas" v
                  JOIN dbo."DetalleVenta" d ON d."VentaID"    = v."VentaID"
                  JOIN dbo."Productos"    p ON p."ProductoID" = d."ProductoID"
                  JOIN dbo."Empleados"    e ON e."EmpleadoID" = v."EmpleadoID"
                 WHERE v."SucursalID" = :sucursal
              ORDER BY v."Fecha" DESC, v."VentaID" DESC
                 LIMIT ' . $limite;

        $stmt = $this->pdo->prepare($sql);
        $stmt->execute(['sucursal' => $sucursalId]);

        return $stmt->fetchAll();
    }

    /**
     * Total vendido hoy en la sucursal.
     *
     * "Hoy" se calcula con dbo.ahora(), que devuelve la hora de México.
     * Neon corre en UTC: comparar contra NOW() movería el corte del día
     * a las 18:00 hora local.
     */
    public function totalDelDia(int $sucursalId): array
    {
        $stmt = $this->pdo->prepare(
            'SELECT COUNT(*) AS "Operaciones", COALESCE(SUM("Total"), 0) AS "Importe"
               FROM dbo."Ventas"
              WHERE "SucursalID" = ? AND "Fecha"::date = (dbo.ahora())::date'
        );
        $stmt->execute([$sucursalId]);

        return $stmt->fetch() ?: ['Operaciones' => 0, 'Importe' => 0];
    }
}

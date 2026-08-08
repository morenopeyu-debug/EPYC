<?php
/**
 * Requisiciones de stock entre sucursales y Central.
 *
 * Flujo completo:
 *
 *   PENDIENTE  la sucursal pide (a mano, o el trigger de stock bajo)
 *   OFERTADO   Central responde con la cantidad que sí tiene —puede ser
 *              menor a la pedida— y descuenta su almacén
 *   ACEPTADO   la sucursal confirma; el stock entra a su inventario
 *   RECHAZADO  la sucursal declina; Central reintegra lo apartado
 */
final class SolicitudRepo
{
    public function __construct(private PDO $pdo) {}

    private const SELECT_BASE = '
        SELECT  s."SolicitudID",
                s."SucursalID",
                suc."Nombre"        AS "Sucursal",
                s."ProductoID",
                p."Nombre"          AS "Producto",
                p."Marca",
                p."PrecioUnitario",
                s."CantidadSolicitada",
                s."CantidadOfrecida",
                s."Estado",
                s."Origen",
                s."StockAlSolicitar",
                s."ComentarioCentral",
                s."ComentarioSucursal",
                s."FechaSolicitud",
                s."FechaOferta",
                s."FechaRespuesta",
                s."StockReintegrado",
                COALESCE(central."Stock", 0) AS "StockCentral",
                COALESCE(local_."Stock", 0)  AS "StockSucursal"
          FROM  dbo."SolicitudesStock" s
          JOIN  dbo."Productos"  p   ON p."ProductoID"   = s."ProductoID"
          JOIN  dbo."Sucursales" suc ON suc."SucursalID" = s."SucursalID"
     LEFT JOIN  dbo."InventarioSucursal" central
            ON  central."ProductoID" = s."ProductoID" AND central."SucursalID" = 1
     LEFT JOIN  dbo."InventarioSucursal" local_
            ON  local_."ProductoID" = s."ProductoID" AND local_."SucursalID" = s."SucursalID"';
    // El alias "local_" lleva guion bajo a propósito: LOCAL es palabra
    // reservada en PostgreSQL y como alias sin comillas da error de
    // sintaxis. En SQL Server pasaba sin problema.

    /** Bandeja de Central: lo que espera respuesta suya. */
    public function pendientesParaCentral(): array
    {
        $sql = self::SELECT_BASE . '
                 WHERE s."Estado" = \'PENDIENTE\'
              ORDER BY s."FechaSolicitud"';

        return $this->pdo->query($sql)->fetchAll();
    }

    /** Envíos que Central ya despachó y siguen sin confirmar. */
    public function enTransito(): array
    {
        $sql = self::SELECT_BASE . '
                 WHERE s."Estado" = \'OFERTADO\'
              ORDER BY s."FechaOferta"';

        return $this->pdo->query($sql)->fetchAll();
    }

    /** Rechazos cuyo stock apartado todavía no vuelve al almacén central. */
    public function rechazadasSinReintegrar(): array
    {
        $sql = self::SELECT_BASE . '
                 WHERE s."Estado" = \'RECHAZADO\' AND s."StockReintegrado" = 0
              ORDER BY s."FechaRespuesta" DESC';

        return $this->pdo->query($sql)->fetchAll();
    }

    /** Historial completo, opcionalmente acotado a una sucursal. */
    public function historial(?int $sucursalId = null, int $limite = 100): array
    {
        // SQL Server usaba TOP n, que va pegado al SELECT; PostgreSQL usa
        // LIMIT n al final. El valor se acota aquí y se interpola porque
        // LIMIT no admite parámetro con consultas preparadas del servidor.
        $limite = max(1, min($limite, 500));

        $sql = self::SELECT_BASE;
        $params = [];

        if ($sucursalId !== null) {
            $sql .= ' WHERE s."SucursalID" = :sucursal';
            $params['sucursal'] = $sucursalId;
        }

        $sql .= ' ORDER BY s."FechaSolicitud" DESC LIMIT ' . $limite;

        $stmt = $this->pdo->prepare($sql);
        $stmt->execute($params);

        return $stmt->fetchAll();
    }

    /** Bandeja de la sucursal: ofertas de Central esperando su decisión. */
    public function ofertasPara(int $sucursalId): array
    {
        $sql = self::SELECT_BASE . '
                 WHERE s."SucursalID" = :sucursal AND s."Estado" = \'OFERTADO\'
              ORDER BY s."FechaOferta"';

        $stmt = $this->pdo->prepare($sql);
        $stmt->execute(['sucursal' => $sucursalId]);

        return $stmt->fetchAll();
    }

    /** Solicitudes de la sucursal que Central aún no atiende. */
    public function pendientesDe(int $sucursalId): array
    {
        $sql = self::SELECT_BASE . '
                 WHERE s."SucursalID" = :sucursal AND s."Estado" = \'PENDIENTE\'
              ORDER BY s."FechaSolicitud"';

        $stmt = $this->pdo->prepare($sql);
        $stmt->execute(['sucursal' => $sucursalId]);

        return $stmt->fetchAll();
    }

    public function obtener(int $solicitudId): ?array
    {
        $sql = self::SELECT_BASE . ' WHERE s."SolicitudID" = :id';

        $stmt = $this->pdo->prepare($sql);
        $stmt->execute(['id' => $solicitudId]);

        return $stmt->fetch() ?: null;
    }

    /** Cuenta para los distintivos del menú. */
    public function contar(string $estado, ?int $sucursalId = null): int
    {
        $sql = 'SELECT COUNT(*) FROM dbo."SolicitudesStock" WHERE "Estado" = :estado';
        $params = ['estado' => $estado];

        if ($sucursalId !== null) {
            $sql .= ' AND "SucursalID" = :sucursal';
            $params['sucursal'] = $sucursalId;
        }

        $stmt = $this->pdo->prepare($sql);
        $stmt->execute($params);

        return (int) $stmt->fetchColumn();
    }

    // ----------------------------------------------------------------
    // Escrituras (vía funciones almacenadas)
    // ----------------------------------------------------------------

    /** La sucursal pide reabastecimiento. Devuelve 0 si ya había una abierta. */
    public function solicitar(int $sucursalId, int $productoId, ?int $cantidad, int $empleadoId, string $comentario = ''): int
    {
        $stmt = $this->pdo->prepare(
            'SELECT * FROM dbo.usp_solicitar_reabastecimiento(?, ?, ?, ?, ?, ?)'
        );
        $stmt->execute([
            $sucursalId,
            $productoId,
            $cantidad,
            $empleadoId,
            'MANUAL',
            $comentario !== '' ? $comentario : null,
        ]);

        $fila = $stmt->fetch();
        $stmt->closeCursor();

        return (int) ($fila['SolicitudID'] ?? 0);
    }

    /** Central oferta una cantidad (total o parcial) y despacha. */
    public function ofertar(int $solicitudId, int $cantidad, int $empleadoId, string $comentario = ''): void
    {
        $stmt = $this->pdo->prepare(
            'SELECT dbo.usp_ofertar_solicitud(?, ?, ?, ?)'
        );
        $stmt->execute([
            $solicitudId,
            $cantidad,
            $empleadoId,
            $comentario !== '' ? $comentario : null,
        ]);
        $stmt->closeCursor();
    }

    /** La sucursal acepta o rechaza el envío. */
    public function responder(int $solicitudId, bool $aceptar, int $empleadoId, string $comentario = ''): void
    {
        $stmt = $this->pdo->prepare(
            'SELECT dbo.usp_responder_solicitud(?, CAST(? AS SMALLINT), ?, ?)'
        );
        $stmt->execute([
            $solicitudId,
            $aceptar ? 1 : 0,
            $empleadoId,
            $comentario !== '' ? $comentario : null,
        ]);
        $stmt->closeCursor();
    }

    /** Central recupera el stock de un envío rechazado. */
    public function reintegrar(int $solicitudId, int $empleadoId): void
    {
        $stmt = $this->pdo->prepare(
            'SELECT dbo.usp_reintegrar_solicitud(?, ?)'
        );
        $stmt->execute([$solicitudId, $empleadoId]);
        $stmt->closeCursor();
    }

    /**
     * Verifica que la solicitud pertenezca a la sucursal indicada.
     * Impide que una sucursal responda envíos dirigidos a otra pasando
     * un SolicitudID a mano en el formulario.
     */
    public function perteneceA(int $solicitudId, int $sucursalId): bool
    {
        $stmt = $this->pdo->prepare(
            'SELECT COUNT(*) FROM dbo."SolicitudesStock"
              WHERE "SolicitudID" = ? AND "SucursalID" = ?'
        );
        $stmt->execute([$solicitudId, $sucursalId]);

        return (int) $stmt->fetchColumn() > 0;
    }
}

<?php
require_once __DIR__ . '/bootstrap.php';

Auth::requerirLogin();

$pdo        = Database::actual();
$inventario = new InventarioRepo($pdo);
$miSucursal = Auth::sucursalId();
$esCentral  = Auth::esCentral();

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    csrf_validar();

    $productoId = entero($_POST, 'producto_id');
    $cantidad   = entero($_POST, 'cantidad');

    try {
        if ($esCentral) {
            // Central: lo que entra aquí es recepción de mercancía del proveedor.
            $inventario->entradaMercancia($productoId, $cantidad, Auth::empleadoId());
            flash('info', 'Entrada de mercancía registrada.');
        } else {
            // Sucursal: pide reabastecimiento a Central en vez de tocar su propio stock a mano.
            $solicitudes = new SolicitudRepo($pdo);
            $folio = $solicitudes->solicitar($miSucursal, $productoId, $cantidad ?: null, Auth::empleadoId());
            flash('info', $folio > 0
                ? "Solicitud #$folio enviada a Central."
                : 'Ya había una solicitud abierta para ese producto.');
        }
    } catch (Throwable $e) {
        flash('error', $e instanceof PDOException ? Database::mensajeError($e) : $e->getMessage());
    }

    redirigir('inventario.php');
}

$buscar = texto($_GET, 'buscar');
$lista  = $inventario->porSucursal($miSucursal, $buscar);

require_once __DIR__ . '/header.php';
?>

<h2>Inventario — <?= e(Auth::nombreSucursal()) ?></h2>

<?php if (!$esCentral): ?>
    <p class="nota">Aquí ves tu stock local. Para reponer un producto, usa el formulario de la fila: se envía como <strong>solicitud a Central</strong> (no se suma directo, así se mantiene consistente con la replicación). Para vender, usa <a href="ventas.php">Ventas</a>.</p>
<?php else: ?>
    <p class="nota">Central: aquí registras la <strong>entrada de mercancía</strong> del proveedor. Para mandar stock a una sucursal, usa <a href="asignar_stock.php">Asignar stock</a>.</p>
<?php endif; ?>

<form class="barra-busqueda" method="get">
    <input type="text" name="buscar" placeholder="Buscar producto..." value="<?= e($buscar) ?>">
    <button type="submit">Buscar</button>
</form>

<table class="tabla">
    <thead>
        <tr>
            <th>Producto</th><th>Categoría</th>
            <th class="num">Stock</th><th class="num">Mínimo</th>
            <th><?= $esCentral ? 'Registrar entrada' : 'Solicitar reabastecimiento' ?></th>
        </tr>
    </thead>
    <tbody>
    <?php if (!$lista): ?>
        <tr><td colspan="5" class="vacio">Sin resultados.</td></tr>
    <?php endif; ?>
    <?php foreach ($lista as $row): ?>
        <tr class="<?= $row['EnAlerta'] ? 'fila-alerta' : '' ?>">
            <td><?= e($row['Producto']) ?></td>
            <td><?= e($row['Categoria']) ?></td>
            <td class="num"><?= (int) $row['Stock'] ?></td>
            <td class="num"><?= (int) $row['StockMinimo'] ?></td>
            <td>
                <?php if ($row['EstadoSolicitud']): ?>
                    <span class="<?= clase_estado($row['EstadoSolicitud']) ?>"><?= e($row['EstadoSolicitud']) ?></span>
                <?php else: ?>
                    <form method="post" class="form-inline">
                        <?= csrf_campo() ?>
                        <input type="hidden" name="producto_id" value="<?= (int) $row['ProductoID'] ?>">
                        <input type="number" name="cantidad" min="1" value="1" style="width:70px">
                        <button type="submit"><?= $esCentral ? 'Recibir' : 'Pedir' ?></button>
                    </form>
                <?php endif; ?>
            </td>
        </tr>
    <?php endforeach; ?>
    </tbody>
</table>

<?php require_once __DIR__ . '/footer.php'; ?>

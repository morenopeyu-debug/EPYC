<?php
/**
 * Asignación y transferencia de stock — exclusivo de Central.
 *
 * Central empuja mercancía a una sucursal sin que ésta la haya pedido.
 *
 * POR QUÉ NO SE INCREMENTA LA SUCURSAL DE INMEDIATO
 * -------------------------------------------------
 * Bajo replicación de mezcla, la fila de inventario de Monterrey vive en
 * la base de Monterrey. Si Central le sumara stock desde su propia base,
 * ambos sitios estarían escribiendo la misma fila y el Merge Agent
 * tendría que elegir un ganador — que es exactamente el conflicto que
 * este rediseño elimina.
 *
 * Así que la asignación descuenta de Central y queda EN TRÁNSITO. La
 * sucursal la confirma desde su propia base (Requisiciones), que es la
 * única autorizada a incrementar su inventario. Además refleja la
 * realidad: la mercancía viaja, no se teletransporta.
 */
require_once __DIR__ . '/bootstrap.php';

Auth::requerirCentral();

$pdo         = Database::actual();
$productos   = new ProductoRepo($pdo);
$inventario  = new InventarioRepo($pdo);
$solicitudes = new SolicitudRepo($pdo);

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    csrf_validar();

    $productoId = entero($_POST, 'producto_id');
    $sucursalId = entero($_POST, 'sucursal_id');
    $cantidad   = entero($_POST, 'cantidad');
    $comentario = texto($_POST, 'comentario');

    $stockCentral = $productoId > 0 ? $inventario->stockDe(SUCURSAL_CENTRAL, $productoId) : 0;

    if ($productoId <= 0) {
        flash('error', 'Selecciona un producto.');
    } elseif (!isset($nombres_sucursal[$sucursalId]) || $sucursalId === SUCURSAL_CENTRAL) {
        flash('error', 'Selecciona una sucursal destino válida.');
    } elseif ($cantidad <= 0) {
        flash('error', 'La cantidad a enviar debe ser mayor que cero.');
    } elseif ($cantidad > $stockCentral) {
        flash('error', "Central sólo tiene $stockCentral unidades disponibles de ese producto.");
    } else {
        try {
            $folio = $inventario->asignarASucursal(
                $productoId,
                $sucursalId,
                $cantidad,
                Auth::empleadoId(),
                $comentario !== '' ? $comentario : null
            );

            flash('info', sprintf(
                'Envío #%d creado: %d unidades hacia %s. Queda en tránsito hasta que la sucursal lo confirme.',
                $folio,
                $cantidad,
                $nombres_sucursal[$sucursalId]
            ));
        } catch (PDOException $e) {
            flash('error', Database::mensajeError($e));
        }
    }

    redirigir('asignar_stock.php');
}

$conStock  = $productos->listar(SUCURSAL_CENTRAL, ['soloActivos' => true]);
$panorama  = $inventario->panoramaGlobal(texto($_GET, 'buscar'));
$transito  = $solicitudes->enTransito();

require_once __DIR__ . '/header.php';
?>

<h2>Asignar stock a sucursales</h2>

<form method="post" class="formulario formulario-ancho">
    <?= csrf_campo() ?>

    <label for="producto_id">Producto</label>
    <select name="producto_id" id="producto_id" required>
        <option value="">-- Selecciona --</option>
        <?php foreach ($conStock as $p): ?>
            <option value="<?= (int) $p['ProductoID'] ?>" <?= (int) $p['Stock'] === 0 ? 'disabled' : '' ?>>
                <?= e($p['Nombre']) ?> — disponible en Central: <?= (int) $p['Stock'] ?>
            </option>
        <?php endforeach; ?>
    </select>

    <label for="sucursal_id">Sucursal destino</label>
    <select name="sucursal_id" id="sucursal_id" required>
        <option value="">-- Selecciona --</option>
        <?php foreach ($nombres_sucursal as $sid => $nombre): ?>
            <?php if ($sid === SUCURSAL_CENTRAL) continue; ?>
            <option value="<?= $sid ?>"><?= e($nombre) ?></option>
        <?php endforeach; ?>
    </select>

    <label for="cantidad">Cantidad a enviar</label>
    <input type="number" name="cantidad" id="cantidad" min="1" value="1" required>

    <label for="comentario">Comentario para la sucursal</label>
    <input type="text" name="comentario" id="comentario" maxlength="300" placeholder="Opcional">

    <button type="submit">Enviar a la sucursal</button>
</form>

<h3>Envíos en tránsito (esperando confirmación de la sucursal)</h3>

<table class="tabla">
    <thead>
        <tr>
            <th>Folio</th>
            <th>Producto</th>
            <th>Destino</th>
            <th class="num">Enviado</th>
            <th>Origen</th>
            <th>Fecha de envío</th>
        </tr>
    </thead>
    <tbody>
    <?php if (!$transito): ?>
        <tr><td colspan="6" class="vacio">No hay envíos pendientes de confirmar.</td></tr>
    <?php endif; ?>

    <?php foreach ($transito as $t): ?>
        <tr>
            <td>#<?= (int) $t['SolicitudID'] ?></td>
            <td><?= e($t['Producto']) ?></td>
            <td><?= e($t['Sucursal']) ?></td>
            <td class="num"><?= (int) $t['CantidadOfrecida'] ?></td>
            <td><span class="chip"><?= e($t['Origen']) ?></span></td>
            <td><?= fecha_corta($t['FechaOferta']) ?></td>
        </tr>
    <?php endforeach; ?>
    </tbody>
</table>

<h3>Panorama de la red</h3>

<form class="barra-busqueda" method="get">
    <input type="text" name="buscar" placeholder="Filtrar producto..." value="<?= e(texto($_GET, 'buscar')) ?>">
    <button type="submit">Filtrar</button>
</form>

<table class="tabla">
    <thead>
        <tr>
            <th>Producto</th>
            <th class="num">Central</th>
            <th class="num">Monterrey</th>
            <th class="num">Puebla</th>
            <th class="num">Querétaro</th>
            <th class="num">Total en la red</th>
        </tr>
    </thead>
    <tbody>
    <?php if (!$panorama): ?>
        <tr><td colspan="6" class="vacio">Sin datos de inventario.</td></tr>
    <?php endif; ?>

    <?php foreach ($panorama as $fila): ?>
        <tr>
            <td><?= e($fila['Producto']) ?></td>
            <td class="num"><?= (int) $fila['Central'] ?></td>
            <td class="num <?= (int) $fila['Monterrey'] <= UMBRAL_STOCK_BAJO ? 'celda-alerta' : '' ?>"><?= (int) $fila['Monterrey'] ?></td>
            <td class="num <?= (int) $fila['Puebla']    <= UMBRAL_STOCK_BAJO ? 'celda-alerta' : '' ?>"><?= (int) $fila['Puebla'] ?></td>
            <td class="num <?= (int) $fila['Queretaro'] <= UMBRAL_STOCK_BAJO ? 'celda-alerta' : '' ?>"><?= (int) $fila['Queretaro'] ?></td>
            <td class="num"><strong><?= (int) $fila['Total'] ?></strong></td>
        </tr>
    <?php endforeach; ?>
    </tbody>
</table>

<p class="ayuda">
    <?php if (!MODO_DEMO): ?>
        Las cifras de las sucursales reflejan la última sincronización de la replicación de mezcla,
        no el instante actual.
    <?php else: ?>
        En modo demostración las cuatro columnas salen de la misma base, así que están siempre al día.
    <?php endif; ?>
</p>

<?php require_once __DIR__ . '/footer.php'; ?>

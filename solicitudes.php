<?php
/**
 * Módulo de requisiciones. Una sola página, dos caras según el rol.
 *
 * CENTRAL   ve las solicitudes PENDIENTES y responde con la cantidad que
 *           tiene disponible — completa o parcial. Al ofertar, la
 *           mercancía sale de su almacén y queda en tránsito.
 *
 * SUCURSAL  ve las ofertas OFERTADAS y decide: aceptar (el stock entra
 *           oficialmente a su inventario) o rechazar (Central reintegra).
 *
 * Todas las escrituras pasan por procedimientos almacenados; aquí sólo
 * se valida la entrada y se traduce el resultado a un mensaje.
 */
require_once __DIR__ . '/bootstrap.php';

Auth::requerirLogin();

$pdo         = Database::actual();
$solicitudes = new SolicitudRepo($pdo);
$inventario  = new InventarioRepo($pdo);
$esCentralOp = Auth::esCentral();
$miSucursal  = Auth::sucursalId();

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    csrf_validar();

    $accion      = texto($_POST, 'accion');
    $solicitudId = entero($_POST, 'solicitud_id');
    $comentario  = texto($_POST, 'comentario');

    try {
        // ---------- Acciones de Central ----------
        if ($accion === 'ofertar') {
            Auth::requerirCentral();

            $cantidad  = entero($_POST, 'cantidad');
            $solicitud = $solicitudes->obtener($solicitudId);

            if (!$solicitud) {
                flash('error', 'La solicitud no existe.');
            } elseif ($solicitud['Estado'] !== 'PENDIENTE') {
                flash('error', 'Esa solicitud ya fue atendida.');
            } elseif ($cantidad <= 0) {
                flash('error', 'La cantidad a enviar debe ser mayor que cero.');
            } elseif ($cantidad > (int) $solicitud['CantidadSolicitada']) {
                flash('error', 'No puedes enviar más de lo solicitado (' . (int) $solicitud['CantidadSolicitada'] . ' unidades).');
            } elseif ($cantidad > (int) $solicitud['StockCentral']) {
                flash('error', 'Central sólo tiene ' . (int) $solicitud['StockCentral'] . ' unidades disponibles.');
            } else {
                $solicitudes->ofertar($solicitudId, $cantidad, Auth::empleadoId(), $comentario);

                $parcial = $cantidad < (int) $solicitud['CantidadSolicitada'];
                flash('info', sprintf(
                    'Envío %s de %d unidades a %s (solicitud #%d). Queda en espera de que la sucursal lo acepte.',
                    $parcial ? 'PARCIAL' : 'completo',
                    $cantidad,
                    $solicitud['Sucursal'],
                    $solicitudId
                ));
            }
        } elseif ($accion === 'reintegrar') {
            Auth::requerirCentral();

            $solicitudes->reintegrar($solicitudId, Auth::empleadoId());
            flash('info', "Stock de la solicitud #$solicitudId reintegrado al almacén central.");

        // ---------- Acciones de sucursal ----------
        } elseif ($accion === 'aceptar' || $accion === 'rechazar') {
            Auth::requerirSucursal();

            // Impide responder envíos dirigidos a otra sucursal.
            if (!$solicitudes->perteneceA($solicitudId, $miSucursal)) {
                flash('error', 'Esa solicitud no pertenece a tu sucursal.');
            } else {
                $aceptar = ($accion === 'aceptar');
                $solicitudes->responder($solicitudId, $aceptar, Auth::empleadoId(), $comentario);

                if ($aceptar) {
                    $s = $solicitudes->obtener($solicitudId);
                    flash('info', sprintf(
                        'Recepción confirmada: +%d unidades de %s. Stock actual en tu sucursal: %d.',
                        (int) $s['CantidadOfrecida'],
                        $s['Producto'],
                        (int) $s['StockSucursal']
                    ));
                } else {
                    flash('info', "Envío #$solicitudId rechazado. Central recuperará la mercancía apartada.");
                }
            }
        } elseif ($accion === 'solicitar') {
            Auth::requerirSucursal();

            $productoId = entero($_POST, 'producto_id');
            $cantidad   = entero($_POST, 'cantidad');

            if ($productoId <= 0) {
                flash('error', 'Selecciona un producto.');
            } elseif ($cantidad <= 0) {
                flash('error', 'La cantidad solicitada debe ser mayor que cero.');
            } else {
                $folio = $solicitudes->solicitar($miSucursal, $productoId, $cantidad, Auth::empleadoId(), $comentario);

                if ($folio > 0) {
                    flash('info', "Solicitud #$folio enviada a Central.");
                } else {
                    flash('error', 'Ya tienes una solicitud abierta de ese producto. Espera la respuesta de Central.');
                }
            }
        } else {
            flash('error', 'Acción no reconocida.');
        }
    } catch (PDOException $e) {
        flash('error', Database::mensajeError($e));
    }

    redirigir('solicitudes.php');
}

// ---------------------------------------------------------------------
// Datos para pintar
// ---------------------------------------------------------------------
if ($esCentralOp) {
    $pendientes = $solicitudes->pendientesParaCentral();
    $transito   = $solicitudes->enTransito();
    $porCobrar  = $solicitudes->rechazadasSinReintegrar();
    $historial  = $solicitudes->historial(null, 40);
} else {
    $ofertas    = $solicitudes->ofertasPara($miSucursal);
    $misPend    = $solicitudes->pendientesDe($miSucursal);
    $historial  = $solicitudes->historial($miSucursal, 40);
    $catalogo   = (new ProductoRepo($pdo))->listar($miSucursal, ['soloActivos' => true]);
}

require_once __DIR__ . '/header.php';
?>

<?php if ($esCentralOp): ?>

    <h2>Requisiciones de las sucursales</h2>

    <p class="nota">
        Si no tienes el total pedido, envía lo que sí tengas: escribe la cantidad disponible
        y la sucursal decidirá si acepta el envío parcial. La mercancía sale de Central al
        momento de enviarla y regresa sola si la rechazan.
    </p>

    <h3>Pendientes de atender <?= $pendientes ? '(' . count($pendientes) . ')' : '' ?></h3>

    <table class="tabla">
        <thead>
            <tr>
                <th>Folio</th>
                <th>Sucursal</th>
                <th>Producto</th>
                <th class="num">Pide</th>
                <th class="num">Su stock</th>
                <th class="num">Hay en Central</th>
                <th>Origen</th>
                <th>Responder</th>
            </tr>
        </thead>
        <tbody>
        <?php if (!$pendientes): ?>
            <tr><td colspan="8" class="vacio">No hay solicitudes pendientes. 🎉</td></tr>
        <?php endif; ?>

        <?php foreach ($pendientes as $s): ?>
            <?php
                $pedido    = (int) $s['CantidadSolicitada'];
                $disponible = (int) $s['StockCentral'];
                $sugerido  = min($pedido, $disponible);
                $insuficiente = $disponible < $pedido;
            ?>
            <tr class="<?= $insuficiente ? 'fila-alerta' : '' ?>">
                <td>#<?= (int) $s['SolicitudID'] ?></td>
                <td><?= e($s['Sucursal']) ?></td>
                <td>
                    <?= e($s['Producto']) ?>
                    <?php if ($s['ComentarioSucursal']): ?>
                        <div class="ayuda">«<?= e($s['ComentarioSucursal']) ?>»</div>
                    <?php endif; ?>
                </td>
                <td class="num"><strong><?= $pedido ?></strong></td>
                <td class="num"><?= (int) $s['StockAlSolicitar'] ?></td>
                <td class="num <?= $insuficiente ? 'celda-alerta' : '' ?>"><?= $disponible ?></td>
                <td><span class="chip"><?= e($s['Origen']) ?></span></td>
                <td>
                    <?php if ($disponible === 0): ?>
                        <span class="ayuda">Sin existencias en Central. Registra una
                            <a href="entrada_mercancia.php">entrada de mercancía</a>.</span>
                    <?php else: ?>
                        <form method="post" class="form-inline">
                            <?= csrf_campo() ?>
                            <input type="hidden" name="accion" value="ofertar">
                            <input type="hidden" name="solicitud_id" value="<?= (int) $s['SolicitudID'] ?>">
                            <input type="number" name="cantidad" min="1" max="<?= $sugerido ?>"
                                   value="<?= $sugerido ?>" style="width:70px" required>
                            <input type="text" name="comentario" maxlength="300" placeholder="Nota (opcional)" style="width:150px">
                            <button type="submit"><?= $insuficiente ? 'Enviar parcial' : 'Enviar' ?></button>
                        </form>
                        <?php if ($insuficiente): ?>
                            <div class="ayuda">Sólo alcanza para <?= $disponible ?> de <?= $pedido ?>.</div>
                        <?php endif; ?>
                    <?php endif; ?>
                </td>
            </tr>
        <?php endforeach; ?>
        </tbody>
    </table>

    <h3>En tránsito <?= $transito ? '(' . count($transito) . ')' : '' ?></h3>

    <table class="tabla">
        <thead>
            <tr>
                <th>Folio</th><th>Sucursal</th><th>Producto</th>
                <th class="num">Pedido</th><th class="num">Enviado</th><th>Enviado el</th>
            </tr>
        </thead>
        <tbody>
        <?php if (!$transito): ?>
            <tr><td colspan="6" class="vacio">Nada en tránsito.</td></tr>
        <?php endif; ?>

        <?php foreach ($transito as $s): ?>
            <tr>
                <td>#<?= (int) $s['SolicitudID'] ?></td>
                <td><?= e($s['Sucursal']) ?></td>
                <td><?= e($s['Producto']) ?></td>
                <td class="num"><?= (int) $s['CantidadSolicitada'] ?></td>
                <td class="num">
                    <?= (int) $s['CantidadOfrecida'] ?>
                    <?php if ((int) $s['CantidadOfrecida'] < (int) $s['CantidadSolicitada']): ?>
                        <span class="chip chip-ofertado">parcial</span>
                    <?php endif; ?>
                </td>
                <td><?= fecha_corta($s['FechaOferta']) ?></td>
            </tr>
        <?php endforeach; ?>
        </tbody>
    </table>

    <h3>Rechazados — stock por reintegrar <?= $porCobrar ? '(' . count($porCobrar) . ')' : '' ?></h3>

    <?php if ($porCobrar): ?>
        <p class="nota">
            La sucursal rechazó estos envíos. La mercancía ya había salido del almacén central;
            reintégrala para que vuelva a contar como existencia disponible.
        </p>
    <?php endif; ?>

    <table class="tabla">
        <thead>
            <tr><th>Folio</th><th>Sucursal</th><th>Producto</th><th class="num">Cantidad</th><th>Motivo</th><th>Acción</th></tr>
        </thead>
        <tbody>
        <?php if (!$porCobrar): ?>
            <tr><td colspan="6" class="vacio">No hay reintegros pendientes.</td></tr>
        <?php endif; ?>

        <?php foreach ($porCobrar as $s): ?>
            <tr class="fila-alerta">
                <td>#<?= (int) $s['SolicitudID'] ?></td>
                <td><?= e($s['Sucursal']) ?></td>
                <td><?= e($s['Producto']) ?></td>
                <td class="num"><?= (int) $s['CantidadOfrecida'] ?></td>
                <td><?= e($s['ComentarioSucursal'] ?? '—') ?></td>
                <td>
                    <form method="post" class="form-inline">
                        <?= csrf_campo() ?>
                        <input type="hidden" name="accion" value="reintegrar">
                        <input type="hidden" name="solicitud_id" value="<?= (int) $s['SolicitudID'] ?>">
                        <button type="submit">Reintegrar a Central</button>
                    </form>
                </td>
            </tr>
        <?php endforeach; ?>
        </tbody>
    </table>

<?php else: ?>

    <h2>Mis solicitudes — <?= e(Auth::nombreSucursal()) ?></h2>

    <h3>Envíos esperando tu decisión <?= $ofertas ? '(' . count($ofertas) . ')' : '' ?></h3>

    <?php if ($ofertas): ?>
        <p class="nota">
            Central respondió. Revisa la cantidad: <strong>al aceptar, el stock se suma
            oficialmente al inventario de tu sucursal</strong>. Si rechazas, la mercancía
            regresa a Central.
        </p>
    <?php endif; ?>

    <table class="tabla">
        <thead>
            <tr>
                <th>Folio</th><th>Producto</th>
                <th class="num">Pediste</th><th class="num">Te envían</th>
                <th>Nota de Central</th><th>Decisión</th>
            </tr>
        </thead>
        <tbody>
        <?php if (!$ofertas): ?>
            <tr><td colspan="6" class="vacio">No tienes envíos por confirmar.</td></tr>
        <?php endif; ?>

        <?php foreach ($ofertas as $s): ?>
            <?php
                $pedido   = (int) $s['CantidadSolicitada'];
                $ofrecido = (int) $s['CantidadOfrecida'];
                $parcial  = $ofrecido < $pedido;
            ?>
            <tr class="<?= $parcial ? 'fila-alerta' : '' ?>">
                <td>#<?= (int) $s['SolicitudID'] ?></td>
                <td><?= e($s['Producto']) ?><?= $s['Marca'] ? ' — ' . e($s['Marca']) : '' ?></td>
                <td class="num"><?= $s['Origen'] === 'ENVIO_CENTRAL' ? '—' : $pedido ?></td>
                <td class="num">
                    <strong><?= $ofrecido ?></strong>
                    <?php if ($parcial && $s['Origen'] !== 'ENVIO_CENTRAL'): ?>
                        <span class="chip chip-ofertado">parcial</span>
                    <?php endif; ?>
                </td>
                <td>
                    <?= e($s['ComentarioCentral'] ?? '—') ?>
                    <div class="ayuda">Enviado el <?= fecha_corta($s['FechaOferta']) ?></div>
                </td>
                <td>
                    <form method="post" class="form-inline">
                        <?= csrf_campo() ?>
                        <input type="hidden" name="solicitud_id" value="<?= (int) $s['SolicitudID'] ?>">
                        <input type="text" name="comentario" maxlength="300" placeholder="Comentario" style="width:130px">
                        <button type="submit" name="accion" value="aceptar">Aceptar</button>
                        <button type="submit" name="accion" value="rechazar" class="btn-peligro"
                                onclick="return confirm('¿Rechazar este envío? La mercancía volverá a Central.');">Rechazar</button>
                    </form>
                </td>
            </tr>
        <?php endforeach; ?>
        </tbody>
    </table>

    <h3>Esperando respuesta de Central <?= $misPend ? '(' . count($misPend) . ')' : '' ?></h3>

    <table class="tabla">
        <thead>
            <tr><th>Folio</th><th>Producto</th><th class="num">Pedido</th><th class="num">Tu stock</th><th>Origen</th><th>Fecha</th></tr>
        </thead>
        <tbody>
        <?php if (!$misPend): ?>
            <tr><td colspan="6" class="vacio">No tienes solicitudes pendientes.</td></tr>
        <?php endif; ?>

        <?php foreach ($misPend as $s): ?>
            <tr>
                <td>#<?= (int) $s['SolicitudID'] ?></td>
                <td><?= e($s['Producto']) ?></td>
                <td class="num"><?= (int) $s['CantidadSolicitada'] ?></td>
                <td class="num"><?= (int) $s['StockSucursal'] ?></td>
                <td>
                    <span class="chip"><?= e($s['Origen']) ?></span>
                    <?php if ($s['Origen'] === 'AUTOMATICA'): ?>
                        <div class="ayuda">Generada por alerta de stock bajo</div>
                    <?php endif; ?>
                </td>
                <td><?= fecha_corta($s['FechaSolicitud']) ?></td>
            </tr>
        <?php endforeach; ?>
        </tbody>
    </table>

    <h3>Pedir reabastecimiento</h3>

    <form method="post" class="formulario formulario-ancho">
        <?= csrf_campo() ?>
        <input type="hidden" name="accion" value="solicitar">

        <label for="producto_id">Producto</label>
        <select name="producto_id" id="producto_id" required>
            <option value="">-- Selecciona --</option>
            <?php foreach ($catalogo as $p): ?>
                <option value="<?= (int) $p['ProductoID'] ?>">
                    <?= e($p['Nombre']) ?> (tienes <?= (int) $p['Stock'] ?>)
                </option>
            <?php endforeach; ?>
        </select>

        <label for="cantidad">Cantidad que necesitas</label>
        <input type="number" name="cantidad" id="cantidad" min="1" value="10" required>

        <label for="comentario">Comentario para Central</label>
        <input type="text" name="comentario" id="comentario" maxlength="300" placeholder="Opcional">

        <button type="submit">Enviar solicitud</button>
    </form>

<?php endif; ?>

<h3>Historial</h3>

<table class="tabla">
    <thead>
        <tr>
            <th>Folio</th>
            <?php if ($esCentralOp): ?><th>Sucursal</th><?php endif; ?>
            <th>Producto</th>
            <th class="num">Pedido</th>
            <th class="num">Enviado</th>
            <th>Estado</th>
            <th>Solicitado</th>
            <th>Resuelto</th>
        </tr>
    </thead>
    <tbody>
    <?php if (!$historial): ?>
        <tr><td colspan="<?= $esCentralOp ? 8 : 7 ?>" class="vacio">Todavía no hay requisiciones registradas.</td></tr>
    <?php endif; ?>

    <?php foreach ($historial as $s): ?>
        <tr>
            <td>#<?= (int) $s['SolicitudID'] ?></td>
            <?php if ($esCentralOp): ?><td><?= e($s['Sucursal']) ?></td><?php endif; ?>
            <td><?= e($s['Producto']) ?></td>
            <td class="num"><?= (int) $s['CantidadSolicitada'] ?></td>
            <td class="num"><?= $s['CantidadOfrecida'] === null ? '—' : (int) $s['CantidadOfrecida'] ?></td>
            <td><span class="<?= clase_estado($s['Estado']) ?>"><?= e($s['Estado']) ?></span></td>
            <td><?= fecha_corta($s['FechaSolicitud']) ?></td>
            <td><?= fecha_corta($s['FechaRespuesta']) ?></td>
        </tr>
    <?php endforeach; ?>
    </tbody>
</table>

<?php require_once __DIR__ . '/footer.php'; ?>

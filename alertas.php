<?php
/**
 * Control de alertas de stock bajo — exclusivo de sucursales.
 *
 * El disparo es automático: el trigger trg_InvSuc_AlertaStockBajo crea
 * la requisición en cuanto una venta deja el producto en el punto de
 * reorden o por debajo. Esta pantalla sirve para ver el panorama, ajustar
 * los umbrales y forzar el barrido si algo se movió por fuera de la
 * aplicación (una carga masiva, un ajuste hecho a mano en la base).
 */
require_once __DIR__ . '/bootstrap.php';

Auth::requerirSucursal();

$pdo         = Database::actual();
$inventario  = new InventarioRepo($pdo);
$solicitudes = new SolicitudRepo($pdo);

$miSucursal = Auth::sucursalId();

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    csrf_validar();

    $accion = texto($_POST, 'accion');

    try {
        if ($accion === 'barrer') {
            $generadas = $inventario->generarAlertas($miSucursal, Auth::empleadoId());

            flash(
                'info',
                $generadas > 0
                    ? ($generadas === 1 ? 'Se generó ' : 'Se generaron ')
                        . pluralizar($generadas, 'solicitud', 'solicitudes')
                        . ' de reabastecimiento hacia Central.'
                    : 'Todo en orden: no hay productos bajo el mínimo sin una solicitud abierta.'
            );
        } elseif ($accion === 'ajustar') {
            $productoId = entero($_POST, 'producto_id');
            $minimo     = entero($_POST, 'stock_minimo');
            $objetivo   = entero($_POST, 'stock_objetivo');

            $inventario->ajustarNiveles($miSucursal, $productoId, $minimo, $objetivo);
            flash('info', 'Niveles actualizados.');
        } elseif ($accion === 'solicitar') {
            $productoId = entero($_POST, 'producto_id');
            $cantidad   = entero($_POST, 'cantidad');

            $folio = $solicitudes->solicitar($miSucursal, $productoId, $cantidad ?: null, Auth::empleadoId());

            flash(
                'info',
                $folio > 0
                    ? "Solicitud #$folio enviada a Central."
                    : 'Ya existe una solicitud abierta de ese producto.'
            );
        }
    } catch (InvalidArgumentException $e) {
        flash('error', $e->getMessage());
    } catch (PDOException $e) {
        flash('error', Database::mensajeError($e));
    }

    redirigir('alertas.php');
}

$enAlerta = $inventario->porSucursal($miSucursal, '', true);
$todo     = $inventario->porSucursal($miSucursal);

require_once __DIR__ . '/header.php';
?>

<h2>Alertas de stock — <?= e(Auth::nombreSucursal()) ?></h2>

<p class="nota">
    Un producto entra en alerta cuando su existencia baja a <strong>su punto de reorden o menos</strong>
    (<?= UMBRAL_STOCK_BAJO ?> unidades por omisión). El sistema genera la solicitud a Central
    automáticamente en cuanto ocurre; aquí puedes verificarlo y ajustar los umbrales de tu sucursal.
</p>

<form method="post" class="form-inline barra-busqueda">
    <?= csrf_campo() ?>
    <input type="hidden" name="accion" value="barrer">
    <button type="submit">Revisar y generar solicitudes faltantes</button>
</form>

<h3>Productos en nivel bajo <?= $enAlerta ? '(' . count($enAlerta) . ')' : '' ?></h3>

<table class="tabla">
    <thead>
        <tr>
            <th>Producto</th>
            <th class="num">Stock</th>
            <th class="num">Punto de reorden</th>
            <th>Solicitud</th>
            <th>Pedir ahora</th>
        </tr>
    </thead>
    <tbody>
    <?php if (!$enAlerta): ?>
        <tr><td colspan="5" class="vacio">Ningún producto está en nivel bajo. 👍</td></tr>
    <?php endif; ?>

    <?php foreach ($enAlerta as $p): ?>
        <tr class="fila-alerta">
            <td><?= e($p['Producto']) ?><?= $p['Marca'] ? ' — ' . e($p['Marca']) : '' ?></td>
            <td class="num"><strong><?= (int) $p['Stock'] ?></strong></td>
            <td class="num"><?= (int) $p['StockMinimo'] ?></td>
            <td>
                <?php if ($p['EstadoSolicitud']): ?>
                    <span class="<?= clase_estado($p['EstadoSolicitud']) ?>"><?= e($p['EstadoSolicitud']) ?></span>
                <?php else: ?>
                    <span class="ayuda">sin solicitud</span>
                <?php endif; ?>
            </td>
            <td>
                <?php if ($p['EstadoSolicitud']): ?>
                    <a href="solicitudes.php">Ver en requisiciones</a>
                <?php else: ?>
                    <form method="post" class="form-inline">
                        <?= csrf_campo() ?>
                        <input type="hidden" name="accion" value="solicitar">
                        <input type="hidden" name="producto_id" value="<?= (int) $p['ProductoID'] ?>">
                        <input type="number" name="cantidad" min="1" style="width:70px"
                               value="<?= max(1, (int) $p['StockObjetivo'] - (int) $p['Stock']) ?>">
                        <button type="submit">Solicitar</button>
                    </form>
                <?php endif; ?>
            </td>
        </tr>
    <?php endforeach; ?>
    </tbody>
</table>

<h3>Umbrales de tu sucursal</h3>

<p class="ayuda">
    El punto de reorden y el objetivo son <em>por sucursal</em>: Monterrey puede querer alertarse
    a las 5 piezas y Puebla a las 12, sin tocar el catálogo maestro de Central.
</p>

<table class="tabla">
    <thead>
        <tr>
            <th>Producto</th>
            <th class="num">Stock</th>
            <th>Punto de reorden / objetivo</th>
        </tr>
    </thead>
    <tbody>
    <?php if (!$todo): ?>
        <tr><td colspan="3" class="vacio">No hay productos en tu inventario.</td></tr>
    <?php endif; ?>

    <?php foreach ($todo as $p): ?>
        <tr class="<?= (int) $p['EnAlerta'] === 1 ? 'fila-alerta' : '' ?>">
            <td><?= e($p['Producto']) ?></td>
            <td class="num"><?= (int) $p['Stock'] ?></td>
            <td>
                <form method="post" class="form-inline">
                    <?= csrf_campo() ?>
                    <input type="hidden" name="accion" value="ajustar">
                    <input type="hidden" name="producto_id" value="<?= (int) $p['ProductoID'] ?>">
                    <input type="number" name="stock_minimo"   min="0" style="width:70px" value="<?= (int) $p['StockMinimo'] ?>" title="Punto de reorden">
                    <span class="ayuda">→</span>
                    <input type="number" name="stock_objetivo" min="0" style="width:70px" value="<?= (int) $p['StockObjetivo'] ?>" title="Reabastecer hasta">
                    <button type="submit">Guardar</button>
                </form>
            </td>
        </tr>
    <?php endforeach; ?>
    </tbody>
</table>

<?php require_once __DIR__ . '/footer.php'; ?>

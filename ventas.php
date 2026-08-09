<?php
/**
 * Simulación de ventas — exclusivo de sucursales.
 *
 * Selecciona producto, captura cantidad y procesa: el stock de ESTA
 * sucursal se descuenta de inmediato. Si con la venta el producto cae al
 * punto de reorden o por debajo, el trigger de la base levanta sola la
 * solicitud de reabastecimiento hacia Central.
 */
require_once __DIR__ . '/bootstrap.php';

Auth::requerirSucursal();

$pdo        = Database::actual();
$productos  = new ProductoRepo($pdo);
$ventas     = new VentaRepo($pdo);
$inventario = new InventarioRepo($pdo);

$miSucursal = Auth::sucursalId();

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    csrf_validar();

    $productoId = entero($_POST, 'producto_id');
    $cantidad   = entero($_POST, 'cantidad');

    if ($productoId <= 0) {
        flash('error', 'Selecciona un producto.');
    } elseif ($cantidad <= 0) {
        flash('error', 'La cantidad vendida debe ser mayor que cero.');
    } else {
        try {
            // La validación de existencias real vive en el procedimiento,
            // dentro de la misma transacción que descuenta. Esta previa
            // solo sirve para dar un mensaje más claro.
            $disponible = $inventario->stockDe($miSucursal, $productoId);

            if ($cantidad > $disponible) {
                flash('error', 'Solo tienes ' . pluralizar($disponible, 'unidad', 'unidades')
                    . ' de ese producto en existencia.');
            } else {
                $resultado = $ventas->registrar($miSucursal, $productoId, $cantidad, Auth::empleadoId());

                $restante = (int) $resultado['StockResultante'];

                $mensaje = sprintf(
                    'Venta #%d registrada por $%s. %s %s.',
                    $resultado['VentaID'],
                    number_format((float) $resultado['Total'], 2),
                    $restante === 1 ? 'Queda' : 'Quedan',
                    pluralizar($restante, 'unidad', 'unidades')
                );

                if ($resultado['StockResultante'] <= UMBRAL_STOCK_BAJO) {
                    $mensaje .= ' ⚠ El producto quedó en nivel bajo: se generó una solicitud automática a Central.';
                }

                flash('info', $mensaje);
            }
        } catch (PDOException $e) {
            flash('error', Database::mensajeError($e));
        }
    }

    redirigir('ventas.php');
}

$disponibles = $productos->conStockEn($miSucursal);
$ultimas     = $ventas->ultimas($miSucursal, 15);
$resumen     = $ventas->totalDelDia($miSucursal);

require_once __DIR__ . '/header.php';
?>

<h2>Punto de venta — <?= e(Auth::nombreSucursal()) ?></h2>

<div class="tarjetas">
    <div class="tarjeta">
        <span class="tarjeta-valor"><?= (int) $resumen['Operaciones'] ?></span>
        <span class="tarjeta-etiqueta">ventas hoy</span>
    </div>
    <div class="tarjeta">
        <span class="tarjeta-valor">$<?= number_format((float) $resumen['Importe'], 2) ?></span>
        <span class="tarjeta-etiqueta">importe del día</span>
    </div>
    <div class="tarjeta">
        <span class="tarjeta-valor"><?= $inventario->contarAlertas($miSucursal) ?></span>
        <span class="tarjeta-etiqueta">productos en nivel bajo</span>
    </div>
</div>

<form method="post" class="formulario formulario-ancho">
    <?= csrf_campo() ?>

    <label for="producto_id">Producto</label>
    <select name="producto_id" id="producto_id" required>
        <option value="">-- Selecciona --</option>
        <?php foreach ($disponibles as $p): ?>
            <option value="<?= (int) $p['ProductoID'] ?>" data-stock="<?= (int) $p['Stock'] ?>">
                <?= e($p['Nombre']) ?><?= $p['Marca'] ? ' — ' . e($p['Marca']) : '' ?>
                · $<?= number_format((float) $p['PrecioUnitario'], 2) ?>
                · <?= (int) $p['Stock'] === 1 ? '1 disponible' : (int) $p['Stock'] . ' disponibles' ?>
            </option>
        <?php endforeach; ?>
    </select>

    <label for="cantidad">Cantidad vendida</label>
    <input type="number" name="cantidad" id="cantidad" min="1" value="1" required>

    <button type="submit">Procesar venta</button>
</form>

<?php if (!$disponibles): ?>
    <p class="nota">
        No tienes existencias de ningún producto. Revisa tus
        <a href="alertas.php">alertas de stock</a> o pide reabastecimiento en
        <a href="solicitudes.php">Mis solicitudes</a>.
    </p>
<?php endif; ?>

<h3>Últimas ventas</h3>

<table class="tabla">
    <thead>
        <tr>
            <th>Folio</th><th>Fecha</th><th>Producto</th>
            <th class="num">Cantidad</th><th class="num">Precio</th><th class="num">Total</th><th>Atendió</th>
        </tr>
    </thead>
    <tbody>
    <?php if (!$ultimas): ?>
        <tr><td colspan="7" class="vacio">Todavía no se registran ventas en esta sucursal.</td></tr>
    <?php endif; ?>

    <?php foreach ($ultimas as $v): ?>
        <tr>
            <td>#<?= (int) $v['VentaID'] ?></td>
            <td><?= fecha_corta($v['Fecha']) ?></td>
            <td><?= e($v['Producto']) ?></td>
            <td class="num"><?= (int) $v['Cantidad'] ?></td>
            <td class="num">$<?= number_format((float) $v['PrecioUnitario'], 2) ?></td>
            <td class="num">$<?= number_format((float) $v['Total'], 2) ?></td>
            <td><?= e($v['Empleado']) ?></td>
        </tr>
    <?php endforeach; ?>
    </tbody>
</table>

<script>
// Ajusta el tope del campo cantidad al stock del producto elegido, para
// que el navegador avise antes de mandar el formulario al servidor.
document.getElementById('producto_id').addEventListener('change', function () {
    var opcion = this.options[this.selectedIndex];
    var stock  = opcion ? opcion.getAttribute('data-stock') : null;
    var campo  = document.getElementById('cantidad');

    if (stock) {
        campo.max = stock;
        if (parseInt(campo.value, 10) > parseInt(stock, 10)) {
            campo.value = stock;
        }
    } else {
        campo.removeAttribute('max');
    }
});
</script>

<?php require_once __DIR__ . '/footer.php'; ?>

<?php
/**
 * Entrada de mercancía — exclusivo de Central.
 *
 * Recepción del proveedor: producto nuevo o reabastecimiento. Es el
 * único punto por donde el stock ENTRA a la red; de aquí en adelante
 * sólo se mueve (Central → sucursal) o se consume (venta).
 */
require_once __DIR__ . '/bootstrap.php';

Auth::requerirCentral();

$pdo         = Database::actual();
$productos   = new ProductoRepo($pdo);
$inventario  = new InventarioRepo($pdo);

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    csrf_validar();

    $productoId = entero($_POST, 'producto_id');
    $cantidad   = entero($_POST, 'cantidad');
    $referencia = texto($_POST, 'referencia');

    if ($productoId <= 0) {
        flash('error', 'Selecciona un producto.');
    } elseif ($cantidad <= 0) {
        flash('error', 'La cantidad recibida debe ser mayor que cero.');
    } elseif ($cantidad > 100000) {
        flash('error', 'La cantidad recibida parece un error de captura (máximo 100,000 por entrada).');
    } else {
        try {
            $nuevoStock = $inventario->entradaMercancia(
                $productoId,
                $cantidad,
                Auth::empleadoId(),
                $referencia !== '' ? $referencia : null
            );

            flash('info', "Entrada registrada: +$cantidad unidades. Stock en Central: $nuevoStock.");
        } catch (PDOException $e) {
            flash('error', Database::mensajeError($e));
        }
    }

    redirigir('entrada_mercancia.php');
}

// Catálogo completo activo: aquí sí interesan los productos en cero,
// porque son justo los que hay que recibir.
$lista = $productos->listar(SUCURSAL_CENTRAL, ['soloActivos' => true]);

require_once __DIR__ . '/header.php';
?>

<h2>Entrada de mercancía</h2>

<p class="nota">
    Recepción total del stock que llega del proveedor. Suma al almacén de <strong>Central</strong>.
    Para mover producto hacia las sucursales usa <a href="asignar_stock.php">Asignar stock</a>
    o atiende las <a href="solicitudes.php">requisiciones</a>.
</p>

<form method="post" class="formulario formulario-ancho">
    <?= csrf_campo() ?>

    <label for="producto_id">Producto</label>
    <select name="producto_id" id="producto_id" required>
        <option value="">-- Selecciona el producto recibido --</option>
        <?php foreach ($lista as $p): ?>
            <option value="<?= (int) $p['ProductoID'] ?>">
                <?= e($p['Nombre']) ?><?= $p['Marca'] ? ' — ' . e($p['Marca']) : '' ?>
                (stock actual: <?= (int) $p['Stock'] ?>)
            </option>
        <?php endforeach; ?>
    </select>

    <label for="cantidad">Cantidad recibida</label>
    <input type="number" name="cantidad" id="cantidad" min="1" max="100000" value="1" required>

    <label for="referencia">Referencia (factura, remisión, nota)</label>
    <input type="text" name="referencia" id="referencia" maxlength="200" placeholder="Opcional">

    <button type="submit">Registrar entrada</button>
</form>

<h3>Existencias en el almacén central</h3>

<table class="tabla">
    <thead>
        <tr>
            <th>Producto</th>
            <th>Marca</th>
            <th>Categoría</th>
            <th class="num">Precio</th>
            <th class="num">Stock en Central</th>
        </tr>
    </thead>
    <tbody>
    <?php if (!$lista): ?>
        <tr><td colspan="5" class="vacio">No hay productos activos en el catálogo.</td></tr>
    <?php endif; ?>

    <?php foreach ($lista as $p): ?>
        <tr class="<?= (int) $p['Stock'] === 0 ? 'fila-alerta' : '' ?>">
            <td><?= e($p['Nombre']) ?></td>
            <td><?= e($p['Marca'] ?? '—') ?></td>
            <td><?= e($p['Categoria']) ?></td>
            <td class="num">$<?= number_format((float) $p['PrecioUnitario'], 2) ?></td>
            <td class="num"><?= (int) $p['Stock'] ?></td>
        </tr>
    <?php endforeach; ?>
    </tbody>
</table>

<?php require_once __DIR__ . '/footer.php'; ?>

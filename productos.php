<?php
require_once __DIR__ . '/bootstrap.php';

Auth::requerirLogin();

$pdo       = Database::actual();
$productos = new ProductoRepo($pdo);
$esCentral = Auth::esCentral();
$miSucursal = Auth::sucursalId();

$buscar      = texto($_GET, 'buscar');
$categoriaId = entero($_GET, 'categoria');
$tipoMascota = texto($_GET, 'tipo');

$filtros = array_filter([
    'buscar'    => $buscar,
    'categoria' => $categoriaId ?: null,
    'tipo'      => $tipoMascota,
], static fn($v) => $v !== null && $v !== '' && $v !== 0);

$lista      = $productos->listar($miSucursal, $filtros);
$categorias = $productos->categorias();

require_once __DIR__ . '/header.php';
?>

<h2>Productos</h2>

<form class="barra-busqueda" method="get">
    <input type="text" name="buscar" placeholder="Buscar por nombre..." value="<?= e($buscar) ?>">
    <select name="categoria">
        <option value="0">Todas las categorías</option>
        <?php foreach ($categorias as $c): ?>
            <option value="<?= (int) $c['CategoriaID'] ?>" <?= ($categoriaId === (int) $c['CategoriaID']) ? 'selected' : '' ?>>
                <?= e($c['Nombre']) ?>
            </option>
        <?php endforeach; ?>
    </select>
    <select name="tipo">
        <option value="">Perro y gato</option>
        <option value="Perro" <?= ($tipoMascota === 'Perro') ? 'selected' : '' ?>>Solo perro</option>
        <option value="Gato" <?= ($tipoMascota === 'Gato') ? 'selected' : '' ?>>Solo gato</option>
        <option value="Ambos" <?= ($tipoMascota === 'Ambos') ? 'selected' : '' ?>>Ambos</option>
    </select>
    <button type="submit">Buscar</button>
    <?php if ($esCentral): ?>
        <a class="btn-nuevo" href="producto_form.php">+ Nuevo producto</a>
    <?php endif; ?>
</form>

<?php if (!$esCentral): ?>
    <p class="nota">Solo la sucursal Central puede dar de alta, editar o dar de baja productos del catálogo. Aquí puedes consultar el catálogo y el stock de tu sucursal.</p>
<?php endif; ?>

<table class="tabla">
    <thead>
        <tr>
            <th>Código</th>
            <th>Producto</th>
            <th>Categoría</th>
            <th>Mascota</th>
            <th>Marca</th>
            <th>Talla</th>
            <th>Precio</th>
            <th class="num">Stock</th>
            <?php if ($esCentral): ?><th>Acciones</th><?php endif; ?>
        </tr>
    </thead>
    <tbody>
    <?php if (!$lista): ?>
        <tr><td colspan="<?= $esCentral ? 9 : 8 ?>" class="vacio">Sin resultados.</td></tr>
    <?php endif; ?>
    <?php foreach ($lista as $row): ?>
        <tr class="<?= $row['Activo'] ? '' : 'fila-inactiva' ?> <?= $row['Stock'] <= $row['StockMinimo'] ? 'fila-alerta' : '' ?>">
            <td class="codigo"><?= e(codigo_producto((int) $row['ProductoID'])) ?></td>
            <td><?= e($row['Nombre']) ?></td>
            <td><?= e($row['Categoria']) ?></td>
            <td><?= e($row['TipoMascota']) ?></td>
            <td><?= e($row['Marca'] ?? '') ?></td>
            <td><?= e($row['Talla'] ?? '-') ?></td>
            <td>$<?= number_format((float) $row['PrecioUnitario'], 2) ?></td>
            <td class="num"><?= (int) $row['Stock'] ?></td>
            <?php if ($esCentral): ?>
            <td>
                <a href="producto_form.php?id=<?= (int) $row['ProductoID'] ?>">Editar</a>
                <?php if ($row['Activo']): ?>
                    | <a href="producto_eliminar.php?id=<?= (int) $row['ProductoID'] ?>" onclick="return confirm('¿Dar de baja este producto?');">Baja</a>
                <?php else: ?>
                    | <a href="producto_eliminar.php?id=<?= (int) $row['ProductoID'] ?>&reactivar=1">Reactivar</a>
                <?php endif; ?>
            </td>
            <?php endif; ?>
        </tr>
    <?php endforeach; ?>
    </tbody>
</table>

<?php require_once __DIR__ . '/footer.php'; ?>

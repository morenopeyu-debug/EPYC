<?php
require_once __DIR__ . '/bootstrap.php';

Auth::requerirCentral();

$pdo       = Database::actual();
$productos = new ProductoRepo($pdo);

$id = entero($_GET, 'id');
$producto = ['Nombre' => '', 'CategoriaID' => '', 'ProveedorID' => '', 'TipoMascota' => 'Perro', 'Marca' => '', 'Talla' => '', 'PrecioUnitario' => '', 'StockMinimo' => UMBRAL_STOCK_BAJO];

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    csrf_validar();

    $datos = [
        'nombre'       => texto($_POST, 'nombre'),
        'categoria'    => entero($_POST, 'categoria'),
        'proveedor'    => entero($_POST, 'proveedor'),
        'tipo_mascota' => texto($_POST, 'tipo_mascota'),
        'marca'        => texto($_POST, 'marca'),
        'talla'        => texto($_POST, 'talla'),
        'precio'       => (float) ($_POST['precio'] ?? 0),
        'stock_minimo' => entero($_POST, 'stock_minimo'),
    ];

    $idPost = entero($_POST, 'producto_id');

    try {
        if ($idPost > 0) {
            $productos->actualizar($idPost, $datos);
            flash('info', 'Producto actualizado.');
        } else {
            $productos->crear($datos);
            flash('info', 'Producto dado de alta en el catálogo.');
        }
    } catch (Throwable $e) {
        flash('error', $e instanceof PDOException ? Database::mensajeError($e) : $e->getMessage());
    }

    redirigir('productos.php');
}

if ($id > 0) {
    $encontrado = $productos->obtener($id);
    if ($encontrado) {
        $producto = $encontrado;
    }
}

$categorias  = $productos->categorias();
$proveedores = $productos->proveedores();

require_once __DIR__ . '/header.php';
?>

<h2><?= $id ? 'Editar producto' : 'Nuevo producto' ?></h2>

<form method="post" class="formulario">
    <?= csrf_campo() ?>
    <input type="hidden" name="producto_id" value="<?= $id ?>">

    <label>Código</label>
    <?php if ($id): ?>
        <input type="text" value="<?= e(codigo_producto($id)) ?>" disabled>
        <p class="ayuda">El código lo asigna el sistema y no se puede cambiar.</p>
    <?php else: ?>
        <input type="text" value="Se asignará al guardar" disabled>
        <p class="ayuda">El sistema le dará un código consecutivo en cuanto guardes el producto.</p>
    <?php endif; ?>

    <label>Nombre</label>
    <input type="text" name="nombre" value="<?= e($producto['Nombre']) ?>" required>

    <label>Categoría</label>
    <select name="categoria" required>
        <?php foreach ($categorias as $c): ?>
            <option value="<?= (int) $c['CategoriaID'] ?>" <?= ((int) $producto['CategoriaID'] === (int) $c['CategoriaID']) ? 'selected' : '' ?>><?= e($c['Nombre']) ?></option>
        <?php endforeach; ?>
    </select>

    <label>Proveedor</label>
    <select name="proveedor" required>
        <?php foreach ($proveedores as $p): ?>
            <option value="<?= (int) $p['ProveedorID'] ?>" <?= ((int) $producto['ProveedorID'] === (int) $p['ProveedorID']) ? 'selected' : '' ?>><?= e($p['Nombre']) ?></option>
        <?php endforeach; ?>
    </select>

    <label>Tipo de mascota</label>
    <select name="tipo_mascota" required>
        <option value="Perro" <?= ($producto['TipoMascota'] === 'Perro') ? 'selected' : '' ?>>Perro</option>
        <option value="Gato" <?= ($producto['TipoMascota'] === 'Gato') ? 'selected' : '' ?>>Gato</option>
        <option value="Ambos" <?= ($producto['TipoMascota'] === 'Ambos') ? 'selected' : '' ?>>Ambos</option>
    </select>

    <label>Marca</label>
    <input type="text" name="marca" value="<?= e($producto['Marca'] ?? '') ?>">

    <label>Talla (opcional)</label>
    <input type="text" name="talla" value="<?= e($producto['Talla'] ?? '') ?>">

    <label>Precio unitario</label>
    <input type="number" step="0.01" name="precio" value="<?= e((string) $producto['PrecioUnitario']) ?>" required>

    <label>Punto de reorden (stock mínimo)</label>
    <input type="number" name="stock_minimo" value="<?= e((string) $producto['StockMinimo']) ?>" required>

    <button type="submit">Guardar</button>
    <a href="productos.php" class="btn-cancelar">Cancelar</a>
</form>

<?php require_once __DIR__ . '/footer.php'; ?>

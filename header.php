<?php
require_once __DIR__ . '/bootstrap.php';

Auth::requerirLogin();

$esCentral   = Auth::esCentral();
$miSucursal  = Auth::sucursalId();
$pdoNav      = Database::actual();
$solicNav    = new SolicitudRepo($pdoNav);

// Distintivos del menú: cuántas requisiciones esperan acción de este usuario.
$pendientesNav = $esCentral
    ? $solicNav->contar('PENDIENTE')
    : $solicNav->contar('OFERTADO', $miSucursal);

// Página en curso, para marcar el enlace activo del menú. Es presentación:
// saber dónde estás parado sin tener que leer la URL.
$paginaActual = basename($_SERVER['SCRIPT_NAME'] ?? '');

/** Marca el enlace de la sección en la que estamos. */
function nav_activo(string $archivo): string
{
    global $paginaActual;
    return $paginaActual === $archivo ? ' class="activo" aria-current="page"' : '';
}
?>
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>EPYC — <?= e(Auth::nombreSucursal()) ?></title>
    <link rel="stylesheet" href="css/style.css">
</head>
<body>
<header class="topbar">
    <a class="marca" href="productos.php">
        <span class="marca-huella" aria-hidden="true">🐾</span>
        <span class="marca-texto">
            <span class="l-e">E</span><span class="l-p">P</span><span class="l-y">Y</span><span class="l-c">C</span>
        </span>
        <span class="marca-lema">Todo para tus mascotas</span>
    </a>

    <nav>
        <a href="productos.php"<?= nav_activo('productos.php') ?>>Productos</a>
        <a href="inventario.php"<?= nav_activo('inventario.php') ?>>Inventario</a>
        <?php if (!$esCentral): ?>
            <a href="ventas.php"<?= nav_activo('ventas.php') ?>>Ventas</a>
            <a href="alertas.php"<?= nav_activo('alertas.php') ?>>Alertas</a>
        <?php else: ?>
            <a href="entrada_mercancia.php"<?= nav_activo('entrada_mercancia.php') ?>>Entrada de mercancía</a>
            <a href="asignar_stock.php"<?= nav_activo('asignar_stock.php') ?>>Asignar stock</a>
        <?php endif; ?>
        <a href="solicitudes.php"<?= nav_activo('solicitudes.php') ?>>
            <?= $esCentral ? 'Solicitudes' : 'Mis solicitudes' ?>
            <?php if ($pendientesNav > 0): ?>
                <span class="nav-badge" title="<?= $pendientesNav === 1 ? '1 solicitud espera' : $pendientesNav . ' solicitudes esperan' ?> tu respuesta"><?= $pendientesNav ?></span>
            <?php endif; ?>
        </a>
    </nav>

    <div class="usuario-info">
        <span class="usuario-nombre"><?= e(Auth::nombre()) ?></span>
        <span class="usuario-sede"><?= e(Auth::nombreSucursal()) ?></span>
        <a href="logout.php" class="btn-salir">Cerrar sesión</a>
    </div>
</header>
<main class="contenido">
<?php foreach (tomar_flash() as $f): ?>
    <div class="alerta-<?= $f['tipo'] === 'error' ? 'error' : 'info' ?>"><?= e($f['mensaje']) ?></div>
<?php endforeach; ?>

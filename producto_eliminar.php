<?php
require_once __DIR__ . '/bootstrap.php';

Auth::requerirCentral();

$pdo       = Database::actual();
$productos = new ProductoRepo($pdo);

$id = entero($_GET, 'id');
$reactivar = isset($_GET['reactivar']);

if ($id > 0) {
    try {
        if (!$reactivar && $productos->tieneEnviosAbiertos($id)) {
            flash('error', 'No se puede dar de baja: hay un envío en tránsito de este producto. Espera a que se confirme o rechace.');
        } else {
            $productos->cambiarEstado($id, $reactivar);
            flash('info', $reactivar ? 'Producto reactivado.' : 'Producto dado de baja.');
        }
    } catch (Throwable $e) {
        flash('error', $e instanceof PDOException ? Database::mensajeError($e) : $e->getMessage());
    }
}

redirigir('productos.php');

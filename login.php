<?php
require_once __DIR__ . '/bootstrap.php';

$error = '';
$sucursalPost = $_POST['sucursal'] ?? '';
$usuarioPost = $_POST['usuario'] ?? '';

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $sucursalId = (int) $sucursalPost;
    $usuario = trim($usuarioPost);
    $password = $_POST['password'] ?? '';

    if ($sucursalId && $usuario !== '' && $password !== '') {
        try {
            if (Auth::intentarLogin($sucursalId, $usuario, $password)) {
                redirigir('productos.php');
            }
            $error = 'Usuario o contraseña incorrectos para esa sucursal.';
        } catch (Throwable $e) {
            // Database::fallaDeConexion ya redactó el mensaje según el
            // entorno y mandó el detalle al log; aquí solo se muestra.
            error_log('[EPYC] Login fallido por error de conexión: ' . $e->getMessage());
            $error = $e->getMessage();
        }
    } else {
        $error = 'Completa todos los campos.';
    }
}
?>
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Iniciar sesión — EPYC</title>
    <link rel="stylesheet" href="css/style.css">
</head>
<body class="login-page">
    <form class="login-box" method="post" autocomplete="off">
        <div class="login-marca">
            <span class="marca">
                <span class="marca-huella" aria-hidden="true">🐾</span>
                <span class="marca-texto">
                    <span class="l-e">E</span><span class="l-p">P</span><span class="l-y">Y</span><span class="l-c">C</span>
                </span>
            </span>
        </div>
        <p class="subtitle">Todo para tus mascotas · Inventario distribuido</p>

        <?php if ($error): ?>
            <div class="alerta-error"><?= e($error) ?></div>
        <?php endif; ?>

        <label>Sucursal</label>
        <select name="sucursal" required>
            <option value="">-- Selecciona tu sucursal --</option>
            <option value="1" <?= ($sucursalPost === '1') ? 'selected' : '' ?>>Central</option>
            <option value="2" <?= ($sucursalPost === '2') ? 'selected' : '' ?>>Monterrey</option>
            <option value="3" <?= ($sucursalPost === '3') ? 'selected' : '' ?>>Puebla</option>
            <option value="4" <?= ($sucursalPost === '4') ? 'selected' : '' ?>>Querétaro</option>
        </select>

        <label>Usuario</label>
        <input type="text" name="usuario" value="<?= e($usuarioPost) ?>" required>

        <label>Contraseña</label>
        <input type="password" name="password" required>

        <button type="submit">Entrar</button>
    </form>
</body>
</html>

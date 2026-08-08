<?php
/**
 * Sesión y control de acceso por rol.
 *
 * Hay dos roles operativos, determinados por la sucursal del empleado:
 *
 *   CENTRAL   (SucursalID = 1) — catálogo de productos, entrada de
 *             mercancía, asignación de stock y atención de requisiciones.
 *
 *   SUCURSAL  (2, 3, 4)        — consulta de catálogo, inventario propio,
 *             solicitudes de reabastecimiento y ventas.
 */
final class Auth
{
    public static function iniciarSesionPhp(): void
    {
        if (session_status() === PHP_SESSION_NONE) {
            session_start();
        }
    }

    /** Valida credenciales contra Empleados y abre la sesión. */
    public static function intentarLogin(int $sucursalId, string $usuario, string $password): bool
    {
        $pdo = Database::para($sucursalId);

        $sql = 'SELECT "EmpleadoID", "Nombre", "PasswordHash", "Rol", "SucursalID"
                  FROM dbo."Empleados"
                 WHERE "NombreUsuario" = ? AND "SucursalID" = ? AND "Activo" = 1';

        $stmt = $pdo->prepare($sql);
        $stmt->execute([$usuario, $sucursalId]);
        $fila = $stmt->fetch();

        if (!$fila || !password_verify($password, (string) $fila['PasswordHash'])) {
            return false;
        }

        // Evita fijación de sesión: identificador nuevo al autenticar.
        session_regenerate_id(true);

        $_SESSION['sucursal_id'] = (int) $fila['SucursalID'];
        $_SESSION['empleado_id'] = (int) $fila['EmpleadoID'];
        $_SESSION['nombre']      = $fila['Nombre'];
        $_SESSION['rol']         = $fila['Rol'];

        return true;
    }

    public static function cerrarSesion(): void
    {
        $_SESSION = [];
        if (ini_get('session.use_cookies')) {
            $p = session_get_cookie_params();
            setcookie(session_name(), '', time() - 42000, $p['path'], $p['domain'], $p['secure'], $p['httponly']);
        }
        session_destroy();
    }

    public static function autenticado(): bool
    {
        return isset($_SESSION['sucursal_id'], $_SESSION['empleado_id']);
    }

    public static function sucursalId(): int
    {
        return (int) ($_SESSION['sucursal_id'] ?? 0);
    }

    public static function empleadoId(): int
    {
        return (int) ($_SESSION['empleado_id'] ?? 0);
    }

    public static function nombre(): string
    {
        return (string) ($_SESSION['nombre'] ?? '');
    }

    public static function esCentral(): bool
    {
        return self::sucursalId() === SUCURSAL_CENTRAL;
    }

    public static function nombreSucursal(): string
    {
        global $nombres_sucursal;
        return $nombres_sucursal[self::sucursalId()] ?? 'Desconocida';
    }

    // ----------------------------------------------------------------
    // Guardas de acceso
    // ----------------------------------------------------------------

    public static function requerirLogin(): void
    {
        if (!self::autenticado()) {
            redirigir('login.php');
        }
    }

    /** Páginas exclusivas del almacén central. */
    public static function requerirCentral(): void
    {
        self::requerirLogin();

        if (!self::esCentral()) {
            http_response_code(403);
            exit('Acceso denegado: esta sección es exclusiva de la sucursal Central.');
        }
    }

    /** Páginas exclusivas de las sucursales (Central no vende ni pide). */
    public static function requerirSucursal(): void
    {
        self::requerirLogin();

        if (self::esCentral()) {
            http_response_code(403);
            exit('Acceso denegado: esta sección es exclusiva de las sucursales.');
        }
    }
}

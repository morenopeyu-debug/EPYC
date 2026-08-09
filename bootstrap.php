<?php
/**
 * Arranque de la aplicación.
 *
 * Toda página empieza con:  require_once __DIR__ . '/bootstrap.php';
 */

declare(strict_types=1);

mb_internal_encoding('UTF-8');

/**
 * En local conviene ver los errores en pantalla; en producción NO, porque
 * un error de PDO imprime la cadena de conexión —con host y usuario— en
 * la página. Render define APP_ENV=production; en tu equipo no existe y
 * se cae al modo de desarrollo.
 */
define('EN_PRODUCCION', (getenv('APP_ENV') ?: 'local') === 'production');

$enProduccion = EN_PRODUCCION;

ini_set('display_errors', $enProduccion ? '0' : '1');
ini_set('display_startup_errors', $enProduccion ? '0' : '1');
ini_set('log_errors', '1');
error_reporting(E_ALL);

require_once __DIR__ . '/config.php';

// Carga automática de las clases de lib/.
spl_autoload_register(static function (string $clase): void {
    $ruta = __DIR__ . '/lib/' . $clase . '.php';
    if (is_file($ruta)) {
        require_once $ruta;
    }
});

require_once __DIR__ . '/lib/helpers.php';

/**
 * Seguridad de la cookie de sesión. Tiene que quedar fijada ANTES de
 * session_start(), o no surte efecto.
 *
 * Render (como cualquier proxy que termina TLS) entrega la petición al
 * contenedor por HTTP plano; el dato de que el usuario llegó por HTTPS
 * viaja en la cabecera X-Forwarded-Proto. Sin consultarla, la cookie
 * nunca se marcaría 'secure' en producción — y marcarla siempre rompería
 * el acceso por http://localhost durante el desarrollo.
 */
$porHttps = (($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https')
    || (!empty($_SERVER['HTTPS']) && strtolower((string) $_SERVER['HTTPS']) !== 'off');

session_set_cookie_params([
    'lifetime' => 0,
    'path'     => '/',
    'httponly' => true,   // fuera del alcance de JavaScript
    'samesite' => 'Lax',  // no viaja en peticiones de otros sitios
    'secure'   => $porHttps,
]);

// Impide que un identificador de sesión inventado por un tercero sea
// aceptado como válido (fijación de sesión).
ini_set('session.use_strict_mode', '1');

Auth::iniciarSesionPhp();

/**
 * Comprobación temprana de los drivers: sin pdo_pgsql la aplicación no
 * puede hacer nada, y el error nativo de PDO ("could not find driver")
 * no dice qué falta habilitar.
 */
if (!in_array('pgsql', PDO::getAvailableDrivers(), true)) {
    exit(
        'Falta la extensión pdo_pgsql de PHP (necesaria para conectar con Neon). '
        . 'Habilítala en php.ini quitando el punto y coma de estas dos líneas y reinicia el servidor: '
        . 'extension=pdo_pgsql  y  extension=pgsql'
    );
}

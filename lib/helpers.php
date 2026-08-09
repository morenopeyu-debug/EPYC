<?php
/**
 * Utilidades compartidas por las vistas: escape, redirecciones,
 * mensajes flash y protección CSRF.
 */

/** Escape para HTML. Todo lo que venga de la base pasa por aquí. */
function e(?string $valor): string
{
    return htmlspecialchars((string) $valor, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

/** Redirección + corte de ejecución (patrón POST/Redirect/GET). */
function redirigir(string $destino): never
{
    header('Location: ' . $destino);
    exit;
}

/** Guarda un mensaje para mostrarlo después de una redirección. */
function flash(string $tipo, string $mensaje): void
{
    $_SESSION['flash'][] = ['tipo' => $tipo, 'mensaje' => $mensaje];
}

/** Extrae y limpia los mensajes flash pendientes. */
function tomar_flash(): array
{
    $mensajes = $_SESSION['flash'] ?? [];
    unset($_SESSION['flash']);
    return $mensajes;
}

/** Token CSRF de la sesión (se genera una vez). */
function csrf_token(): string
{
    if (empty($_SESSION['csrf_token'])) {
        $_SESSION['csrf_token'] = bin2hex(random_bytes(32));
    }
    return $_SESSION['csrf_token'];
}

/** Campo oculto listo para incrustar en cualquier formulario POST. */
function csrf_campo(): string
{
    return '<input type="hidden" name="csrf_token" value="' . e(csrf_token()) . '">';
}

/**
 * Valida el token del POST. Corta la petición si no coincide: las
 * acciones de este sistema mueven inventario, no deben poder
 * dispararse desde otro sitio.
 */
function csrf_validar(): void
{
    $enviado = $_POST['csrf_token'] ?? '';

    if (!is_string($enviado) || !hash_equals(csrf_token(), $enviado)) {
        http_response_code(400);
        exit('Petición inválida (token CSRF). Recarga la página e inténtalo de nuevo.');
    }
}

/** Entero saneado de $_POST/$_GET. */
function entero(array $fuente, string $clave, int $default = 0): int
{
    return isset($fuente[$clave]) ? (int) $fuente[$clave] : $default;
}

/** Texto recortado de $_POST/$_GET. */
function texto(array $fuente, string $clave, string $default = ''): string
{
    return isset($fuente[$clave]) ? trim((string) $fuente[$clave]) : $default;
}

/**
 * Código visible del producto, a partir de su identificador.
 *
 * El identificador lo asigna la base de datos sola (columna IDENTITY),
 * así que un producto recién dado de alta ya trae su código sin que
 * nadie lo capture. Aquí solo se le da formato para que se lea como un
 * código de catálogo y no como un número suelto: P-0007, no 7.
 */
function codigo_producto(int $productoId): string
{
    return 'P-' . str_pad((string) $productoId, 4, '0', STR_PAD_LEFT);
}

/**
 * Concuerda el sustantivo con la cantidad.
 *
 * Sin esto salían frases como «Quedan 1 unidades» o «Se generaron 1
 * solicitudes» en cuanto la cifra era uno, que es justo el caso más
 * frecuente al final de las existencias.
 *
 *   pluralizar(1, 'unidad', 'unidades')  ->  "1 unidad"
 *   pluralizar(5, 'unidad', 'unidades')  ->  "5 unidades"
 */
function pluralizar(int $cantidad, string $singular, string $plural): string
{
    return $cantidad . ' ' . ($cantidad === 1 ? $singular : $plural);
}

/** Etiqueta CSS por estado de solicitud. */
function clase_estado(string $estado): string
{
    return match ($estado) {
        'PENDIENTE' => 'chip chip-pendiente',
        'OFERTADO'  => 'chip chip-ofertado',
        'ACEPTADO'  => 'chip chip-aceptado',
        'RECHAZADO' => 'chip chip-rechazado',
        default     => 'chip',
    };
}

/** Formato de fecha para las tablas. */
function fecha_corta(?string $valor): string
{
    if (!$valor) {
        return '—';
    }
    $ts = strtotime($valor);
    return $ts ? date('d/m/Y H:i', $ts) : $valor;
}

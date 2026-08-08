<?php
// =====================================================================
// Configuración de la aplicación.
//
// ESTE ARCHIVO SÍ SE SUBE A GIT: no contiene ninguna credencial.
//
// Las credenciales de Neon entran por dos caminos, según dónde corra:
//
//   En la nube (Render)  -> variables de entorno del servicio.
//   En tu computadora    -> config.local.php, que está en .gitignore.
//
// Para trabajar en local:
//     cp config.local.example.php config.local.php
//     # y rellena los tres valores dentro
// =====================================================================

// Si existe el archivo local, sus define() ganan: al estar ya definidas
// las constantes, los defined() de abajo no las sobrescriben.
if (is_file(__DIR__ . '/config.local.php')) {
    require_once __DIR__ . '/config.local.php';
}

defined('NEON_HOST')     || define('NEON_HOST',     getenv('NEON_HOST')     ?: '');
defined('NEON_PUERTO')   || define('NEON_PUERTO',   (int) (getenv('NEON_PUERTO') ?: 5432));
defined('NEON_USUARIO')  || define('NEON_USUARIO',  getenv('NEON_USUARIO')  ?: 'neondb_owner');
defined('NEON_PASSWORD') || define('NEON_PASSWORD', getenv('NEON_PASSWORD') ?: '');

// Sin host no hay nada que hacer, y el error nativo de PDO no explica
// que lo que falta es configuración, no red.
if (NEON_HOST === '' || NEON_PASSWORD === '') {
    exit(
        'Falta la configuración de la base de datos. '
        . 'En local: copia config.local.example.php a config.local.php y rellénalo. '
        . 'En Render: define las variables de entorno NEON_HOST, NEON_USUARIO y NEON_PASSWORD.'
    );
}

$conexiones = [
    1 => [ // Central
        'host'      => NEON_HOST,
        'puerto'    => NEON_PUERTO,
        'basedatos' => 'bd_central',
        'usuario'   => NEON_USUARIO,
        'password'  => NEON_PASSWORD,
    ],
    2 => [ // Monterrey
        'host'      => NEON_HOST,
        'puerto'    => NEON_PUERTO,
        'basedatos' => 'bd_monterrey',
        'usuario'   => NEON_USUARIO,
        'password'  => NEON_PASSWORD,
    ],
    3 => [ // Puebla
        'host'      => NEON_HOST,
        'puerto'    => NEON_PUERTO,
        'basedatos' => 'bd_puebla',
        'usuario'   => NEON_USUARIO,
        'password'  => NEON_PASSWORD,
    ],
    4 => [ // Queretaro
        'host'      => NEON_HOST,
        'puerto'    => NEON_PUERTO,
        'basedatos' => 'bd_queretaro',
        'usuario'   => NEON_USUARIO,
        'password'  => NEON_PASSWORD,
    ],
];

$nombres_sucursal = [
    1 => 'Central',
    2 => 'Monterrey',
    3 => 'Puebla',
    4 => 'Querétaro',
];

// =====================================================================
// Constantes que usan lib/Database.php, lib/Auth.php y los repos.
// =====================================================================

// SucursalID de la sede Central (usada en varias comparaciones y en el
// panorama global). Debe coincidir con Sucursales.EsCentral = 1 en la BD.
define('SUCURSAL_CENTRAL', 1);

// ---------------------------------------------------------------------
// MODO_DEMO — LÉELO ANTES DE CAMBIARLO
// ---------------------------------------------------------------------
// true  = las 4 sucursales resuelven a la conexión de Central
//         (bd_central). La separación de datos la sigue haciendo
//         SucursalID, que es como está diseñado todo el modelo.
//
// false = cada sucursal se conecta a SU PROPIA base de Neon.
//
// EN NEON DEBE QUEDARSE EN true, y la razón es de fondo:
//
//   PostgreSQL no tiene replicación de mezcla. En SQL Server, el Merge
//   Agent era lo que hacía que una solicitud creada en BD_Monterrey
//   apareciera en BD_Central para que la atendieran. Sin ese agente,
//   con MODO_DEMO = false cada base quedaría aislada: Monterrey pediría
//   reabasto y Central jamás vería la petición.
//
//   Con MODO_DEMO = true las cuatro sedes trabajan sobre la misma base
//   y el flujo completo (solicitud -> oferta -> aceptación) funciona
//   igual que antes, sin retraso de sincronización.
define('MODO_DEMO', true);

// Punto de reorden: <= a esta cantidad dispara la alerta de stock bajo.
define('UMBRAL_STOCK_BAJO', 5);

// Opciones de conexión que usa lib/Database.php al construir el DSN.
// Neon SIEMPRE exige TLS: 'sslmode' no debe bajarse de 'require'.
$opciones_conexion = [
    'timeout_conexion' => 10,
    'sslmode'          => 'require',
];

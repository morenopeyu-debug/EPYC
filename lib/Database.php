<?php
/**
 * Conexión a PostgreSQL (Neon) vía PDO, driver pdo_pgsql.
 *
 * Una conexión por sucursal, reutilizada durante toda la petición.
 * Todas las consultas de la aplicación pasan por aquí; ninguna vista
 * abre conexiones por su cuenta.
 */
final class Database
{
    /** @var array<int, PDO> */
    private static array $conexiones = [];

    private function __construct() {}

    /**
     * Devuelve la conexión PDO de la sucursal indicada.
     *
     * En MODO_DEMO todas las sucursales resuelven a la conexión de
     * Central: la separación de datos la sigue haciendo SucursalID.
     * Ver la explicación en config.php — en Neon es el modo correcto,
     * porque no hay replicación de mezcla que junte las 4 bases.
     */
    public static function para(int $sucursalId): PDO
    {
        $destino = MODO_DEMO ? SUCURSAL_CENTRAL : $sucursalId;

        if (isset(self::$conexiones[$destino])) {
            return self::$conexiones[$destino];
        }

        global $conexiones, $opciones_conexion;

        if (!isset($conexiones[$destino])) {
            throw new RuntimeException("No hay conexión configurada para la sucursal $destino.");
        }

        $c = $conexiones[$destino];

        $dsn = sprintf(
            'pgsql:host=%s;port=%d;dbname=%s;sslmode=%s;connect_timeout=%d',
            $c['host'],
            $c['puerto'] ?? 5432,
            $c['basedatos'],
            $opciones_conexion['sslmode'] ?? 'require',
            $opciones_conexion['timeout_conexion'] ?? 10
        );

        $opcionesPdo = [
            PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            // Consultas preparadas del lado del servidor: Postgres recibe
            // los parámetros tipados y no hay interpolación de cadenas en
            // ningún punto.
            PDO::ATTR_EMULATE_PREPARES   => false,
        ];

        try {
            // ---------------------------------------------------------
            // Camino normal. Neon aloja muchos endpoints tras una misma
            // IP y decide a cuál conectarte por SNI: el nombre de servidor
            // que viaja en el saludo TLS. Cualquier libpq moderna lo manda
            // sola y esto funciona sin más.
            // ---------------------------------------------------------
            $pdo = new PDO($dsn, $c['usuario'], $c['password'], $opcionesPdo);

        } catch (PDOException $e) {
            // ---------------------------------------------------------
            // Camino de respaldo, solo para libpq anteriores al soporte
            // de SNI —como la que trae XAMPP—. Sin SNI, Neon no sabe a
            // qué endpoint mandarte y responde:
            //
            //     ERROR: Endpoint ID is not specified.
            //
            // El rodeo que documenta Neon es pasar el endpoint explícito
            // en el parámetro 'options'.
            //
            // OJO: esto NO puede aplicarse siempre. Si la libpq sí manda
            // SNI y además va la opción, Neon compara ambos y rechaza la
            // conexión con "Inconsistent project name inferred from SNI".
            // Por eso el rodeo va aquí, como reacción al error concreto, y
            // no en el DSN de entrada.
            // ---------------------------------------------------------
            if (!str_contains($e->getMessage(), 'Endpoint ID is not specified')) {
                self::fallaDeConexion($c, $e);
            }

            // El identificador es la primera etiqueta del host, sin el
            // sufijo '-pooler':
            //   ep-quiet-heart-axxjk1qg-pooler.c-4.us-east-2.aws.neon.tech
            //   └──────── endpoint ────┘└pooler┘
            $endpoint = preg_replace('/-pooler$/', '', explode('.', $c['host'])[0]);

            try {
                $pdo = new PDO(
                    $dsn . ';options=endpoint=' . $endpoint,
                    $c['usuario'],
                    $c['password'],
                    $opcionesPdo
                );
            } catch (PDOException $e2) {
                self::fallaDeConexion($c, $e2);
            }
        }

        // Todo el modelo vive en el esquema dbo (se conservó el nombre de
        // SQL Server). Aun así, las consultas lo escriben completo: esto
        // es una red de seguridad, no la ruta principal.
        $pdo->exec('SET search_path TO dbo, public');

        self::$conexiones[$destino] = $pdo;

        return $pdo;
    }

    /**
     * Corta la ejecución con un fallo de conexión, sin filtrar detalles.
     *
     * El detalle completo —host, base, error de red— va SIEMPRE al log,
     * pero al visitante solo se le muestra en desarrollo. En producción
     * ese texto aparecía en la pantalla de login, y con él el nombre del
     * servidor de Neon y la base a la que intenta conectarse: información
     * de reconocimiento regalada a cualquiera que abra la página.
     *
     * @return never
     */
    private static function fallaDeConexion(array $c, PDOException $e): void
    {
        error_log("[EPYC] Fallo de conexión a {$c['host']} ({$c['basedatos']}): " . $e->getMessage());

        throw new RuntimeException(
            EN_PRODUCCION
                ? 'No se pudo conectar con la base de datos. Inténtalo de nuevo en un momento.'
                : "No se pudo conectar a {$c['host']} ({$c['basedatos']}): " . $e->getMessage(),
            0,
            $e
        );
    }

    /** Conexión de la sucursal del usuario en sesión. */
    public static function actual(): PDO
    {
        return self::para((int) ($_SESSION['sucursal_id'] ?? SUCURSAL_CENTRAL));
    }

    /**
     * Traduce un PDOException de PostgreSQL a un mensaje presentable.
     *
     * Los RAISE EXCEPTION de las funciones almacenadas traen un texto ya
     * redactado para el usuario. PDO lo entrega envuelto así:
     *
     *   SQLSTATE[P0001]: Raise exception: 7 ERROR:  Stock insuficiente...
     *   CONTEXT:  PL/pgSQL function dbo.usp_registrar_venta(...) line 30
     *
     * Se extrae solo la primera línea después de "ERROR:", que es la
     * redactada; el CONTEXT es ruido para quien está en el mostrador.
     */
    public static function mensajeError(PDOException $e): string
    {
        $texto = $e->getMessage();

        if (preg_match('/ERROR:\s*(.+?)(?:\r?\n|$)/', $texto, $m)) {
            $limpio = trim($m[1]);
            if ($limpio !== '') {
                return $limpio;
            }
        }

        return $texto;
    }
}

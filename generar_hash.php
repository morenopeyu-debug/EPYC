<?php
// Uso desde la terminal:  php generar_hash.php "MiContraseña123"
// Copia el resultado y pégalo en sql/01_Ajustes_Usuarios.sql
if ($argc < 2) {
    echo "Uso: php generar_hash.php TuContraseña\n";
    exit(1);
}
echo password_hash($argv[1], PASSWORD_DEFAULT) . "\n";

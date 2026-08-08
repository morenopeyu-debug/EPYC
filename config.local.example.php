<?php
// =====================================================================
// PLANTILLA — cópiala como config.local.php y rellena los valores.
//
//     cp config.local.example.php config.local.php
//
// config.local.php está en .gitignore: es el único lugar del proyecto
// donde vive la contraseña, y nunca debe subir a GitHub.
//
// En Render NO se usa este archivo: allá los mismos tres valores se
// definen como variables de entorno del servicio.
//
// Los datos salen de la consola de Neon, en "Connection Details". La
// cadena que muestran tiene esta forma:
//
//   postgresql://USUARIO:CONTRASEÑA@HOST/base?sslmode=require
//                └─────┘ └────────┘ └──┘
// =====================================================================

define('NEON_HOST',     'ep-tu-endpoint-pooler.c-4.us-east-2.aws.neon.tech');
define('NEON_USUARIO',  'neondb_owner');
define('NEON_PASSWORD', 'tu_password_de_neon');

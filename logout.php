<?php
require_once __DIR__ . '/bootstrap.php';
Auth::cerrarSesion();
redirigir('login.php');

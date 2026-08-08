<?php
require_once __DIR__ . '/bootstrap.php';
redirigir(Auth::autenticado() ? 'productos.php' : 'login.php');

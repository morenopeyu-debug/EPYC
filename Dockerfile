# =====================================================================
# EPYC — Inventario Distribuido
# Imagen para desplegar en Render.
#
# POR QUÉ DOCKER
# Render no tiene entorno nativo de PHP (sólo Node, Python, Ruby, Go,
# Rust y Elixir). Docker es la vía soportada para correr PHP ahí, y de
# paso deja el despliegue reproducible: la misma imagen corre igual en
# tu máquina que en la nube.
# =====================================================================

FROM php:8.2-apache

# ---------------------------------------------------------------------
# Extensión pdo_pgsql — es lo único que la aplicación necesita compilar.
# libpq-dev trae las cabeceras para construirla y libpq5 para ejecutarla;
# se conserva instalada a propósito (purgarla con --auto-remove se lleva
# libpq5 y el contenedor arranca sin poder conectar a Postgres).
# ---------------------------------------------------------------------
RUN apt-get update \
 && apt-get install -y --no-install-recommends libpq-dev \
 && docker-php-ext-install -j"$(nproc)" pdo_pgsql \
 && rm -rf /var/lib/apt/lists/*

# Base de configuración recomendada por PHP para producción.
RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"

# Ajustes propios encima (el prefijo zz- garantiza que se lean al final).
COPY docker/php-epyc.ini "$PHP_INI_DIR/conf.d/zz-epyc.ini"

# Reglas de Apache: qué se sirve y qué no.
COPY docker/apache-epyc.conf /etc/apache2/conf-available/epyc.conf
RUN a2enconf epyc && a2enmod headers

# ---------------------------------------------------------------------
# La aplicación.
# .dockerignore deja fuera .git, los scripts SQL y las credenciales
# locales; el rm es un segundo cerrojo por si alguien despliega sin él.
# ---------------------------------------------------------------------
COPY --chown=www-data:www-data . /var/www/html/
RUN rm -f /var/www/html/config.local.php

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Render inyecta PORT en tiempo de ejecución; 10000 es su valor por
# omisión y sirve para correr la imagen en local sin variables.
ENV PORT=10000
EXPOSE 10000

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["apache2-foreground"]

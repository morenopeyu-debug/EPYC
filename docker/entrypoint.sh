#!/bin/sh
# =====================================================================
# Apache tiene el puerto escrito en su configuración, pero Render decide
# el puerto en tiempo de ejecución y lo pasa en la variable PORT. Si el
# contenedor no escucha exactamente ahí, Render lo da por caído y
# reinicia el servicio en bucle.
#
# Por eso el puerto se reescribe al arrancar, no al construir la imagen.
# =====================================================================
set -e

PORT="${PORT:-10000}"

sed -i "s/^Listen .*/Listen ${PORT}/" /etc/apache2/ports.conf
sed -i "s|<VirtualHost \*:[0-9]*>|<VirtualHost *:${PORT}>|" /etc/apache2/sites-available/000-default.conf

echo "[epyc] Apache escuchando en el puerto ${PORT}"

exec "$@"

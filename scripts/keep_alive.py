#!/usr/bin/env python3
"""
keep_alive.py — mantiene despierto el servicio de EPYC en Render.

EL PROBLEMA
-----------
El plan gratuito de Render duerme el contenedor tras 15 minutos sin
visitas. La siguiente petición lo despierta, pero tarda entre 50 segundos
y un minuto en responder: justo el tiempo que nadie quiere esperar en
medio de una presentación.

LA SOLUCIÓN
-----------
Visitar la página cada pocos minutos para que el reloj de inactividad
nunca llegue a 15.

    python keep_alive.py https://epyc-inventario.duckdns.org

ANTES DE DEJARLO CORRIENDO, DOS ADVERTENCIAS
--------------------------------------------
1. Esto sólo funciona mientras esta computadora esté encendida y con
   internet. Si el objetivo es que el servicio viva en la nube sin
   depender de tu equipo, usa la versión de GitHub Actions que está en
   .github/workflows/keep-alive.yml — hace exactamente lo mismo desde
   los servidores de GitHub.

2. El plan gratuito de Render incluye 750 horas de instancia al mes, y
   un mes tiene ~730 horas. Mantener el servicio despierto las 24 horas
   consume prácticamente toda la cuota: alcanza para UN servicio, y si
   tienes otro en la misma cuenta te quedarás sin horas antes de fin de
   mes. Por eso este script trae un horario (--desde / --hasta) y por
   omisión sólo despierta de 6:00 a 23:59, hora de México.

Sólo usa la biblioteca estándar: no hace falta instalar nada.
"""

from __future__ import annotations

import argparse
import signal
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

# México central (UTC-6). Se fija así, sin base de datos de zonas
# horarias, para que el script corra igual en Windows sin tzdata.
ZONA_MEXICO = timezone(timedelta(hours=-6))

AGENTE = "EPYC-KeepAlive/1.0 (+mantiene despierto el servicio de Render)"

_detener = False


def _al_interrumpir(_signum, _frame) -> None:
    """Ctrl+C: termina la espera en curso y sale ordenadamente."""
    global _detener
    _detener = True
    print("\n[!] Interrumpido. Cerrando…", flush=True)


def marca_de_tiempo() -> str:
    return datetime.now(ZONA_MEXICO).strftime("%d/%m/%Y %H:%M:%S")


def dentro_del_horario(desde: int, hasta: int) -> bool:
    """
    ¿La hora actual de México cae dentro de la ventana de actividad?

    Admite ventanas que cruzan la medianoche (por ejemplo 22 a 6).
    """
    if desde == hasta:
        return True  # ventana de 24 horas

    hora = datetime.now(ZONA_MEXICO).hour

    if desde < hasta:
        return desde <= hora <= hasta
    return hora >= desde or hora <= hasta


def visitar(url: str, timeout: int) -> tuple[bool, str]:
    """
    Hace una petición GET y devuelve (exito, descripción).

    Un 3xx o un 4xx también cuentan como éxito: significa que el
    contenedor está despierto y respondiendo, que es lo único que
    interesa aquí. Sólo un fallo de red o un 5xx indican problema.
    """
    peticion = urllib.request.Request(url, headers={"User-Agent": AGENTE})
    inicio = time.monotonic()

    try:
        with urllib.request.urlopen(peticion, timeout=timeout) as respuesta:
            tardanza = time.monotonic() - inicio
            return True, f"HTTP {respuesta.status} en {tardanza:.1f}s"

    except urllib.error.HTTPError as e:
        tardanza = time.monotonic() - inicio
        # El servidor contestó, aunque sea con un error de aplicación.
        if e.code < 500:
            return True, f"HTTP {e.code} en {tardanza:.1f}s (despierto)"
        return False, f"HTTP {e.code} en {tardanza:.1f}s (error del servidor)"

    except urllib.error.URLError as e:
        return False, f"sin respuesta: {e.reason}"

    except TimeoutError:
        return False, f"se agotó el tiempo de espera ({timeout}s)"

    except Exception as e:  # noqa: BLE001 — el vigilante no debe morir nunca
        return False, f"error inesperado: {e.__class__.__name__}: {e}"


def esperar(segundos: float) -> None:
    """Duerme en tramos cortos para que Ctrl+C responda de inmediato."""
    fin = time.monotonic() + segundos
    while not _detener and time.monotonic() < fin:
        time.sleep(min(1.0, fin - time.monotonic()))


def main() -> int:
    analizador = argparse.ArgumentParser(
        description="Mantiene despierto el servicio de EPYC en Render.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Ejemplos:\n"
            "  python keep_alive.py https://epyc-inventario.duckdns.org\n"
            "  python keep_alive.py https://mi-app.onrender.com --intervalo 600\n"
            "  python keep_alive.py https://mi-app.onrender.com --desde 0 --hasta 0   (24 horas)\n"
        ),
    )
    analizador.add_argument(
        "url",
        help="Dirección del servicio, por ejemplo https://epyc-inventario.duckdns.org",
    )
    analizador.add_argument(
        "--intervalo", type=int, default=300,
        help="Segundos entre visitas (por omisión 300 = 5 minutos). "
             "Render duerme a los 15 minutos, así que cualquier valor "
             "por debajo de 840 sirve.",
    )
    analizador.add_argument(
        "--timeout", type=int, default=90,
        help="Segundos de espera por respuesta (por omisión 90). Tiene que "
             "ser holgado: despertar un contenedor dormido tarda cerca de un minuto.",
    )
    analizador.add_argument(
        "--desde", type=int, default=6, metavar="HORA",
        help="Hora de México a la que empieza a vigilar (por omisión 6).",
    )
    analizador.add_argument(
        "--hasta", type=int, default=23, metavar="HORA",
        help="Hora de México a la que deja de vigilar (por omisión 23). "
             "Usa --desde 0 --hasta 0 para las 24 horas.",
    )
    args = analizador.parse_args()

    if not args.url.startswith(("http://", "https://")):
        args.url = "https://" + args.url

    if args.intervalo < 30:
        print("[!] Un intervalo menor a 30 segundos es abuso, no vigilancia.", file=sys.stderr)
        return 2

    signal.signal(signal.SIGINT, _al_interrumpir)
    try:
        signal.signal(signal.SIGTERM, _al_interrumpir)
    except (AttributeError, ValueError):
        pass  # Windows no siempre lo permite

    ventana = ("las 24 horas" if args.desde == args.hasta
               else f"de {args.desde:02d}:00 a {args.hasta:02d}:59, hora de México")

    print("=" * 62)
    print(" EPYC — vigilante de actividad")
    print("=" * 62)
    cadencia = (f"cada {args.intervalo}s"
                if args.intervalo < 60
                else f"cada {args.intervalo}s ({args.intervalo / 60:.0f} min)")

    print(f" Destino  : {args.url}")
    print(f" Intervalo: {cadencia}")
    print(f" Horario  : {ventana}")
    print(" Detener  : Ctrl+C")
    print("=" * 62, flush=True)

    exitos = fallos = 0

    while not _detener:
        if dentro_del_horario(args.desde, args.hasta):
            ok, detalle = visitar(args.url, args.timeout)

            if ok:
                exitos += 1
                print(f"[{marca_de_tiempo()}]  OK    {detalle}", flush=True)
            else:
                fallos += 1
                print(f"[{marca_de_tiempo()}]  FALLA {detalle}", flush=True)

            espera = args.intervalo
        else:
            # Fuera de horario se revisa cada 10 minutos, sólo para saber
            # cuándo vuelve a empezar la ventana.
            print(f"[{marca_de_tiempo()}]  fuera de horario, en pausa", flush=True)
            espera = 600

        esperar(espera)

    print(f"\nResumen: {exitos} visitas correctas, {fallos} fallidas.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

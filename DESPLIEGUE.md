# Publicar EPYC en internet — Render + DuckDNS

Guía completa para que la página quede accesible desde
`https://tu-nombre.duckdns.org`.

---

## Cómo encajan las piezas

Conviene tener claro el reparto antes de empezar, porque son tres
servicios distintos y cada uno hace una sola cosa:

```
   Navegador
       |
       |  https://epyc-inventario.duckdns.org
       v
   DuckDNS ................. sólo traduce el nombre a una IP
       |                     (no aloja nada, no guarda nada)
       v  216.24.57.1
   Render .................. aquí SÍ corre la página
       |                     (contenedor Docker con PHP + Apache)
       v
   Neon .................... aquí viven las 4 bases de datos
```

**DuckDNS no es alojamiento.** Es un servicio de DNS dinámico: le das un
nombre y una IP, y responde esa IP a quien pregunte. El alojamiento es
Render. Son dos cosas separadas y se configuran por separado.

---

## Antes de empezar

- Cuenta de GitHub con el proyecto subido.
- Cuenta en [render.com](https://render.com) (el registro es con GitHub).
- Cuenta en [duckdns.org](https://www.duckdns.org) (entra con Google o GitHub).
- Las 4 bases ya cargadas en Neon — ver [sql/neon/00_LEEME.md](sql/neon/00_LEEME.md).

---

## Paso 1 — Subir el proyecto a GitHub

Antes del primer commit, **verifica que `.gitignore` esté incluido**:

```bash
cd proyecto_web
git init
git add .
git status          # <-- config.local.php NO debe aparecer en la lista
```

Si `config.local.php` aparece, detente: lleva tu contraseña de Neon.
Revisa que `.gitignore` exista y vuelve a intentar.

```bash
git commit -m "EPYC — inventario distribuido sobre Neon"
git branch -M main
git remote add origin https://github.com/TU_USUARIO/TU_REPO.git
git push -u origin main
```

> **Si subes la carpeta padre** (`ProyectoWeb_InventarioMascotas`) en vez
> de `proyecto_web`, el `Dockerfile` no queda en la raíz del repositorio.
> En ese caso, en el paso 2 hay que indicarle a Render
> **Root Directory = `proyecto_web`**.

---

## Paso 2 — Crear el servicio en Render

1. En el panel de Render: **New → Web Service**.
2. Conecta el repositorio de GitHub.
3. Configura así:

   | Campo | Valor |
   |---|---|
   | Language / Runtime | **Docker** |
   | Branch | `main` |
   | Root Directory | *(vacío, o `proyecto_web` — ver nota del paso 1)* |
   | Instance Type | **Free** |
   | Region | Oregon |

   Render detecta el `Dockerfile` solo. No hay que escribir comandos de
   build ni de arranque: el `Dockerfile` y `docker/entrypoint.sh` ya se
   encargan, incluido el detalle de escuchar en el puerto que Render
   asigna.

4. En **Environment Variables**, agrega estas cuatro:

   | Clave | Valor |
   |---|---|
   | `APP_ENV` | `production` |
   | `NEON_HOST` | `ep-quiet-heart-axxjk1qg-pooler.c-4.us-east-2.aws.neon.tech` |
   | `NEON_USUARIO` | `neondb_owner` |
   | `NEON_PASSWORD` | *(tu contraseña de Neon)* |

   `APP_ENV=production` es la que apaga los mensajes de error en pantalla
   y marca la cookie de sesión como `secure`. Sin ella, un error de base
   de datos imprimiría el host y el usuario al visitante.

5. **Create Web Service**. El primer build tarda unos 3–5 minutos
   (compila la extensión `pdo_pgsql`).

Cuando termine, entra a `https://TU-SERVICIO.onrender.com/login.php` y
comprueba que puedas iniciar sesión. **Que esto funcione antes de tocar
DuckDNS**: si algo falla, es de Render o de Neon, no del dominio.

---

## Paso 3 — Crear el subdominio en DuckDNS

1. Entra a [duckdns.org](https://www.duckdns.org) e inicia sesión.
2. En **add domain**, escribe el nombre que quieras, por ejemplo
   `epyc-inventario`, y dale **add domain**.
   Tu dirección será `epyc-inventario.duckdns.org`.
3. En el campo **current ip** de ese dominio, borra lo que traiga
   (DuckDNS pone la IP de tu casa por omisión) y escribe:

   ```
   216.24.57.1
   ```

4. Presiona **update ip**.
5. Deja el campo de **IPv6 vacío**. Render funciona sobre IPv4 y un
   registro AAAA suelto provoca fallos intermitentes difíciles de
   diagnosticar.

### Por qué esa IP y no un CNAME

Render pide un **CNAME** para subdominios, pero DuckDNS **sólo permite
registros A** (una IP). Para ese caso Render publica la IP fija de su
balanceador, `216.24.57.1`, y enruta la petición al servicio correcto
leyendo el nombre del sitio en la cabecera `Host`. Por eso el paso 4 es
imprescindible: sin registrar el dominio en Render, esa IP no sabe a
quién entregarle tu visita.

> **Nota:** `216.24.57.1` la publica Render en su documentación y es
> estable, pero es un dato de ellos, no tuyo. Si algún día el sitio deja
> de responder de golpe, lo primero que hay que revisar es si esa IP
> cambió.

---

## Paso 4 — Registrar el dominio en Render

1. En tu servicio: **Settings → Custom Domains → Add Custom Domain**.
2. Escribe `epyc-inventario.duckdns.org` y guarda.
3. Presiona **Verify**. Render consulta el DNS; si ya apunta a su IP,
   lo marca como verificado.
4. Render emite el certificado TLS solo (Let's Encrypt). Tarda entre uno
   y quince minutos. Mientras tanto puede verse un aviso de certificado
   en el navegador — es normal, espera a que el panel diga *Certificate
   issued*.

Si al verificar dice que el DNS todavía no propaga, espera un par de
minutos y reintenta. Puedes comprobar a mano a dónde apunta:

```bash
nslookup epyc-inventario.duckdns.org
# debe responder 216.24.57.1
```

---

## Listo

`https://epyc-inventario.duckdns.org` sirve la página, con HTTPS y
contra las bases de Neon.

---

## Paso 5 — Evitar que el servicio se duerma

Tras 15 minutos sin visitas, Render apaga el contenedor y la siguiente
petición tarda casi un minuto en responder. Hay dos formas de evitarlo;
hacen exactamente lo mismo, la diferencia es **dónde corren**.

### Opción A — Servicio de monitoreo externo (es la que se usa)

Un servicio dedicado que visita la página cada pocos minutos. Gratuitos
y en la nube, así que no dependen de tu equipo:

- **[cron-job.org](https://cron-job.org)** — gratis, sin tarjeta, hasta
  cada minuto.
- **[UptimeRobot](https://uptimerobot.com)** — gratis cada 5 minutos, y
  además avisa por correo si el sitio se cae.

Configuración: dirección `https://epyc-inventario.duckdns.org/login.php`,
intervalo de 10 minutos. Son tres campos.

### Opción B — GitHub Actions (respaldo, NO confiar en él)

`.github/workflows/keep-alive.yml` hace lo mismo desde GitHub. Está en
el repositorio y funciona, pero **no sirve como método principal**, y
esto está medido, no supuesto:

> El cron está programado cada 5 minutos. En una ventana de dos horas
> debieron dispararse ~26 ejecuciones. Se dispararon **3**, a intervalos
> de aproximadamente una hora. Después estuvo más de dos horas sin
> ejecutarse ni una vez.

GitHub descarta ejecuciones programadas cuando su cola está saturada, y
en repositorios gratuitos lo hace de forma agresiva. Con huecos de una
hora y un *spin down* a los 15 minutos, no evita que el servicio se
duerma. Por eso las tres visitas espaciadas que hace cada ejecución no
alcanzan a compensar.

Sirve como red de seguridad y para **despertar el servicio a mano** antes
de una presentación: pestaña **Actions → Mantener despierto el servicio
→ Run workflow**.

Si quieres apuntarlo a otra dirección, crea la variable `URL_SERVICIO`
en *Settings → Secrets and variables → Actions → pestaña **Variables***.
Si no existe, usa la dirección de `onrender.com`, así que funciona sin
configurar nada.

> Ojo: GitHub **desactiva** los cron de repositorios sin actividad por 60
> días. Se reactivan desde la pestaña Actions.

### Opción C — Desde tu computadora

```bash
python scripts/keep_alive.py https://epyc-inventario.duckdns.org
```

No necesita instalar nada (sólo biblioteca estándar). Funciona bien para
una sesión de trabajo, pero **deja de servir en cuanto apagas el
equipo**. Opciones útiles:

```bash
--intervalo 600      # cada 10 minutos en vez de 5
--desde 0 --hasta 0  # las 24 horas (por omisión, de 6:00 a 23:59)
```

### La cuota: por qué el horario no es de 24 horas

El plan gratuito de Render da **750 horas de instancia al mes**, y un mes
tiene ~730. Mantener el servicio despierto todo el día consume
prácticamente la cuota completa: alcanza para **un** servicio, y si
tienes otro en la misma cuenta te quedarás sin horas antes de fin de mes.

Por eso el workflow y el script de Python vigilan de 06:00 a 23:59 hora
de México (~18 h al día ≈ 540 h al mes). El sitio está despierto cuando
alguien lo va a usar, y sobra margen. Si de verdad lo necesitas las 24
horas, en el YAML cambia el cron a `'*/5 * * * *'`.

**Si usas un servicio externo, aplícale el mismo criterio**: cron-job.org
y UptimeRobot permiten limitar el horario. Un monitor cada 5 minutos las
24 horas mantiene el contenedor encendido todo el mes y agota la cuota.

---

## Lo que tienes que saber del plan gratuito

**Las sesiones se pierden al reiniciar.** Las sesiones de PHP se guardan
en archivos dentro del contenedor, y el contenedor es efímero: cada
despliegue o reinicio cierra la sesión de todos. Para este proyecto es
irrelevante; volver a entrar toma dos segundos.

**Neon también suspende.** Su plan gratuito duerme la base tras un rato
sin consultas, pero despierta en un par de segundos — no se nota.

---

## Si algo sale mal

| Síntoma | Causa probable |
|---|---|
| Render reinicia el servicio en bucle | El contenedor no escucha en `$PORT`. Revisa en los logs la línea `[epyc] Apache escuchando en el puerto ...` |
| «Falta la configuración de la base de datos» | Faltan las variables `NEON_HOST` / `NEON_PASSWORD` en Render, o tienen una errata |
| «Endpoint ID is not specified» | El host de Neon no trae el endpoint. Debe ser el nombre completo `ep-....neon.tech`; `lib/Database.php` deriva de ahí el identificador |
| Página en blanco, sin mensaje | Es lo correcto en producción: los errores van al log. Míralos en Render → **Logs** |
| Render no verifica el dominio | Confirma con `nslookup` que responde `216.24.57.1`. Si insiste en fallar, usa la dirección `onrender.com`, que siempre funciona |
| El dominio apunta a tu casa | DuckDNS repuso tu IP doméstica. **No instales su script actualizador**: sobrescribe la IP de Render cada 5 minutos |

### Ver los registros

Render → tu servicio → pestaña **Logs**. Ahí salen los errores de PHP
(van a `stderr` a propósito) y los accesos de Apache.

---

## Probar la imagen en tu máquina antes de subirla

Si tienes Docker funcionando, vale la pena comprobar el contenedor en
local — te ahorra esperar cinco minutos por cada build fallido en Render:

```bash
cd proyecto_web

docker build -t epyc .

docker run --rm -p 8080:10000 \
  -e APP_ENV=production \
  -e NEON_HOST='ep-quiet-heart-axxjk1qg-pooler.c-4.us-east-2.aws.neon.tech' \
  -e NEON_USUARIO='neondb_owner' \
  -e NEON_PASSWORD='tu_password' \
  epyc
```

Y abre `http://localhost:8080/login.php`.

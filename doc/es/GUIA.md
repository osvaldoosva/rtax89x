# Guía: compilar y modificar el firmware del RT-AX89X

> **Nunca flashees un firmware que no hayas probado sin tener antes listo el plan de recuperación** (sección 5).
> Nada en este repositorio flashea el router: solo genera archivos `.trx`.

## 1. Qué es este repositorio

Es el árbol de código completo de **SWRT** para el RT-AX89X, basado en el código GPL de ASUS
**3.0.0.4.388_33812** (commit `Merge with 388.33812`). No hace falta "desempaquetar" el `.trx`
oficial: aquí está todo el código fuente (kernel, `rc`, `httpd`, web, lighttpd/AiCloud, etc.)
y se compila con un solo comando.

* Dentro del código ASUS el modelo se llama **`RT-AX89U`** (`BUILD_NAME="RT-AX89U"` en
  `release/src-qca-ipq806x/target.mak`). Por eso el objetivo de `make` es `rt-ax89u`: es correcto.
* SDK: `release/src-qca-ipq806x` (Qualcomm IPQ807x, userspace ARM de 32 bits, uClibc).
* Toolchain: `/opt/openwrt-gcc463.arm` (incluido en `tools/openwrt-gcc463.arm.tar.bz2`).
* El firmware resultante es **SWRT** (no el firmware de fábrica byte a byte).

## 2. Compilar

### Opción A: en GitHub (recomendada, no necesitas Linux)

El workflow `.github/workflows/github-actions.yml` compila **este** repositorio en cada push
(o a mano desde *Actions → Build testing → Run workflow*). Al terminar, el `.trx` queda en la
sección *Artifacts* de la ejecución (`firmware-rt-ax89u-<commit>`), 14 días.

### Opción B: en tu PC (Ubuntu 18.04/20.04 x64, usuario normal, **no root**)

1. Instala los paquetes de la lista de `README_en.md` (paso 2), incluidas las librerías de 32 bits
   (`lib32z1`, `libc6-dev-i386`...): el toolchain es un binario de 32 bits.
2. `git clone https://github.com/osvaldoosva/rtax89x && cd rtax89x`
3. `./build.sh` (instala el toolchain en `/opt/openwrt-gcc463.arm` y lanza `make rt-ax89u`).
4. Resultado: `release/src-qca-ipq806x/image/RT-AX89U_*.trx`.

La primera compilación tarda horas y necesita ~30 GB libres.

## 3. Cómo hacer una modificación

1. Crea una rama: `git checkout -b mi-cambio`.
2. Edita el código. Lugares habituales:
   * `release/src/router/rc/` – arranque, servicios, firewall.
   * `release/src/router/httpd/` y `release/src/router/www/` – interfaz web.
   * `release/src/router/lighttpd-1.4.39/` – AiCloud / WebDAV.
   * `release/src-qca-ipq806x/target.mak` – activar/desactivar funciones (`RTCONFIG_*`).
3. Para recompilar solo un paquete tras la primera compilación completa:
   `cd release/src-qca-ipq806x && make rt-ax89u` sigue siendo lo más seguro (reempaqueta todo).
4. Sube la rama y abre un PR: GitHub Actions compila y te deja el `.trx`.

## 4. Primera mejora incluida: AiCloud con archivos > 2 GB

En ARM de 32 bits lighttpd guardaba `Content-Length` en `size_t` (32 bits) y rechazaba con
**413** todo cuerpo mayor de `SSIZE_MAX` (2 GB). Cambios en `lighttpd-1.4.39/src`:

* `base.h`: `request.content_length` pasa a `off_t` (64 bits; LFS ya está activo por defecto
  en `configure.ac`, no existe ningún `--disable-lfs`).
* `request.c`: `Content-Length` se lee con `strtoll` (con control de desbordamiento y
  negativos), se elimina el tope de `SSIZE_MAX`, y la comprobación de memoria libre de ASUS
  compara en 64 bits (antes `(int) strtol()` se saturaba en 2 GB).

Se mantiene la protección de ASUS que rechaza un `PUT` cuyo tamaño supere la RAM libre
(evita cuelgues): la interfaz web de AiCloud sube por partes, pero un cliente WebDAV que
envíe un archivo enorme de una sola vez seguirá recibiendo 413. **Esto se debe probar en el
router**; no se pudo ejecutar aquí.

## 5. Recuperación (léelo ANTES de flashear)

1. Guarda el firmware oficial `RT-AX89X_3_0_0_4_388_33812-gab9863d.trx` y un respaldo de la
   configuración (*Administración → Restaurar/Guardar/Cargar configuración*).
2. Descarga la utilidad **ASUS Firmware Restoration** desde la página de soporte del RT-AX89X.
3. Si el router no arranca tras flashear:
   1. Conecta el PC por cable a un puerto LAN y pon IP fija `192.168.1.10`, máscara `255.255.255.0`.
   2. Apaga el router, mantén pulsado **Reset**, enciéndelo y suelta cuando el LED de
      encendido parpadee lento (modo rescate).
   3. Abre Firmware Restoration, elige el `.trx` **oficial** y pulsa *Cargar*. Espera a que reinicie.
4. Tras volver a firmware oficial, haz *reset de fábrica* si ves comportamientos raros.
5. No apagues el router durante una actualización. Prueba primero cambios pequeños.

## 6. Sobre `ax89x_build.sh` (método de parchear el `.trx` oficial)

Ver `doc/es/REVISION_ax89x_build.md`. Resumen: con este repo ya no es necesario, y tal como
estaba se habría detenido en el paso 4 o en el 5.

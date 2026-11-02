# Revisión de `ax89x_build.sh`

Script que extrae el SquashFS del `.trx` oficial 388_33812, recompila lighttpd desde el GPL de
ASUS, sustituye el binario y reempaqueta. Contrastado con el código de este repositorio
(mismo GPL 388.33812):

| Paso | Problema | Efecto |
|---|---|---|
| 4 | El regex busca `unsigned long x = strtoul(` en una sola línea y `HTTP_CONTENT_LENGTH`; en `request.c` la variable se declara aparte (`unsigned long int r;`, línea ~854) y la cadena `HTTP_CONTENT_LENGTH` no existe | Se detiene: "No reconocí el código de Content-Length" |
| 4 | Aunque se parcheara, `strtoull` no basta: el valor se guarda en `request.content_length`, que es `size_t` (32 bits), y luego `content_length > SSIZE_MAX` devuelve 413 | El límite de 2 GB seguiría |
| 4 | Exige encontrar `--disable-lfs`; no existe en el árbol (LFS ya está activo por defecto). Si apareciera en otro paquete, el `sed` cambiaría un Makefile ajeno | Se detiene, o toca otro paquete |
| 5 | `make rt-ax89u` sí es el objetivo correcto (nombre interno RT-AX89U), pero el Makefile se elige con `grep ... | head -n1`, que puede devolver otro directorio; debe ser `release/src-qca-ipq806x` | Puede compilar desde el sitio equivocado |
| 5 | No instala el toolchain (`/opt/openwrt-gcc463.arm`) ni las librerías i386 que necesita | La compilación falla |
| 5–6 | Busca `lighttpd-1.4.39/_inst/sbin/lighttpd` y módulos en `.../lib`; el Makefile instala desde `src/.libs/lighttpd` y `src/.libs/*.so` | "La compilación no generó lighttpd" aunque haya compilado |
| 6 | Valida intérprete `/lib/ld-uClibc.so.0` y NEEDED idénticos: correcto y útil, pero el GPL enlaza también `libsmbclient.so.0` de samba-3.5.8, que puede diferir del binario de fábrica | Posible falso rechazo |
| 9 | Recalcula la cabecera uImage y hace autoprueba byte a byte: buena idea. Pero el `.trx` de ASUS lleva además su propia firma/CRC de ASUS; si el router la verifica, el firmware se rechazará al subirlo | Riesgo de rechazo (no de brick) |

Conclusión: es más fiable compilar el firmware completo desde este repo (`./build.sh` o GitHub
Actions) con el parche de lighttpd aplicado en el código fuente, en lugar de trasplantar
binarios en el `.trx` oficial.

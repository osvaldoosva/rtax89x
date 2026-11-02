#!/usr/bin/env bash
# =============================================================================
# ax89x_build.sh  -  AiCloud con archivos de mas de 2 GB en el ASUS RT-AX89X
# Firmware base: 3.0.0.4.388_33812-gab9863d
#
# QUE HACE: recompila el servidor de AiCloud (lighttpd) con soporte de archivos
# grandes y arma un firmware nuevo. NO flashea nada: solo genera el archivo.
# SI ALGO NO CUADRA, SE DETIENE SOLO y te dice que enviar. Nunca sigas a mano.
#
# Version corregida (ver doc/es/REVISION_ax89x_build.md): aplica el mismo parche
# de lighttpd que este repo, compila desde release/src-qca-ipq806x, instala el
# toolchain y toma los binarios de src/.libs (donde realmente se generan).
# Ejecutalo con tu usuario normal, NO como root.
#
# ANTES DE EJECUTAR (unico trabajo manual): deja en tu carpeta Descargas
#   1) el firmware  RT-AX89X_3_0_0_4_388_33812-gab9863d.trx
#   2) el codigo GPL de ASUS para el RT-AX89X (archivo con "GPL" y "AX89" en el nombre)
# =============================================================================
set -Eeuo pipefail
[ "$(id -u)" != "0" ] || { echo "No lo ejecutes como root (usa tu usuario; pedira sudo cuando haga falta)."; exit 1; }
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # este repositorio (para el toolchain)
trap 'echo; echo "*** FALLO en la linea $LINENO. NO flashees nada. Envia las ultimas 40 lineas a Claude."' ERR

WORK="$HOME/ax89x"
SQ_OFF=2957704
FW_SIZE=53390434
mkdir -p "$WORK"; cd "$WORK"
say(){ printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"; }
stop(){ printf '\n\033[1;31mDETENIDO: %s\033[0m\n' "$*"; exit 1; }
SEARCH=("$HOME" /mnt/c/Users)

# ---------------------------------------------------------------- 0. paquetes
say "0/9 Instalando paquetes (pedira tu contrasena de Linux)"
sudo apt-get update -y
sudo apt-get install -y build-essential git squashfs-tools python3 qemu-user curl unzip \
  bison flex gawk autoconf automake libtool pkg-config libncurses-dev libssl-dev file binutils \
  gettext texinfo libltdl-dev gperf lib32z1 libc6-i386 lib32stdc++6
# el toolchain de ASUS/SWRT es un binario de 32 bits y los Makefiles esperan esta ruta
TC=/opt/openwrt-gcc463.arm
if [ ! -x "$TC/bin/arm-openwrt-linux-gcc" ]; then
  [ -f "$REPO/tools/openwrt-gcc463.arm.tar.bz2" ] || stop "No encuentro tools/openwrt-gcc463.arm.tar.bz2 (ejecuta este script desde el repo rtax89x)."
  mkdir -p "$WORK/toolchain"; tar xjf "$REPO/tools/openwrt-gcc463.arm.tar.bz2" -C "$WORK/toolchain"
  sudo ln -sfn "$WORK/toolchain/openwrt-gcc463.arm" "$TC"
fi
"$TC/bin/arm-openwrt-linux-gcc" --version >/dev/null 2>&1 || stop "El toolchain no arranca (faltan librerias de 32 bits: lib32z1 libc6-i386)."
[ "$(readlink -f /bin/sh)" = /bin/bash ] || sudo ln -sf /bin/bash /bin/sh   # el arbol GPL usa sintaxis bash

# ------------------------------------------------- 1. localizar archivos
say "1/9 Buscando el firmware y el codigo GPL"
FW=$(find "${SEARCH[@]}" -maxdepth 4 -type f -name 'RT-AX89X_3_0_0_4_388_33812*.trx' -size "${FW_SIZE}c" 2>/dev/null | head -n1 || true)
[ -n "$FW" ] || stop "No encontre el firmware .trx (53390434 bytes) en Descargas."
GPL=$(find "${SEARCH[@]}" -maxdepth 4 -type f \( -iname '*gpl*ax89*' -o -iname '*ax89*gpl*' \) \
  \( -iname '*.tar.gz' -o -iname '*.tgz' -o -iname '*.tar' -o -iname '*.zip' -o -iname '*.tar.bz2' -o -iname '*.tar.xz' \) 2>/dev/null | head -n1 || true)
[ -n "$GPL" ] || stop "No encontre el codigo GPL de ASUS (archivo con GPL y AX89 en el nombre) en Descargas."
echo "Firmware: $FW"; echo "GPL:      $GPL"
cp -f "$FW" original.trx

# ---------------------------------------- 2. extraer el firmware original
say "2/9 Extrayendo el sistema de archivos del firmware"
tail -c +$((SQ_OFF+1)) original.trx > orig.sqsh
head -c 4 orig.sqsh | grep -q hsqs || stop "El firmware no tiene el SquashFS donde se esperaba."
sudo rm -rf rootfs_orig rootfs_new
sudo unsquashfs -f -d rootfs_orig orig.sqsh > unsquashfs.log 2>&1 || true
[ -x rootfs_orig/usr/sbin/lighttpd ] || stop "No se extrajo bien el firmware (ver unsquashfs.log)."
unsquashfs -ll orig.sqsh | awk '{$3=$4=$5=""; print}' > list_orig.txt

# ----------------------------------------------- 3. codigo fuente de ASUS
say "3/9 Descomprimiendo el codigo GPL (puede tardar)"
rm -rf gpl gpl_zip; mkdir -p gpl
case "$GPL" in
  *.zip) mkdir -p gpl_zip; unzip -q -o "$GPL" -d gpl_zip
         while IFS= read -r t; do tar xf "$t" -C gpl; done < <(find gpl_zip -type f \( -name '*.tar*' -o -name '*.tgz' \)) ;;
  *)     tar xf "$GPL" -C gpl ;;
esac
LT=$(find gpl -type d -name 'lighttpd-1.4.39' | head -n1 || true)
[ -n "$LT" ] || stop "El codigo GPL no contiene lighttpd-1.4.39 (version distinta a la del firmware)."
echo "lighttpd en: $LT"

# ------------------------------------------------------ 4. aplicar el cambio
say "4/9 Aplicando el cambio a 64 bits (mismo parche que el repo)"
python3 - "$LT/src" <<'PY' || stop "El codigo de lighttpd no coincide con 388.33812. Envia la salida de arriba a Claude."
import sys, shutil, os
d = sys.argv[1]
def patch(name, pairs):
    p = os.path.join(d, name)
    s = open(p, encoding='latin1').read()
    if 'strtoll' in s and name == 'request.c':
        print(name + ': ya parcheado'); return
    for old, new in pairs:
        if s.count(old) != 1:
            print('--- no encontre en %s:\n%s' % (name, old)); sys.exit(2)
        s = s.replace(old, new)
    shutil.copy(p, p + '.orig')
    open(p, 'w', encoding='latin1').write(s)
    print(name + ': %d cambios' % len(pairs))
patch('base.h', [('\tsize_t content_length; /* returned by strtoul() */', '\toff_t content_length;')])
patch('request.c', [
 ('#include <ctype.h>\n', '#include <ctype.h>\n#include <errno.h>\n\nunsigned int get_free_mem();\n'),
 ("\t\tstrncpy(filesize, content + filesize_pos , 11);\n\t\tfilesize[11] = '\\0';",
  "\t\tstrncpy(filesize, content + filesize_pos , 20);\n\t\tfilesize[20] = '\\0';"),
 ('if(get_free_mem() < (int) strtol(filesize, NULL, 10) ) {',
  'if((long long) get_free_mem() < strtoll(filesize, NULL, 10) ) {'),
 ('\t\t\t\t\t\t\t\tunsigned long int r;\n', '\t\t\t\t\t\t\t\tlong long r;\n'),
 ("\t\t\t\t\t\t\t\tr = strtoul(ds->value->ptr, &err, 10);\n\n\t\t\t\t\t\t\t\tif (*err == '\\0') {",
  "\t\t\t\t\t\t\t\terrno = 0;\n\t\t\t\t\t\t\t\tr = strtoll(ds->value->ptr, &err, 10);\n\n\t\t\t\t\t\t\t\tif (*err == '\\0' && errno != ERANGE && r >= 0 && (long long)(off_t)r == r) {"),
 ('\t\t\t\t\t\t\t\t\tcon->request.content_length = r;', '\t\t\t\t\t\t\t\t\tcon->request.content_length = (off_t)r;'),
 ('\t\tif (con->request.content_length > SSIZE_MAX) {\n\t\t\tcon->http_status = 413;',
  '\t\tif (con->request.content_length < 0) {\n\t\t\tcon->http_status = 400;'),
])
PY
diff -u "$LT/src/request.c.orig" "$LT/src/request.c" || true
# LFS ya viene activo por defecto en configure.ac (no hay --disable-lfs que quitar); solo se comprueba
grep -q 'enable_lfs=yes' "$LT/configure.ac" || stop "configure.ac de lighttpd no activa LFS por defecto."
( cd "$LT" && { make distclean >/dev/null 2>&1 || true; rm -f config.status config.cache; } )

# ------------------------------------------------------------ 5. compilar
say "5/9 Compilando (tarda HORAS la primera vez; deja la ventana abierta)"
# RT-AX89X se llama RT-AX89U dentro del codigo de ASUS: el objetivo correcto es "make rt-ax89u"
MKF=$(find gpl -path '*/release/src-qca-ipq806x/Makefile' | head -n1 || true)
[ -n "$MKF" ] || stop "No encontre release/src-qca-ipq806x/Makefile en el codigo GPL."
TOP=$(dirname "$MKF"); echo "Compilando desde: $TOP"
grep -q 'BUILD_NAME="RT-AX89U"' "$TOP/target.mak" || stop "target.mak no define RT-AX89U."
touch "$WORK/.start"
( cd "$TOP" && make rt-ax89u 2>&1 | tee "$WORK/build.log" ) || true
# el Makefile instala lighttpd desde src/.libs (no desde _inst)
NEW=$(find "$WORK/gpl" -path '*lighttpd-1.4.39/src/.libs/lighttpd' -type f -newer "$WORK/.start" 2>/dev/null | head -n1 || true)
if [ -z "$NEW" ]; then tail -40 "$WORK/build.log"; stop "La compilacion no genero lighttpd. Envia las ultimas 40 lineas de arriba y build.log a Claude."; fi
NEWLIB=$(dirname "$NEW")   # modulos mod_*.so en src/.libs

# ---------------------------------------------- 6. validar el binario nuevo
say "6/9 Validando lo compilado"
file "$NEW" | grep -q 'ARM' || stop "El lighttpd compilado no es ARM."
readelf --dyn-syms "$NEW" | grep -q 'strtoll' || stop "El nuevo lighttpd no usa strtoll: el cambio no se compilo."
# src/.libs tiene binarios sin strip: se hace como en el Makefile de ASUS
STRIPDIR="$WORK/stripped"; rm -rf "$STRIPDIR"; mkdir -p "$STRIPDIR"
cp "$NEW" "$STRIPDIR/lighttpd"; cp "$NEWLIB"/mod_*.so "$STRIPDIR/"
"$TC/bin/arm-openwrt-linux-strip" -s "$STRIPDIR"/lighttpd "$STRIPDIR"/mod_*.so
NEW="$STRIPDIR/lighttpd"; NEWLIB="$STRIPDIR"
[ "$(readelf -l "$NEW" | grep -o '/lib/ld-uClibc.so.0')" = "/lib/ld-uClibc.so.0" ] || stop "El interprete no es uClibc."
diff <(readelf -d rootfs_orig/usr/sbin/lighttpd | grep NEEDED | sort) <(readelf -d "$NEW" | grep NEEDED | sort) \
  || stop "El nuevo lighttpd necesita librerias distintas a las del router."
# los modulos DEBEN reemplazarse todos: comparten estructuras con el nucleo
for m in rootfs_orig/usr/lib/mod_*.so; do
  b=$(basename "$m")
  [ -f "$NEWLIB/$b" ] || stop "Falta el modulo compilado $b en $NEWLIB. Mezclar modulos viejos con el nucleo nuevo hace fallar el servidor."
  file "$NEWLIB/$b" | grep -q ARM || stop "$b no es ARM."
done

# ------------------------------------------------ 7. armar el sistema de archivos
say "7/9 Reemplazando lighttpd y sus modulos"
sudo cp -a rootfs_orig rootfs_new
sudo install -m 755 "$NEW" rootfs_new/usr/sbin/lighttpd
for m in rootfs_orig/usr/lib/mod_*.so; do sudo install -m 755 "$NEWLIB/$(basename "$m")" "rootfs_new/usr/lib/$(basename "$m")"; done

# --------------------------------------- 8. prueba opcional en el PC (qemu)
say "8/9 Prueba en el PC (solo prueba mod_webdav; la prueba real es en el router)"
AV=$(df --output=avail -B1 /tmp | tail -1)
if [ "$AV" -gt 12000000000 ]; then
  mkdir -p /tmp/lt/www /tmp/lt/uploads
  cat > /tmp/lt/test.conf <<'EOF'
server.port = 8081
server.document-root = "/tmp/lt/www"
server.upload-dirs = ("/tmp/lt/uploads")
server.modules = ("mod_webdav")
webdav.activate = "enable"
webdav.is-readonly = "disable"
webdav.sqlite-db-name = "/tmp/lt/webdav.db"
EOF
  truncate -s 5G /tmp/big.bin
  for R in rootfs_orig rootfs_new; do
    echo "--- $R"
    qemu-arm -L "$WORK/$R" "$WORK/$R/usr/sbin/lighttpd" -D -f /tmp/lt/test.conf -m "$WORK/$R/usr/lib" >/tmp/lt/$R.log 2>&1 &
    sleep 3
    curl -s -o /dev/null -w "HTTP %{http_code}\n" -T /tmp/big.bin http://127.0.0.1:8081/big.bin || echo "curl fallo (resultado no concluyente)"
    pkill -f /tmp/lt/test.conf || true; rm -f /tmp/lt/www/big.bin; sleep 1
  done
  rm -f /tmp/big.bin
  echo "Esperado: rootfs_orig = HTTP 413 ; rootfs_new = HTTP 201/204. Si falla por librerias del router, no es concluyente."
else
  echo "Menos de 12 GB libres en /tmp: prueba omitida."
fi

# ------------------------------------------------ 9. construir el firmware
say "9/9 Construyendo el firmware"
cat > fixhdr.py <<'PY'
import sys, struct, zlib
orig, sqsh, out = sys.argv[1:4]
SQ_OFF = 2957704
o = open(orig, 'rb').read()
assert o[SQ_OFF:SQ_OFF+4] == b'hsqs', 'offset del SquashFS no coincide'
new = o[:SQ_OFF] + open(sqsh, 'rb').read()
hdr = bytearray(new[:64]); body = new[64:]
assert struct.unpack('>I', hdr[0:4])[0] == 0x27051956, 'no es uImage'
struct.pack_into('>I', hdr, 12, len(body))
struct.pack_into('>I', hdr, 24, zlib.crc32(body) & 0xffffffff)
struct.pack_into('>I', hdr, 4, 0)
struct.pack_into('>I', hdr, 4, zlib.crc32(bytes(hdr)) & 0xffffffff)
open(out, 'wb').write(bytes(hdr) + body)
print('OK size=%d' % len(body))
PY
# autoprueba: con el SquashFS ORIGINAL debe reproducir el firmware original byte a byte
python3 fixhdr.py original.trx orig.sqsh selftest.trx
cmp original.trx selftest.trx || stop "Autoprueba de cabecera fallo."
rm -f selftest.trx

sudo mksquashfs rootfs_new new.sqsh -comp xz -b 131072 -noappend -nopad -no-xattrs > mksquashfs.log 2>&1 \
  || { tail -20 mksquashfs.log; stop "mksquashfs fallo."; }
unsquashfs -s new.sqsh | grep -qi 'xz' || stop "El SquashFS nuevo no es xz."
unsquashfs -ll new.sqsh | awk '{$3=$4=$5=""; print}' > list_new.txt
if ! diff -q list_orig.txt list_new.txt >/dev/null; then diff list_orig.txt list_new.txt | head -20; stop "Cambiaron archivos, permisos o dispositivos ademas de lighttpd."; fi
OUT="$WORK/RT-AX89X_AiCloud_grande.trx"
python3 fixhdr.py original.trx new.sqsh "$OUT"
NS=$(stat -c %s "$OUT")
echo "Tamano original: $FW_SIZE   nuevo: $NS"
[ "$NS" -le $((FW_SIZE + 524288)) ] || stop "El firmware nuevo es mas de 512 KB mayor que el original; podria no caber en la particion."
file "$OUT" | grep -q 'u-boot legacy uImage' || stop "La cabecera del firmware nuevo no es valida."

DL=$(ls -d /mnt/c/Users/*/Downloads 2>/dev/null | head -n1 || true)
[ -n "$DL" ] && cp -f "$OUT" "$DL/" && echo "Copiado tambien a: $DL"
printf '\n\033[1;32mLISTO.\033[0m Archivo: %s\n' "$OUT"
echo "Guarda tu firmware ORIGINAL aparte y lee la seccion de recuperacion de la guia ANTES de flashear."

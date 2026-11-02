#!/bin/bash
# Compila el firmware RT-AX89X (nombre interno del modelo: RT-AX89U) desde este repo.
# Uso: ./build.sh            (no flashea nada; el .trx queda en release/src-qca-ipq806x/image/)
set -e

if [ "$(id -u)" = "0" ]; then
	echo "No compiles como root (ver README). Usa un usuario normal." >&2
	exit 1
fi

# platform.mak y Makefile esperan el toolchain en /opt/openwrt-gcc463.arm
TC=/opt/openwrt-gcc463.arm
if [ ! -x "$TC/bin/arm-openwrt-linux-gcc" ]; then
	echo "Instalando toolchain en $TC (pedira sudo)..."
	TCDIR="$(pwd)/toolchains-local"
	if [ ! -d "$TCDIR/openwrt-gcc463.arm" ]; then
		mkdir -p "$TCDIR"
		tar xjf tools/openwrt-gcc463.arm.tar.bz2 -C "$TCDIR"
	fi
	sudo ln -sfn "$TCDIR/openwrt-gcc463.arm" "$TC"
fi

# los scripts del arbol GPL usan sintaxis bash con /bin/sh
if [ "$(readlink -f /bin/sh)" != "/bin/bash" ]; then
	echo "Enlazando /bin/sh -> /bin/bash (requerido por el arbol GPL de ASUS)..."
	sudo ln -sf /bin/bash /bin/sh
fi

cd release/src-qca-ipq806x
make rt-ax89u
ls -l image/*.trx

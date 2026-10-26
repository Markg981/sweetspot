# SPDX-License-Identifier: GPL-3.0-or-later
# Ambiente di compilazione per Sweetspot (Buildroot).
# Debian stabile piu' recente (13, trixie): la controlla scripts/controlla-versioni.sh.
# Immagine fissata per digest (indice multi-architettura) e pacchetti dalla
# fotografia di snapshot.debian.org di quel giorno: la stessa ricetta da' gli
# stessi pacchetti. Si aggiornano insieme (vedi docs/supply-chain.md).
FROM debian:trixie-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad
ARG SNAPSHOT=20261024T000000Z
RUN sed -i "s#^URIs: http://deb.debian.org/\(debian[a-z-]*\)\$#URIs: http://snapshot.debian.org/archive/\1/$SNAPSHOT#" \
		/etc/apt/sources.list.d/debian.sources \
	&& ! grep -q deb.debian.org /etc/apt/sources.list.d/debian.sources \
	&& echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99snapshot
RUN apt-get update && apt-get install -y --no-install-recommends \
	bash bc build-essential ca-certificates cpio file git libelf-dev \
	libncurses-dev libssl-dev perl python3 rsync unzip wget xz-utils \
	&& rm -rf /var/lib/apt/lists/*
RUN useradd -m -u 1000 builder && mkdir -p /home/builder/.buildroot-dl /home/builder/.buildroot-ccache \
	&& chown -R builder:builder /home/builder
ENV HOME=/home/builder
WORKDIR /sweetspot

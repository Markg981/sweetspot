# SPDX-License-Identifier: GPL-3.0-or-later
# Ambiente di compilazione per Sweetspot (Buildroot).
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
	bash bc build-essential ca-certificates cpio file git libelf-dev \
	libncurses-dev libssl-dev perl python3 rsync unzip wget xz-utils \
	&& rm -rf /var/lib/apt/lists/*
RUN useradd -m -u 1000 builder && mkdir -p /home/builder/.buildroot-dl /home/builder/.buildroot-ccache \
	&& chown -R builder:builder /home/builder
ENV HOME=/home/builder
WORKDIR /sweetspot

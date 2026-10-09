################################################################################
#
# sweetspot-rpi-firmware
#
################################################################################

# Ultima release del firmware della Raspberry Pi Foundation (controllata da
# scripts/controlla-versioni.sh). Il Pi 5 ha il firmware nella EEPROM: qui
# serve solo quello del Pi 4.
SWEETSPOT_RPI_FIRMWARE_VERSION = 1.20260915
SWEETSPOT_RPI_FIRMWARE_SITE = https://raw.githubusercontent.com/raspberrypi/firmware/$(SWEETSPOT_RPI_FIRMWARE_VERSION)/boot
SWEETSPOT_RPI_FIRMWARE_SOURCE = start4.elf
SWEETSPOT_RPI_FIRMWARE_EXTRA_DOWNLOADS = fixup4.dat LICENCE.broadcom
SWEETSPOT_RPI_FIRMWARE_LICENSE = BSD-3-Clause
SWEETSPOT_RPI_FIRMWARE_LICENSE_FILES = LICENCE.broadcom
SWEETSPOT_RPI_FIRMWARE_REDISTRIBUTE = YES
SWEETSPOT_RPI_FIRMWARE_INSTALL_TARGET = NO
SWEETSPOT_RPI_FIRMWARE_INSTALL_IMAGES = YES
# Gli overlay li compila il kernel (hook qui sotto).
SWEETSPOT_RPI_FIRMWARE_DEPENDENCIES = linux

SWEETSPOT_RPI_FIRMWARE_OVERLAYS = $(LINUX_DIR)/arch/arm64/boot/dts/overlays

define SWEETSPOT_RPI_FIRMWARE_EXTRACT_CMDS
	cp $(SWEETSPOT_RPI_FIRMWARE_DL_DIR)/start4.elf \
		$(SWEETSPOT_RPI_FIRMWARE_DL_DIR)/fixup4.dat \
		$(SWEETSPOT_RPI_FIRMWARE_DL_DIR)/LICENCE.broadcom $(@D)/
endef

# Stessa disposizione di rpi-firmware di Buildroot: post-build.sh e
# post-image.sh leggono da $(BINARIES_DIR)/rpi-firmware.
define SWEETSPOT_RPI_FIRMWARE_INSTALL_IMAGES_CMDS
	$(INSTALL) -D -m 0644 $(@D)/start4.elf $(BINARIES_DIR)/rpi-firmware/start4.elf
	$(INSTALL) -D -m 0644 $(@D)/fixup4.dat $(BINARIES_DIR)/rpi-firmware/fixup4.dat
	rm -rf $(BINARIES_DIR)/rpi-firmware/overlays
	mkdir -p $(BINARIES_DIR)/rpi-firmware/overlays
	cp $(SWEETSPOT_RPI_FIRMWARE_OVERLAYS)/*.dtbo \
		$(SWEETSPOT_RPI_FIRMWARE_OVERLAYS)/overlay_map.dtb \
		$(SWEETSPOT_RPI_FIRMWARE_OVERLAYS)/hat_map.dtb \
		$(BINARIES_DIR)/rpi-firmware/overlays/
	test -f $(BINARIES_DIR)/rpi-firmware/overlays/hifiberry-dacplus.dtbo
endef

# Tutti gli alberi dei dispositivi e gli overlay del kernel in uso (con la
# configurazione del Pi solo quelli Broadcom): gli overlay corrispondono
# esattamente al kernel, come quelli che la Raspberry Pi Foundation
# pubblica con il firmware.
define SWEETSPOT_RPI_FIRMWARE_LINUX_DTBS
	$(LINUX_MAKE_ENV) $(BR2_MAKE) $(LINUX_MAKE_FLAGS) -C $(LINUX_DIR) dtbs
endef
ifeq ($(BR2_PACKAGE_SWEETSPOT_RPI_FIRMWARE),y)
LINUX_POST_BUILD_HOOKS += SWEETSPOT_RPI_FIRMWARE_LINUX_DTBS
endif

$(eval $(generic-package))

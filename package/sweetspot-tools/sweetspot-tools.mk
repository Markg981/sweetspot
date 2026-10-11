################################################################################
#
# sweetspot-tools
#
################################################################################

SWEETSPOT_TOOLS_VERSION = 1.0
SWEETSPOT_TOOLS_SITE = $(BR2_EXTERNAL_SWEETSPOT_PATH)/package/sweetspot-tools/src
SWEETSPOT_TOOLS_SITE_METHOD = local
SWEETSPOT_TOOLS_LICENSE = GPL-3.0+

define SWEETSPOT_TOOLS_BUILD_CMDS
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) -O2 -Wall \
		-o $(@D)/sweetspot-arcrc $(@D)/sweetspot-arcrc.c
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) -O2 -Wall \
		-o $(@D)/sweetspot-reboot2 $(@D)/sweetspot-reboot2.c
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) -O2 -Wall \
		-o $(@D)/sweetspot-partizione $(@D)/sweetspot-partizione.c
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) -O2 -Wall \
		-o $(@D)/sweetspot-precarica $(@D)/sweetspot-precarica.c
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) -O2 -Wall \
		-o $(@D)/sweetspot-prova-dop $(@D)/sweetspot-prova-dop.c -lm
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) -O2 -Wall \
		-o $(@D)/sweetspot-camilla $(@D)/sweetspot-camilla.c
endef

define SWEETSPOT_TOOLS_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/sweetspot-arcrc $(TARGET_DIR)/usr/bin/sweetspot-arcrc
	$(INSTALL) -D -m 0755 $(@D)/sweetspot-reboot2 $(TARGET_DIR)/usr/sbin/sweetspot-reboot2
	$(INSTALL) -D -m 0755 $(@D)/sweetspot-partizione $(TARGET_DIR)/usr/sbin/sweetspot-partizione
	$(INSTALL) -D -m 0755 $(@D)/sweetspot-precarica $(TARGET_DIR)/usr/sbin/sweetspot-precarica
	$(INSTALL) -D -m 0755 $(@D)/sweetspot-prova-dop $(TARGET_DIR)/usr/sbin/sweetspot-prova-dop
	$(INSTALL) -D -m 0755 $(@D)/sweetspot-camilla $(TARGET_DIR)/usr/sbin/sweetspot-camilla
endef

$(eval $(generic-package))

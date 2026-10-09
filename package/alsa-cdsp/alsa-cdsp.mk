################################################################################
#
# alsa-cdsp
#
################################################################################

ALSA_CDSP_VERSION = 1a1b0a3e452f87372881ffaa9391a11d0ff6d541
ALSA_CDSP_SITE = $(call github,scripple,alsa_cdsp,$(ALSA_CDSP_VERSION))
ALSA_CDSP_LICENSE = MIT
ALSA_CDSP_LICENSE_FILES = LICENSE
ALSA_CDSP_DEPENDENCIES = alsa-lib

define ALSA_CDSP_BUILD_CMDS
	$(TARGET_CC) $(TARGET_CFLAGS) -Wall -fPIC -DPIC -shared $(TARGET_LDFLAGS) \
		-o $(@D)/libasound_module_pcm_cdsp.so $(@D)/libasound_module_pcm_cdsp.c \
		-Wl,--no-as-needed -lasound -Wl,--as-needed
endef

define ALSA_CDSP_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0644 $(@D)/libasound_module_pcm_cdsp.so \
		$(TARGET_DIR)/usr/lib/alsa-lib/libasound_module_pcm_cdsp.so
endef

$(eval $(generic-package))

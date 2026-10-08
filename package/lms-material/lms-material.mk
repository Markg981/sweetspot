################################################################################
#
# lms-material - Material Skin per Lyrion Music Server
#
################################################################################

LMS_MATERIAL_VERSION = 6.4.12
LMS_MATERIAL_SOURCE = lms-material-$(LMS_MATERIAL_VERSION).zip
LMS_MATERIAL_SITE = https://github.com/CDrummond/lms-material/releases/download/$(LMS_MATERIAL_VERSION)
LMS_MATERIAL_LICENSE = MIT, GPL-2.0 (parti)

define LMS_MATERIAL_EXTRACT_CMDS
	$(UNZIP) -d $(@D) $(LMS_MATERIAL_DL_DIR)/$(LMS_MATERIAL_SOURCE)
endef

# Copia di partenza: al primo avvio va tra i plugin installati di Lyrion.
define LMS_MATERIAL_INSTALL_TARGET_CMDS
	rm -rf $(TARGET_DIR)/usr/share/sweetspot/lms-plugins/MaterialSkin
	mkdir -p $(TARGET_DIR)/usr/share/sweetspot/lms-plugins/MaterialSkin
	cp -a $(@D)/. $(TARGET_DIR)/usr/share/sweetspot/lms-plugins/MaterialSkin/
	test -f $(TARGET_DIR)/usr/share/sweetspot/lms-plugins/MaterialSkin/install.xml
endef

$(eval $(generic-package))

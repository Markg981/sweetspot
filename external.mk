include $(sort $(wildcard $(BR2_EXTERNAL_SWEETSPOT_PATH)/package/*/*.mk))

# Firmware del Wi-Fi Intel BE201 (Lunar Lake, MAC "bz"): Buildroot non ha
# l'opzione, IWLWIFI_7 copre solo la BE200 (gl). Solo le versioni "c" per
# iwlmld, il sistema gira in RAM. La licenza arriva gia' con IWLWIFI_7.
ifeq ($(BR2_PACKAGE_LINUX_FIRMWARE_IWLWIFI_7),y)
LINUX_FIRMWARE_FILES += \
	intel/iwlwifi/iwlwifi-bz-b0-fm-c0-c*.ucode \
	intel/iwlwifi/iwlwifi-bz-b0-fm-c0.pnvm
endif

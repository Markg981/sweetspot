################################################################################
#
# camilladsp
#
################################################################################

CAMILLADSP_VERSION = 4.1.3
CAMILLADSP_SITE = $(call github,HEnquist,camilladsp,v$(CAMILLADSP_VERSION))
CAMILLADSP_LICENSE = GPL-3.0 or MPL-2.0
CAMILLADSP_LICENSE_FILES = LICENSE_GLPv3.txt LICENSE_MPL2.0.txt
CAMILLADSP_DEPENDENCIES = host-rustc host-pkgconf alsa-lib

# Il progetto non pubblica il Cargo.lock: usiamo il nostro, cosi' le
# dipendenze sono sempre le stesse versioni (cargo --locked). Le dipendenze
# si scaricano in compilazione nella cache di cargo dentro la cartella dei
# download di Buildroot.
define CAMILLADSP_COPY_CARGO_LOCK
	cp $(CAMILLADSP_PKGDIR)/Cargo.lock $(@D)/Cargo.lock
endef
CAMILLADSP_POST_EXTRACT_HOOKS += CAMILLADSP_COPY_CARGO_LOCK

# Caratteristiche predefinite (il server websocket resta spento: si attiva
# solo con -p; senza, CamillaDSP 4.1 si ferma all'avvio). Lo avvia il
# plugin ALSA cdsp con i parametri del brano.
define CAMILLADSP_BUILD_CMDS
	cd $(@D) && \
	$(TARGET_MAKE_ENV) \
		$(TARGET_CONFIGURE_OPTS) \
		$(PKG_CARGO_ENV) \
		CARGO_PROFILE_RELEASE_OPT_LEVEL="3" \
		PKG_CONFIG_ALLOW_CROSS=1 \
		cargo build --release --locked --bin camilladsp
endef

define CAMILLADSP_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/target/$(RUSTC_TARGET_NAME)/release/camilladsp \
		$(TARGET_DIR)/usr/bin/camilladsp
endef

$(eval $(generic-package))

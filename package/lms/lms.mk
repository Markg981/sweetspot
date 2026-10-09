################################################################################
#
# lms - Lyrion Music Server
#
################################################################################

LMS_VERSION = 9.1.1
LMS_SITE = $(call github,LMS-Community,slimserver,$(LMS_VERSION))
LMS_LICENSE = GPL-2.0
LMS_LICENSE_FILES = License.txt
LMS_DEPENDENCIES = perl

# Cartella di Lyrion nel sistema (LMS_DIR e' riservata da Buildroot:
# e' la cartella di compilazione del pacchetto).
LMS_INSTALL_PATH = /opt/lms
LMS_PERL_MAJOR = 5.$(PERL_VERSION_MAJOR)

ifeq ($(BR2_x86_64),y)
LMS_CPAN_ARCH = x86_64-linux-thread-multi
LMS_BIN_ARCH = x86_64-linux
endif

# ARM a 64 bit (Raspberry Pi 4 e 5): Lyrion include i programmi (Bin) ma
# non i moduli compilati per Perl 5.42. Li compila il workflow "Moduli di
# Lyrion" di questo progetto con lo script ufficiale di Lyrion e li pubblica
# nella release dipendenze-lyrion; il nome del file porta la versione di
# slimserver-vendor e di Fedora, e un file pubblicato non cambia mai
# (impronta SHA-256 in lms.hash).
ifeq ($(BR2_aarch64),y)
LMS_CPAN_ARCH = aarch64-linux-thread-multi
LMS_BIN_ARCH = aarch64-linux
LMS_MODULI = lyrion-cpan-5.42-aarch64-linux-thread-multi-b62107b-fc43.tar.xz
LMS_EXTRA_DOWNLOADS = https://github.com/Markg981/sweetspot/releases/download/dipendenze-lyrion/$(LMS_MODULI)
LMS_DEPENDENCIES += $(BR2_XZCAT_HOST_DEPENDENCY) host-patchelf
# I moduli (.so) e i loro file .pm vengono dalla stessa compilazione: si
# sovrappongono a quelli di Lyrion. Fedora collega i moduli a libperl.so,
# che qui non c'e': il Perl di Buildroot e' un unico eseguibile che esporta
# gli stessi simboli. La dipendenza da libperl.so si toglie, come nei
# moduli di Lyrion per x86_64, che non la hanno.
define LMS_INSTALL_MODULI
	$(XZCAT) $(LMS_DL_DIR)/$(LMS_MODULI) | tar -C $(TARGET_DIR)$(LMS_INSTALL_PATH)/CPAN/arch -xf -
	for f in $$(find $(TARGET_DIR)$(LMS_INSTALL_PATH)/CPAN/arch -name '*.so'); do \
		for n in $$($(HOST_DIR)/bin/patchelf --print-needed $$f | grep '^libperl\.so'); do \
			$(HOST_DIR)/bin/patchelf --remove-needed $$n $$f || exit 1; \
		done; \
	done
endef
endif

# lms.hash contiene l'impronta dei moduli per ARM; il sorgente di Lyrion
# (archivio generato da GitHub) non ne ha una.
BR_NO_CHECK_HASH_FOR += $(LMS_SOURCE)

# I moduli compilati di Lyrion per Perl 5.42 usano il contesto dei thread
# in una variabile thread-local (PL_current_context), come il Perl delle
# distribuzioni Linux. perl-cross non lo rileva da solo: senza questa
# opzione i moduli non si caricano ("undefined symbol PL_current_context").
ifeq ($(BR2_PACKAGE_LMS),y)
PERL_CONF_OPTS += -Dd_thread_local=define -Dperl_thread_local=_Thread_local
endif

# Del sorgente si installa solo cio' che serve al server su questa
# architettura: niente test, skin Classic, binari e moduli di altri sistemi,
# dati ICU big-endian.
define LMS_INSTALL_TARGET_CMDS
	rm -rf $(TARGET_DIR)$(LMS_INSTALL_PATH)
	mkdir -p $(TARGET_DIR)$(LMS_INSTALL_PATH)/Bin $(TARGET_DIR)$(LMS_INSTALL_PATH)/CPAN/arch
	rsync -a \
		--exclude=/.git* --exclude=/.github --exclude=/.devcontainer \
		--exclude=/t --exclude=/Bin --exclude=/CPAN/arch \
		--exclude=/HTML/Classic --exclude='/icudt*b.dat' \
		--exclude='/Changelog*.html' --exclude=/DEVCONTAINERS.md \
		$(@D)/ $(TARGET_DIR)$(LMS_INSTALL_PATH)/
	cp -a $(@D)/Bin/$(LMS_BIN_ARCH) $(TARGET_DIR)$(LMS_INSTALL_PATH)/Bin/
	cp -a $(@D)/CPAN/arch/$(LMS_PERL_MAJOR) $(TARGET_DIR)$(LMS_INSTALL_PATH)/CPAN/arch/
	$(LMS_INSTALL_MODULI)
	for d in $(TARGET_DIR)$(LMS_INSTALL_PATH)/CPAN/arch/$(LMS_PERL_MAJOR)/*-*; do \
		[ "$${d##*/}" = "$(LMS_CPAN_ARCH)" ] || rm -rf "$$d"; \
	done
	test -d $(TARGET_DIR)$(LMS_INSTALL_PATH)/CPAN/arch/$(LMS_PERL_MAJOR)/$(LMS_CPAN_ARCH)
	# Lyrion cerca i moduli nella cartella con il nome dell'architettura
	# di Perl: perl-cross la chiama senza "-thread-multi". Config_heavy.pl
	# esiste solo li' (Config.pm anche in Net/).
	archname=$$(basename $$(dirname $$(ls $(TARGET_DIR)/usr/lib/perl5/$(PERL_VERSION)/*/Config_heavy.pl))); \
	if [ "$$archname" != "$(LMS_CPAN_ARCH)" ]; then \
		ln -sfn $(LMS_CPAN_ARCH) $(TARGET_DIR)$(LMS_INSTALL_PATH)/CPAN/arch/$(LMS_PERL_MAJOR)/$$archname; \
	fi
	mkdir -p $(TARGET_DIR)$(LMS_INSTALL_PATH)/Plugins
endef

$(eval $(generic-package))

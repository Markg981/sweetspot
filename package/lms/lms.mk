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

LMS_DIR = /opt/lms
LMS_PERL_MAJOR = 5.$(PERL_VERSION_MAJOR)

ifeq ($(BR2_x86_64),y)
LMS_CPAN_ARCH = x86_64-linux-thread-multi
LMS_BIN_ARCH = x86_64-linux
endif

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
	rm -rf $(TARGET_DIR)$(LMS_DIR)
	mkdir -p $(TARGET_DIR)$(LMS_DIR)/Bin $(TARGET_DIR)$(LMS_DIR)/CPAN/arch
	rsync -a \
		--exclude=/.git* --exclude=/.github --exclude=/.devcontainer \
		--exclude=/t --exclude=/Bin --exclude=/CPAN/arch \
		--exclude=/HTML/Classic --exclude='/icudt*b.dat' \
		--exclude='/Changelog*.html' --exclude=/DEVCONTAINERS.md \
		$(@D)/ $(TARGET_DIR)$(LMS_DIR)/
	cp -a $(@D)/Bin/$(LMS_BIN_ARCH) $(TARGET_DIR)$(LMS_DIR)/Bin/
	cp -a $(@D)/CPAN/arch/$(LMS_PERL_MAJOR) $(TARGET_DIR)$(LMS_DIR)/CPAN/arch/
	for d in $(TARGET_DIR)$(LMS_DIR)/CPAN/arch/$(LMS_PERL_MAJOR)/*-*; do \
		[ "$${d##*/}" = "$(LMS_CPAN_ARCH)" ] || rm -rf "$$d"; \
	done
	test -d $(TARGET_DIR)$(LMS_DIR)/CPAN/arch/$(LMS_PERL_MAJOR)/$(LMS_CPAN_ARCH)
	# Lyrion cerca i moduli nella cartella con il nome dell'architettura
	# di Perl: perl-cross la chiama senza "-thread-multi".
	archname=$$(basename $$(dirname $$(ls $(TARGET_DIR)/usr/lib/perl5/$(PERL_VERSION)/*/Config.pm))); \
	if [ "$$archname" != "$(LMS_CPAN_ARCH)" ]; then \
		ln -sfn $(LMS_CPAN_ARCH) $(TARGET_DIR)$(LMS_DIR)/CPAN/arch/$(LMS_PERL_MAJOR)/$$archname; \
	fi
	mkdir -p $(TARGET_DIR)$(LMS_DIR)/Plugins
endef

$(eval $(generic-package))

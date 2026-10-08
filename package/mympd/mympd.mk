################################################################################
#
# mympd
#
################################################################################

MYMPD_VERSION = 26.0.0
MYMPD_SITE = $(call github,jcorporation,myMPD,v$(MYMPD_VERSION))
MYMPD_LICENSE = GPL-3.0+
MYMPD_LICENSE_FILES = LICENSE.md

# Gli asset web (JavaScript, traduzioni) vengono preparati in fase di
# configurazione da build.sh con jq, perl e gzip dell'host.
MYMPD_DEPENDENCIES = host-jq openssl pcre2 flac libid3tag utf8proc

MYMPD_CONF_OPTS = \
	-DMYMPD_EMBEDDED_ASSETS=ON \
	-DMYMPD_ENABLE_LUA=OFF \
	-DMYMPD_ENABLE_FLAC=ON \
	-DMYMPD_ENABLE_LIBID3TAG=ON \
	-DMYMPD_ENABLE_UTF8=ON \
	-DMYMPD_ENABLE_IPV6=ON \
	-DMYMPD_DOC=OFF \
	-DMYMPD_DOC_HTML=OFF \
	-DMYMPD_MANPAGES=OFF \
	-DMYMPD_STARTUP_SCRIPT=OFF \
	-DMYMPD_BUILD_TESTING=OFF

$(eval $(cmake-package))

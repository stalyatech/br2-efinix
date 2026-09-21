################################################################################
#
# asio
#
################################################################################

ASIO_VERSION = 1-30-2
ASIO_SITE = $(call github,chriskohlhoff,asio,asio-$(ASIO_VERSION))
ASIO_LICENSE = BSL-1.0
ASIO_LICENSE_FILES = asio/LICENSE_1_0.txt
ASIO_INSTALL_STAGING = YES
ASIO_INSTALL_TARGET = NO

define ASIO_INSTALL_STAGING_CMDS
	$(INSTALL) -d $(STAGING_DIR)/usr/include
	cp -a $(@D)/asio/include/asio $(@D)/asio/include/asio.hpp $(STAGING_DIR)/usr/include/
endef

$(eval $(generic-package))

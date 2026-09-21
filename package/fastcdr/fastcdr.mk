################################################################################
#
# fastcdr
#
################################################################################

FASTCDR_VERSION = 1.0.29
FASTCDR_SITE = $(call github,eProsima,Fast-CDR,v$(FASTCDR_VERSION))
FASTCDR_LICENSE = Apache-2.0
FASTCDR_LICENSE_FILES = LICENSE
FASTCDR_INSTALL_STAGING = YES
FASTCDR_CONF_OPTS = \
	-DBUILD_TESTING=OFF

$(eval $(cmake-package))

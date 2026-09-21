################################################################################
#
# foonathan-memory
#
################################################################################

FOONATHAN_MEMORY_VERSION = 0.7-3
FOONATHAN_MEMORY_SITE = $(call github,foonathan,memory,v$(FOONATHAN_MEMORY_VERSION))
FOONATHAN_MEMORY_LICENSE = Zlib
FOONATHAN_MEMORY_LICENSE_FILES = LICENSE
FOONATHAN_MEMORY_INSTALL_STAGING = YES
FOONATHAN_MEMORY_CONF_OPTS = \
	-DFOONATHAN_MEMORY_BUILD_EXAMPLES=OFF \
	-DFOONATHAN_MEMORY_BUILD_TESTS=OFF \
	-DFOONATHAN_MEMORY_BUILD_TOOLS=OFF

$(eval $(cmake-package))

################################################################################
#
# tinyxml2-v10
#
# Fast DDS 2.6 does not build against the TinyXML2 11 API that Buildroot ships,
# so this package carries the 10.0.0 release under its own name. It installs
# the same files as the stock package: enable one or the other, never both.
#
################################################################################

TINYXML2_V10_VERSION = 10.0.0
TINYXML2_V10_SITE = $(call github,leethomason,tinyxml2,$(TINYXML2_V10_VERSION))
TINYXML2_V10_LICENSE = Zlib
TINYXML2_V10_LICENSE_FILES = LICENSE.txt
TINYXML2_V10_INSTALL_STAGING = YES
TINYXML2_V10_CPE_ID_VALID = YES

ifeq ($(BR2_STATIC_LIBS),y)
TINYXML2_V10_CONF_OPTS += -DBUILD_STATIC_LIBS=ON
endif

$(eval $(cmake-package))

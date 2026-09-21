################################################################################
#
# fastdds
#
################################################################################

FASTDDS_VERSION = 2.6.11
FASTDDS_SITE = $(call github,eProsima,Fast-DDS,v$(FASTDDS_VERSION))
FASTDDS_LICENSE = Apache-2.0
FASTDDS_LICENSE_FILES = LICENSE
FASTDDS_INSTALL_STAGING = YES
FASTDDS_DEPENDENCIES = asio fastcdr foonathan-memory tinyxml2-v10
FASTDDS_CONF_OPTS = \
	-DBUILD_TESTING=OFF \
	-DCOMPILE_EXAMPLES=OFF \
	-DCOMPILE_TOOLS=OFF \
	-DINSTALL_EXAMPLES=OFF \
	-DINSTALL_TOOLS=OFF \
	-DFASTDDS_STATISTICS=OFF \
	-DSECURITY=OFF \
	-DNO_TLS=ON \
	-DSM_RUN_RESULT=1 \
	-DSM_RUN_RESULT__TRYRUN_OUTPUT= \
	-DSQLITE3_SUPPORT=OFF \
	-DTHIRDPARTY=OFF \
	-DTHIRDPARTY_Asio=OFF \
	-DTHIRDPARTY_TinyXML2=OFF \
	-DTHIRDPARTY_UPDATE=OFF

$(eval $(cmake-package))

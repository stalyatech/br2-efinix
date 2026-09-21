################################################################################
#
# micro-xrce-dds-agent
#
################################################################################

# v2.4.0 is the Humble-aligned release: links against Fast-CDR 1.x
# (UAGENT_USE_SYSTEM_FASTCDR sets _fastcdr_version=1 in this tag's
# CMakeLists). Matches the rest of the stack: fastcdr 1.0.29 + fastdds
# 2.6.11. v2.4.3 / v3.0.x require Fast-CDR 2.
MICRO_XRCE_DDS_AGENT_VERSION = v2.4.0
MICRO_XRCE_DDS_AGENT_SITE = $(call github,eProsima,Micro-XRCE-DDS-Agent,$(MICRO_XRCE_DDS_AGENT_VERSION))
MICRO_XRCE_DDS_AGENT_LICENSE = Apache-2.0
MICRO_XRCE_DDS_AGENT_LICENSE_FILES = LICENSE
MICRO_XRCE_DDS_AGENT_INSTALL_STAGING = YES
MICRO_XRCE_DDS_AGENT_DEPENDENCIES = fastcdr fastdds

MICRO_XRCE_DDS_AGENT_CONF_OPTS = \
	-DUAGENT_SUPERBUILD=OFF \
	-DUAGENT_BUILD_TESTS=OFF \
	-DUAGENT_BUILD_EXECUTABLE=ON \
	-DUAGENT_FAST_PROFILE=ON \
	-DUAGENT_CED_PROFILE=OFF \
	-DUAGENT_DISCOVERY_PROFILE=OFF \
	-DUAGENT_SOCKETCAN_PROFILE=OFF \
	-DUAGENT_SECURITY_PROFILE=OFF \
	-DUAGENT_LOGGER_PROFILE=OFF \
	-DUAGENT_USE_SYSTEM_FASTCDR=ON \
	-DUAGENT_USE_SYSTEM_FASTDDS=ON

ifeq ($(BR2_PACKAGE_MICRO_XRCE_DDS_AGENT_P2P),y)
MICRO_XRCE_DDS_AGENT_DEPENDENCIES += micro-xrce-dds-client
MICRO_XRCE_DDS_AGENT_CONF_OPTS += \
	-DUAGENT_P2P_PROFILE=ON
else
MICRO_XRCE_DDS_AGENT_CONF_OPTS += \
	-DUAGENT_P2P_PROFILE=OFF
endif

$(eval $(cmake-package))

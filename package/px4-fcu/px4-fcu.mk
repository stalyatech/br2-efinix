################################################################################
#
# px4-fcu: PX4 firmware for the soft FCU, built out of tree
#
################################################################################

PX4_FCU_VERSION = local
PX4_FCU_SOURCE =
PX4_FCU_LICENSE = BSD-3-Clause

PX4_FCU_ELF = $(call qstrip,$(BR2_PACKAGE_PX4_FCU_ELF))
PX4_FCU_NAME = $(call qstrip,$(BR2_PACKAGE_PX4_FCU_NAME))

# Nothing is built here: the firmware runs on the FCU and comes from the
# px4-core tree (make stalya_nexus-v2_default). Only the ELF is taken, and
# its debug symbols stay behind in that tree.
define PX4_FCU_EXTRACT_CMDS
	cp $(PX4_FCU_ELF) $(@D)/px4-fcu.elf
endef

define PX4_FCU_BUILD_CMDS
	$(TARGET_CROSS)strip -g -o $(@D)/$(PX4_FCU_NAME) $(@D)/px4-fcu.elf
endef

define PX4_FCU_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0644 $(@D)/$(PX4_FCU_NAME) \
		$(TARGET_DIR)/lib/firmware/$(PX4_FCU_NAME)
endef

$(eval $(generic-package))

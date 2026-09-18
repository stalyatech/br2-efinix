################################################################################
#
# stalya-fcu: FCU remoteproc driver and FCU test firmware
#
################################################################################

STALYA_FCU_VERSION = local
STALYA_FCU_PROJECT = $(call qstrip,$(BR2_PACKAGE_STALYA_FCU_PROJECT))
STALYA_FCU_SITE = $(STALYA_FCU_PROJECT)/sw
STALYA_FCU_SITE_METHOD = local
STALYA_FCU_LICENSE = GPL-2.0 (driver)
STALYA_FCU_MODULE_SUBDIRS = linux/fcu_rproc

# The firmware runs on the FCU, not on Linux: bare-metal toolchain and the
# FCU BSP that Efinity generates into the project's embedded_sw/.
define STALYA_FCU_BUILD_CMDS
	PATH="$(call qstrip,$(BR2_PACKAGE_STALYA_FCU_BAREMETAL_BIN)):$$PATH" \
	$(MAKE) -C $(@D)/fcu_fw_test \
		PROJ_ROOT="$(STALYA_FCU_PROJECT)" \
		RISCV_BIN="$(call qstrip,$(BR2_PACKAGE_STALYA_FCU_BAREMETAL_PREFIX))" \
		MARCH=rv32imafdc_zicsr_zifencei MABI=ilp32d
endef

define STALYA_FCU_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0644 $(@D)/fcu_fw_test/build/fcu_fw_test.elf \
		$(TARGET_DIR)/lib/firmware/fcu_fw_test.elf
endef

define STALYA_FCU_INSTALL_INIT_SYSV
	$(INSTALL) -D -m 0755 $(STALYA_FCU_PKGDIR)/S30fcu $(TARGET_DIR)/etc/init.d/S30fcu
endef

$(eval $(kernel-module))
$(eval $(generic-package))

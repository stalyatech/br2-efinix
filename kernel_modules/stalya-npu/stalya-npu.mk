################################################################################
#
# stalya-npu: StalyaNPU kernel driver, libsnpu and snpu-bench
#
################################################################################

STALYA_NPU_VERSION = local
STALYA_NPU_SITE = $(call qstrip,$(BR2_PACKAGE_STALYA_NPU_SRCDIR))
STALYA_NPU_SITE_METHOD = local
STALYA_NPU_LICENSE = GPL-2.0 (driver)
STALYA_NPU_INSTALL_STAGING = YES
STALYA_NPU_MODULE_SUBDIRS = linux/driver

define STALYA_NPU_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D)/linux \
		CC="$(TARGET_CC)" AR="$(TARGET_AR)" \
		CFLAGS="$(TARGET_CFLAGS)" LDFLAGS="$(TARGET_LDFLAGS)"
endef

define STALYA_NPU_INSTALL_STAGING_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D)/linux DESTDIR=$(STAGING_DIR) install
endef

define STALYA_NPU_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/linux/snpu-bench $(TARGET_DIR)/usr/bin/snpu-bench
endef

define STALYA_NPU_INSTALL_INIT_SYSV
	$(INSTALL) -D -m 0755 $(STALYA_NPU_PKGDIR)/S31snpu $(TARGET_DIR)/etc/init.d/S31snpu
endef

$(eval $(kernel-module))
$(eval $(generic-package))

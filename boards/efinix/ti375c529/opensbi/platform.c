/*
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2026 Efinix Inc
 */

#include <sbi/riscv_asm.h>
#include <sbi/riscv_encoding.h>
#include <sbi/riscv_io.h>
#include <sbi/sbi_const.h>
#include <sbi/sbi_hart.h>
#include <sbi/sbi_platform.h>
#include <sbi/sbi_console.h>
#include <sbi/sbi_ecall_interface.h>
#include <sbi/sbi_system.h>
#include <sbi_utils/irqchip/plic.h>
#include <sbi_utils/serial/spinal-uart.h>
#include <sbi_utils/ipi/aclint_mswi.h>
#include <sbi_utils/timer/aclint_mtimer.h>
#include "soc.h"

#ifndef SYSTEM_CORES_COUNT
#define VEX_HART_COUNT  1
#else
#define VEX_HART_COUNT  SYSTEM_CORES_COUNT
#endif

#define VEX_PLATFORM_FEATURES  SBI_PLATFORM_HAS_MFAULTS_DELEGATION

#define VEX_CLINT_MTIME_LO	0xbff8
#define VEX_CLINT_MTIME_HI	0xbffc
#define VEX_CLINT_MTIMECMP_LO	0x4000
#define VEX_CLINT_MTIMECMP_HI	0x4004

#define VEX_UART_ADDR 		(void*)SYSTEM_UART_0_IO_CTRL
#define VEX_CLINT_MSWI_ADDR	(SYSTEM_CLINT_CTRL + CLINT_MSWI_OFFSET)
#define VEX_CLINT_MTIMER_ADDR	(SYSTEM_CLINT_CTRL + VEX_CLINT_MTIME_LO)
#define VEX_CLINT_MTIMECMP_ADDR (SYSTEM_CLINT_CTRL + VEX_CLINT_MTIMECMP_LO)

static struct aclint_mswi_data mswi = {
	.addr = VEX_CLINT_MSWI_ADDR,
	.size = ACLINT_MSWI_SIZE,
	.first_hartid = 0,
	.hart_count = VEX_HART_COUNT,
};

static struct aclint_mtimer_data mtimer = {
	.mtime_freq = SYSTEM_CLINT_HZ,
	.mtime_addr = VEX_CLINT_MTIMER_ADDR,
	.mtime_size = ACLINT_DEFAULT_MTIME_SIZE,
	.mtimecmp_addr = VEX_CLINT_MTIMECMP_ADDR,
	.mtimecmp_size = ACLINT_DEFAULT_MTIMECMP_SIZE,
	.first_hartid = 0,
	.hart_count = VEX_HART_COUNT,
#if __riscv_xlen == 32
	.has_64bit_mmio = false,
#elif __riscv_xlen == 64
	.has_64bit_mmio = true,
#endif
};

void vex_enable_cbo(void)
{
    unsigned long menvcfg = csr_read(CSR_MENVCFG);
    menvcfg |= ENVCFG_CBCFE;  // enable CBO clean/flush
    menvcfg |= ENVCFG_CBIE_INV << ENVCFG_CBIE_SHIFT; //enable CBO invalidate
    csr_write(CSR_MENVCFG, menvcfg);
    sbi_printf("CBO extensions enabled in MENVCFG: 0x%lx\n", menvcfg);
}

#ifdef SYSTEM_AMP_CTRL
/*
 * ti375_oob: reboot through the amp_ctrl block of the design (rtl/amp_ctrl.v).
 * Writing the key to SYS_RESET holds the board's reset button input low for a
 * moment: the hard SoC, the FCU and the DDR start over exactly as after a
 * press of the button, and the FSBL boots the board again. There is no way to
 * remove power, so shutdown is left unsupported.
 */
#define AMP_REG_ID		0x00
#define AMP_ID_VALUE		0x414D5001
#define AMP_REG_SYS_RESET	0x1C
#define AMP_SYS_RESET_KEY	0x52535421	/* "RST!" */

static int amp_reset_check(u32 type, u32 reason)
{
	switch (type) {
	case SBI_SRST_RESET_TYPE_COLD_REBOOT:
	case SBI_SRST_RESET_TYPE_WARM_REBOOT:
		return 1;
	default:
		return 0;
	}
}

static void amp_reset(u32 type, u32 reason)
{
	writel(AMP_SYS_RESET_KEY, (void *)(SYSTEM_AMP_CTRL + AMP_REG_SYS_RESET));
	while (1)
		wfi();
}

static struct sbi_system_reset_device amp_reset_dev = {
	.name			= "ti375_oob-amp_ctrl",
	.system_reset_check	= amp_reset_check,
	.system_reset		= amp_reset,
};
#endif

static int vex_final_init(bool cold_boot)
{
#ifdef SYSTEM_AMP_CTRL
	/* Only a bitstream that has amp_ctrl answers with its ID. */
	if (cold_boot && readl((void *)(SYSTEM_AMP_CTRL + AMP_REG_ID)) == AMP_ID_VALUE)
		sbi_system_reset_add_device(&amp_reset_dev);
#endif
	return 0;
}

static int vex_early_init(bool cold_boot)
{

#if defined(__riscv_xlen) && __riscv_xlen == 64
#if defined(SYSTEM_RISCV_ISA_EXT_ZICBOM) && SYSTEM_RISCV_ISA_EXT_ZICBOM
	vex_enable_cbo();
#endif
#endif

	if (!cold_boot)
		return 0;

	return spinal_uart_init((unsigned long)VEX_UART_ADDR);
}

static int vex_irqchip_init(void)
{
	return 0;
}

static int vex_ipi_init(void)
{
	return aclint_mswi_cold_init(&mswi);
}

static int vex_timer_init(void)
{
	return aclint_mtimer_cold_init(&mtimer, NULL);
}

const struct sbi_platform_operations platform_ops = {
	.early_init		= vex_early_init,
	.final_init		= vex_final_init,
	.irqchip_init		= vex_irqchip_init,
	.ipi_init		= vex_ipi_init,
	.timer_init		= vex_timer_init,
};

const struct sbi_platform platform = {
	.opensbi_version	= OPENSBI_VERSION,
	.platform_version	= SBI_PLATFORM_VERSION(0x0, 0x01),
	.name			= "Efinix Titanium Ti375C529",
	.features		= VEX_PLATFORM_FEATURES,
	.hart_count		= VEX_HART_COUNT,
	.hart_stack_size	= SBI_PLATFORM_DEFAULT_HART_STACK_SIZE,
	.heap_size		= SBI_PLATFORM_DEFAULT_HEAP_SIZE(VEX_HART_COUNT),
	.platform_ops_addr	= (unsigned long)&platform_ops
};

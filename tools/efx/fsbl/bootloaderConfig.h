///////////////////////////////////////////////////////////////////////////////
// ti375_oob — first-stage bootloader for the hardened RISC-V SoC.
//
// Runs from the hard SoC's on-chip RAM (0xF900_0000), placed there by the
// bitstream through OCR_FILE_PATH in ti375_oob.peri.xml. It
//
//   1. prints a banner on UART0, the Linux console
//   2. starts the soft FCU SoC through amp_ctrl, unless it is already running
//   3. copies OpenSBI and U-Boot from the boot flash (SPI0) into DDR
//   4. releases the other harts and jumps to OpenSBI
//
// Step 2 comes first on purpose: the FCU carries the flight stack, so it
// starts within milliseconds of configuration, before anything that could
// fail on the Linux side. After a reboot of the hard SoC alone, amp_ctrl still
// shows the FCU running and it is left untouched (remoteproc attaches later).
//
// Derived from boards/efinix/common/bootloaderConfig.h (RV32 path). The flash
// offsets must agree with the U-Boot mtdparts and the flash programming map.
///////////////////////////////////////////////////////////////////////////////
#pragma once

#include "bsp.h"
#include "io.h"
#include "start.h"
#include "spiFlash.h"
#include "amp_ctrl.h"       /* ti375_oob/sw/amp, added to the include path by efx */

#if __riscv_xlen != 32
#error "ti375_oob hard SoC is RV32"
#endif

#define SPI                     SYSTEM_SPI_0_IO_CTRL
#define SPI_CS                  0

#define OPENSBI_MEMORY          0x02000000
#define UBOOT_MEMORY            0x02040000

#define OPENSBI_FLASH           0x00600000
#define OPENSBI_SIZE            0x040000

#define UBOOT_SBI_FLASH         0x00680000
#define UBOOT_SIZE              0x0C0000

#define UART_0_SAMPLE_PER_BAUD  8
#define UART_0_BAUD_RATE        115200

static void configure_uart(void)
{
    Uart_Config uart0;
    uart0.dataLength   = BITS_8;
    uart0.parity       = NONE;
    uart0.stop         = ONE;
    uart0.clockDivider = BSP_CLINT_HZ / (UART_0_BAUD_RATE * UART_0_SAMPLE_PER_BAUD) - 1;
    uart_applyConfig(BSP_UART_TERMINAL, &uart0);
}

static void print_hex(const char *label, u32 value)
{
    bsp_printf_s((char *)label);
    bsp_printHex(value);
    bsp_printf_s("\r\n");
}

// Start the FCU. Its test image (sw/fcu_test) lives in the FCU's own on-chip
// RAM, so there is nothing to load: releasing the hold is enough. A NuttX
// build would be copied into its DDR carve-out and BOOT_ADDR set here first.
static void amp_start_fcu(void)
{
    u32 id = read_u32(AMP_HOST_BASE + AMP_REG_ID);

    if (id != AMP_ID_VALUE) {
        print_hex("AMP: no amp_ctrl, ID reads 0x", id);
        return;
    }

    if (!(read_u32(AMP_HOST_BASE + AMP_REG_CTRL) & AMP_CTRL_FCU_HOLD)) {
        bsp_printf_s("AMP: FCU already running, left alone\r\n");
        return;
    }

    write_u32(0, AMP_HOST_BASE + AMP_REG_CTRL);
    print_hex("AMP: FCU released, STATUS 0x", read_u32(AMP_HOST_BASE + AMP_REG_STATUS));
}

void bspMain(void)
{
    configure_uart();
    bsp_printf_s("\r\n\r\nti375_oob hard SoC FSBL, built " __DATE__ " " __TIME__ "\r\n");

    amp_start_fcu();

    spiFlash_init(SPI, SPI_CS);
    spiFlash_wake(SPI, SPI_CS);
    spiFlash_exit4ByteAddr(SPI, SPI_CS);

    bsp_printf_s("OpenSBI copy\r\n");
    spiFlash_f2m(SPI, SPI_CS, OPENSBI_FLASH, OPENSBI_MEMORY, OPENSBI_SIZE);
    bsp_printf_s("U-Boot copy\r\n");
    spiFlash_f2m(SPI, SPI_CS, UBOOT_SBI_FLASH, UBOOT_MEMORY, UBOOT_SIZE);

    void (*userMain)(u32, u32, u32) = (void (*)(u32, u32, u32))OPENSBI_MEMORY;
#ifdef SMP
    smp_unlock(userMain);
#endif
    bsp_printf_s("Starting OpenSBI\r\n");
    userMain(0, 0, 0);
}

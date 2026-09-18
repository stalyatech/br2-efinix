/*
 * ti375_oob — peripheral map overlay for the hardened RISC-V SoC (efx_hard_soc)
 *
 * This file is appended to a *copy* of the project's soc.h by `efx config
 * configure`, just before the closing #endif. The original soc.h in the Efinity
 * project is never modified.
 *
 * It describes the fabric peripherals that the hard SoC reaches in the
 * ti375_oob RTL from branch stalya-fmu_v3.0-npu onwards, where the hard SoC is
 * the boot master and the soft FCU runs NuttX under its control. Keep it in
 * step with ti375_oob_top.v: the addresses below are fixed by
 *
 *   u_hs_axi_split       takes the 32 MB window 0xEA00_0000 out of AXI-A
 *   u_AXIS_1to2_switch   decodes that window's low 25 bits:
 *                        port 0 gTSE  at 0x000_0000, 16 MB  (24 address bits)
 *                        port 1 gSDHC at 0x100_0000, 64 KB  (16 address bits)
 *                        (ip/gAXIS_1to2_switch/axi_interconnect.vh)
 *   the APB split        hard SoC APB window 0xE810_0000 by PADDR[15:14]
 *
 * WHY THIS FILE EXISTS
 * --------------------
 * init.sh injects a hard-coded AXI slave map when given -u (unified hardware)
 * or -e (example design). For a hardened SoC that map puts slave 0 at
 * 0xE800_0000, on top of this SoC's own peripherals at 0xE801_0000 (UART0)
 * through 0xE805_0000 (watchdog). So efx never passes -u/-e and supplies this
 * map instead.
 *
 * HARD SoC MAP
 * ------------
 *   DDR                 0x0000_1000  size 0xE7FF_F000   shared with the FCU,
 *                                                       same addresses
 *   AXI_A window        0xE800_0000  size 0x1000_0000
 *     soft logic block  0xE800_0000 .. 0xE8FF_FFFF      decodes bits [23:0]
 *       UART0/1/2       0xE801_0000 / _1000 / _2000     UART0 is the console
 *       I2C0/1/2        0xE802_0000 / _1000 / _2000     pins on the FCU
 *       SPI0/1/2        0xE803_0000 / _1000 / _2000     SPI0/1 = boot flashes
 *       GPIO0           0xE804_0000                     pins on the FCU
 *       Watchdog        0xE805_0000
 *       APB window      0xE810_0000  size 0x1_0000
 *         gDMA          0xE810_0000  size 0x4000        PADDR[15:14] = 00
 *         StalyaNPU     0xE810_4000  size 0x4000        PADDR[15:14] = 01
 *         amp_ctrl      0xE810_8000  size 0x40          PADDR[15]    = 1
 *     gTSE              0xEA00_0000  size 0x100_0000
 *     gSDHC             0xEB00_0000  size 0x1_0000
 *   CLINT               0xF8B0_0000
 *   PLIC                0xF8C0_0000
 *   On-chip RAM A       0xF900_0000  size 0x4000
 *
 * HARD SoC PLIC LINES (userInterruptA..L = PLIC 1..12)
 *   1 UART0   4 SPI0   5 SPI1   6 gSDHC   7 gDMA ch0   8 gDMA ch1
 *   9 NPU0   10 NPU1  11 amp_ctrl doorbell from the FCU   12 watchdog
 *   2, 3 tied low. These lines are already declared in soc.h; nothing to
 *   define for them here.
 */

/* gTSE: triple-speed Ethernet MAC control and status registers. */
#define SYSTEM_AXI_SLAVE_0_IO_CTRL      0xea000000
#define SYSTEM_AXI_SLAVE_0_IO_CTRL_SIZE 0x1000000

/* gSDHC: SD host controller registers (SDHCI compatible). */
#define SYSTEM_AXI_SLAVE_1_IO_CTRL      0xeb000000
#define SYSTEM_AXI_SLAVE_1_IO_CTRL_SIZE 0x10000

/* AMP control block, host port. See rtl/amp_ctrl.v in the ti375_oob repo. */
#define SYSTEM_AMP_CTRL                 0xe8108000
#define SYSTEM_AMP_CTRL_SIZE            0x40

/*
 * No SYSTEM_AXI_<letter>_BMB defines here, and no redefinition of
 * SYSTEM_AXI_A_BMB.
 *
 * soc.h already declares the real CPU-side window (0xE800_0000, 256 MB), and the
 * device tree generator turns that into the `axi0` simple-bus. Both slaves above
 * fall inside it, so they are emitted as children of `axi0` automatically, at
 * offsets 0x2000000 and 0x3000000.
 *
 * Adding SYSTEM_AXI_B_BMB / SYSTEM_AXI_C_BMB on top of that makes the generator
 * emit a *second* bus describing the same addresses, and the device tree fails
 * to compile with a duplicate 'axi_slave1' label. Efinix's own reference maps
 * in init.sh define both, but they also delete SYSTEM_AXI_A_BMB first and
 * re-point it at the slave window — an arrangement that does not apply here,
 * where the hardened SoC's own peripherals live inside that same window.
 */

# Device tree generator overrides

`sapphire-soc-dt-generator` builds its device trees from `soc.h` plus a stack of
JSON config files. Its generic files — `config/<type>/generic/*.json` — describe
*what a peripheral node looks like*, but not *which device instance it is*. That
binding comes from an override file, and Efinix only ship overrides for their own
reference designs, selected by `init.sh`'s `-u` (unified hardware) and `-e`
(example design) flags.

Neither applies to `ti375_oob`, and `-u`/`-e` would also inject an AXI map that
collides with this SoC's own peripherals. So `efx config` supplies the bindings
from here instead.

## How they get used

`init.sh` resolves its override directory as
`config/<type>/<arch>/<override_tag>`, and the board-specific directory as
`<that>/<board>`. With no `-u`/`-e` the tag is empty, so the board directory
becomes:

```
config/linux/32/ti375c529/
config/uboot/32/ti375c529/
```

`efx config configure` copies everything from `dtoverlay/linux/` and
`dtoverlay/uboot/` into those directories before running `init.sh`, which then
finds them with no extra flags. The generator checkout is cloned at runtime and
not tracked by git, which is exactly why these files live here instead.

A file is only consulted if its feature is listed in `DT_FEATURES`.

## Status

The ti375_oob RTL on branch `stalya-fmu_v3.0-npu` gives the hard SoC the SD
host, the Ethernet MAC and its DMA (see `socmap/ti375_oob_hard.h` for the map).
Earlier bitstreams give all three to the soft FCU SoC, so `DT_FEATURES` stays
empty by default and has to be switched on for a v3.0 bitstream.

| Feature | Override | State |
|---|---|---|
| `sdhc` | `linux/sdhc.json`: `axi_slave1`, PLIC 6 | ready |
| `spi` (always on) | `linux/spi-nor.json`: boot flash partitions matching `efx flash image`; disables UART1/2, SPI2, I2C0-2 and GPIO0 | ready |
| `gpio` (always on) | `linux/gpio_irq.json`: disables the `gpio-irq-example` node | ready |
| `ethernet` | not written yet | see below |

`spi` and `gpio` are switched on by init.sh whenever the word appears in
`soc.h`, so their board files are always read. The peripheral overrides sit in
`spi-nor.json` for that reason. Those peripherals have no pins in ti375_oob, and
the PLIC lines soc.h pairs them with carry gSDHC, gDMA, StalyaNPU and the
amp_ctrl doorbell instead (see the table in `socmap/ti375_oob_hard.h`).

`ethernet` needs more than an address. The generic config wires the MAC to a DMA
node (`axistream-connected = <&dma0>`), so gDMA needs a node of its own or the
device tree will not compile. On v3.0 gDMA sits in the lowest 16 KB of the hard
SoC's only APB window (`0xE810_0000`), which it shares with the StalyaNPU CSRs
(`+0x4000`) and amp_ctrl (`+0x8000`). The generator turns that window into a
single 64 KB `apb_slave0` node, so the DMA binding has to describe a sub-range
of it rather than the whole window — which the stock JSON cannot express.

For a v3.0 bitstream:

1. `DT_FEATURES=sdhc` in `efx.conf`.
2. `efx config regen-dt && efx kernel rebuild`.

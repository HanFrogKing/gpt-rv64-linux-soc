// SPDX-License-Identifier: GPL-2.0-only
/* Fixed physical noncoherent platform; no fictional Zicbom/PBMT/coherency. */
#include <linux/init.h>
#include <linux/io.h>
#include <linux/of_address.h>
#include <linux/spinlock.h>
#include <linux/errno.h>
#include <linux/sizes.h>
#include <asm/cacheflush.h>
#include <asm/dma-noncoherent.h>
#include <asm/rv64lab-dma.h>
#include "rv64lab-dma-protocol.h"

static DEFINE_RAW_SPINLOCK(maint_lock);
static void __iomem *maint_base;
static bool configured;

static u64 control_read(void *ctx, unsigned int offset)
{
	return readq((void __iomem *)ctx + offset);
}

static void control_write(void *ctx, unsigned int offset, u64 value)
{
	writeq(value, (void __iomem *)ctx + offset);
}

static void cache_range(phys_addr_t paddr, size_t bytes, unsigned int op)
{
	struct rv64lab_dma_io io = { control_read, control_write, maint_base };
	u64 first, last, status = 0;
	unsigned long flags;
	int rc = rv64lab_dma_range(paddr, bytes, &first, &last);
	if (rc == 1)
		return;
	if (rc || !maint_base)
		panic("rv64lab-dma: invalid range/unready %pa bytes=%zu rc=%d\n",
		      &paddr, bytes, rc);
	for (;;) {
		/* Bound IRQ exclusion to one line, not a whole multi-MiB buffer. */
		raw_spin_lock_irqsave(&maint_lock, flags);
		rc = rv64lab_dma_line(&io, first, op, &status);
		raw_spin_unlock_irqrestore(&maint_lock, flags);
		/* Architecture hooks have no error return. Never silently continue DMA. */
		if (rc)
			panic("rv64lab-dma: maintenance failed addr=%llx op=%u status=%llx rc=%d\n",
			      first, op, status, rc);
		if (first == last)
			break;
		first += RV64LAB_DMA_LINE;
	}
}

static void cache_clean(phys_addr_t paddr, size_t bytes)
{
	cache_range(paddr, bytes, 0);
}
static void cache_invalidate(phys_addr_t paddr, size_t bytes)
{
	cache_range(paddr, bytes, 1);
}
static void cache_flush(phys_addr_t paddr, size_t bytes)
{
	cache_range(paddr, bytes, 2);
}
static const struct riscv_nonstd_cache_ops cache_ops = {
	.wback = cache_clean, .inv = cache_invalidate, .wback_inv = cache_flush,
};

void __init rv64lab_dma_early_init(void)
{
	struct device_node *np, *pool;
	struct resource control, memory;
	bool valid;
	if (!of_machine_is_compatible("rv64lab,rk-zynq7020-f"))
		return;
	np = of_find_compatible_node(NULL, NULL, "rv64lab,dma-cache-control-v1");
	if (!np)
		return;
	valid = of_device_is_available(np) && !of_address_to_resource(np, 0, &control) &&
		control.start == 0x03000000 && resource_size(&control) == SZ_4K;
	of_node_put(np);
	pool = of_find_node_by_path("/reserved-memory/dma-pool@87000000");
	valid = valid && pool && of_device_is_compatible(pool, "shared-dma-pool") &&
		of_property_read_bool(pool, "no-map") &&
		of_property_read_bool(pool, "linux,dma-default") &&
		!of_property_read_bool(pool, "reusable") &&
		!of_address_to_resource(pool, 0, &memory) && memory.start == 0x87000000 &&
		resource_size(&memory) >= SZ_4K && resource_size(&memory) <= SZ_8M &&
		!(resource_size(&memory) & (SZ_4K - 1));
	of_node_put(pool);
	if (!valid)
		panic("rv64lab-dma: invalid controller/physical uncached pool DT\n");
	/* setup_arch: before alignment is frozen and before devices can DMA.
	 * ioremap needs the later allocator; no dynamic mapping is attempted here.
	 */
	riscv_cbom_block_size = RV64LAB_DMA_LINE;
	riscv_noncoherent_register_cache_ops(&cache_ops);
	riscv_noncoherent_supported();
	configured = true;
}

static int __init rv64lab_dma_map_init(void)
{
	if (!configured)
		return 0;
	/* early initcall runs after MM/slab init, before coherent pool/devices. */
	maint_base = ioremap(0x03000000, SZ_4K);
	if (!maint_base || readq(maint_base + 32) != RV64LAB_DMA_ID)
		panic("rv64lab-dma: controller identity/mapping failed\n");
	if (readq(maint_base + 16) & 9)
		panic("rv64lab-dma: controller busy/fatal at init\n");
	pr_info("RV64LAB_DMA_READY line=32 pool=physical-uncached hooks=clean,invalidate,flush\n");
	return 0;
}
early_initcall(rv64lab_dma_map_init);

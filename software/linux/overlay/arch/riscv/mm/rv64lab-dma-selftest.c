// SPDX-License-Identifier: GPL-2.0-only
/* Explicit simulator-only device. Tests real Linux DMA APIs on actual CPU RTL.
 * No USB emulation or claims of a physical DMA controller. The external RAM
 * agent responds only to real writes to a reserved uncached doorbell page.
 */
#include <linux/dma-direct.h>
#include <linux/dma-map-ops.h>
#include <linux/dma-mapping.h>
#include <linux/io.h>
#include <linux/mm.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/sizes.h>

struct ram_agent { void __iomem *box; u64 sequence; };
#define MUST(x) do { if (!(x)) panic("RV64LAB_DMA_SELFTEST_FAIL line=%d: %s\n", __LINE__, #x); } while (0)

static u64 agent(struct ram_agent *a, unsigned int op, dma_addr_t address, u64 value)
{
	unsigned int n;
	MUST(address >= 0x00200000 && address <= 0x07fffff8 && !(address & 7));
	writeq(address, a->box + 8);
	writeq(value, a->box + 16);
	writeq(++a->sequence, a->box + 32);
	/* Ownership was transferred with DMA API before this doorbell. */
	dma_wmb();
	writeq(op, a->box);
	for (n = 0; n < 4096; n++)
		if (readq(a->box + 40) == a->sequence)
			return readq(a->box + 24);
	panic("RV64LAB_DMA_SELFTEST_FAIL agent timeout\n");
}

static int test_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct ram_agent a = { };
	struct page *page;
	volatile u64 *coherent, *spare, *data;
	dma_addr_t handle, spare_handle, stream;
	phys_addr_t physical;
	void __iomem *control;
	u32 before, after;
	unsigned int i;
	MUST(!dev_is_dma_coherent(dev));
	MUST(dma_get_cache_alignment() >= 32);
	MUST(!dma_set_mask_and_coherent(dev, DMA_BIT_MASK(32)));
	a.box = ioremap(0x877ff000, SZ_4K);
	control = ioremap(0x03000000, SZ_4K);
	MUST(a.box && control);
	before = readq(control + 16) >> 32;

	coherent = dma_alloc_coherent(dev, PAGE_SIZE, &handle, GFP_KERNEL);
	spare = dma_alloc_coherent(dev, PAGE_SIZE, &spare_handle, GFP_KERNEL);
	MUST(coherent && spare && handle != spare_handle);
	MUST(handle >= 0x07000000 && handle + PAGE_SIZE <= 0x077ff000);
	MUST(spare_handle >= 0x07000000 && spare_handle + PAGE_SIZE <= 0x077ff000);
	MUST(dma_to_phys(dev, handle) == handle + 0x80000000ULL);
	for (i = 0; i < PAGE_SIZE / 8; i++)
		MUST(coherent[i] == 0 && spare[i] == 0);
	coherent[0] = 0x1122334455667788ULL;
	MUST(agent(&a, 1, handle, 0) == coherent[0]);
	agent(&a, 2, handle, 0x8877665544332211ULL);
	MUST(coherent[0] == 0x8877665544332211ULL);
	dma_free_coherent(dev, PAGE_SIZE, (void *)coherent, handle);
	coherent = dma_alloc_coherent(dev, PAGE_SIZE, &handle, GFP_KERNEL);
	MUST(coherent && handle >= 0x07000000 && handle < 0x077ff000);
	MUST(coherent[0] == 0 && agent(&a, 1, handle, 0) == 0);
	/* Oversized allocation must fail, never fall back to cached normal RAM. */
	{
		dma_addr_t rejected;
		void *p = dma_alloc_coherent(dev, SZ_8M + PAGE_SIZE, &rejected, GFP_KERNEL);
		MUST(!p);
	}

	page = alloc_page(GFP_KERNEL);
	MUST(page);
	physical = page_to_phys(page);
	MUST(physical >= 0x80200000 && physical + PAGE_SIZE <= 0x88000000 &&
	     !(physical >= 0x87000000 && physical < 0x87800000));
	data = page_address(page);
	MUST(data);
	data[0] = 0x746f5f6465766963ULL;
	stream = dma_map_single(dev, (void *)data, 64, DMA_TO_DEVICE);
	MUST(!dma_mapping_error(dev, stream) && stream + 0x80000000ULL == physical);
	MUST(agent(&a, 1, stream, 0) == 0x746f5f6465766963ULL);
	dma_unmap_single(dev, stream, 64, DMA_TO_DEVICE);

	data[0] = 0x6f6c645f63616368ULL;
	data[1] = 0x6e65696768626f75ULL;
	stream = dma_map_single(dev, (void *)data, 64, DMA_FROM_DEVICE);
	MUST(!dma_mapping_error(dev, stream));
	agent(&a, 2, stream, 0x66726f6d5f646d61ULL);
	dma_unmap_single(dev, stream, 64, DMA_FROM_DEVICE);
	MUST(data[0] == 0x66726f6d5f646d61ULL && data[1] == 0x6e65696768626f75ULL);

	data[0] = 0x6269646972656374ULL;
	stream = dma_map_single(dev, (void *)data, 64, DMA_BIDIRECTIONAL);
	MUST(!dma_mapping_error(dev, stream));
	MUST(agent(&a, 1, stream, 0) == 0x6269646972656374ULL);
	agent(&a, 2, stream, 0x6465766963655f32ULL);
	dma_sync_single_for_cpu(dev, stream, 64, DMA_BIDIRECTIONAL);
	MUST(data[0] == 0x6465766963655f32ULL);
	data[0] = 0x6370755f61676169ULL;
	dma_sync_single_for_device(dev, stream, 64, DMA_BIDIRECTIONAL);
	MUST(agent(&a, 1, stream, 0) == 0x6370755f61676169ULL);
	dma_unmap_single(dev, stream, 64, DMA_BIDIRECTIONAL);

	data[0] = 0x666c7573685f6f6bULL;
	arch_dma_prep_coherent(page, 64);
	MUST(agent(&a, 1, physical - 0x80000000ULL, 0) == 0x666c7573685f6f6bULL);
	after = readq(control + 16) >> 32;
	MUST((u32)(after - before) == 16 && !(readq(control + 16) & 0x3d));
	__free_page(page);
	dma_free_coherent(dev, PAGE_SIZE, (void *)coherent, handle);
	dma_free_coherent(dev, PAGE_SIZE, (void *)spare, spare_handle);
	iounmap(a.box);
	iounmap(control);
	pr_info("RV64LAB_DMA_SELFTEST_PASS coherent=zero,reuse,visibility,exhaust streaming=to,from,bidir,sync,flush maint=16 offset=80000000 agent_reads=6 agent_writes=3\n");
	return 0;
}
static const struct of_device_id matches[] = {
	{ .compatible = "rv64lab,simulation-only-dma-selftest" }, { }
};
static struct platform_driver test_driver = {
	.probe = test_probe,
	.driver = { .name = "rv64lab-simulation-dma-selftest", .of_match_table = matches },
};
module_platform_driver(test_driver);
MODULE_LICENSE("GPL");

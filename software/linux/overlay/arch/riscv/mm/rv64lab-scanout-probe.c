// SPDX-License-Identifier: GPL-2.0-only
/* R107 explicit opt-in built-in diagnostic, not a DRM driver.
 * R103 STOP is not a drain acknowledgment. After the first RUN write, retain
 * coherent storage and binding until coordinated whole-system reset, including
 * error paths. No remove/unbind/module-unload/suspend contract is provided.
 */
#include <linux/bitops.h>
#include <linux/crc32.h>
#include <linux/dma-direct.h>
#include <linux/dma-map-ops.h>
#include <linux/dma-mapping.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/jiffies.h>
#include <linux/module.h>
#include <linux/mm.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/slab.h>
#include <linux/workqueue.h>
#include "r107-pattern.h"

#define REG_STATUS 0x10
#define REG_SEQUENCE 0x1c
struct scan_probe {
 struct device *dev;
 void __iomem *ctl;
 void *frame;
 dma_addr_t handle;
 u32 crc, last_good, errors[4];
 unsigned int stable;
 unsigned long deadline;
 bool qualified, failed, passed;
 struct delayed_work work;
};

static void fail(struct scan_probe *p, const char *reason)
{
 if (!p->failed)
  dev_err(p->dev, "R107_SCANOUT_FAIL %s; RUN/storage retained until common reset\n", reason);
 p->failed = true;
}

static void observe(struct work_struct *work)
{
 struct scan_probe *p = container_of(to_delayed_work(work), struct scan_probe, work);
 u32 seq = readl(p->ctl + REG_SEQUENCE), status, good, crc, errors[4];
 unsigned int i;
 int rc;
 if (p->failed)
  return;
 /* Sole software snapshot owner. No arbitrary /dev/mem access concurrently. */
 if (readl(p->ctl + REG_STATUS) & BIT(4)) {
  fail(p, "snapshot already busy");
  return;
 }
 writel(1, p->ctl + 0x18);
 rc = readl_poll_timeout(p->ctl + REG_STATUS, status,
                        !(status & BIT(4)) && readl(p->ctl + REG_SEQUENCE) != seq,
                        100, 100000);
 if (rc || readl(p->ctl + REG_SEQUENCE) != seq + 1 ||
     (status & 0x63) != 0x63) {
  fail(p, "snapshot timeout/sequence/RUN/lock/configuration");
  return;
 }
 crc = readl(p->ctl + 0x20);
 good = readl(p->ctl + 0x28);
 for (i = 0; i < 4; i++)
  errors[i] = readl(p->ctl + 0x2c + i * 4);
 /* R105 packs bursts/beats/pixels/frames/failed/5-bit reader_error. */
 if (readl(p->ctl + 0x50) || readl(p->ctl + 0x54)) {
  fail(p, "reader bus counter");
  return;
 }
 if (!p->qualified) {
  if (good < 3) {
   if (time_after(jiffies, p->deadline)) {
    fail(p, "no three good frames before deadline");
    return;
   }
   goto again;
  }
  if (crc != p->crc) {
   fail(p, "initial full frame CRC");
   return;
  }
  p->qualified = true;
  memcpy(p->errors, errors, sizeof(errors));
  dev_info(p->dev, "R107_SCANOUT_BASELINE good=%u crc=%08x bad=%u underflow=%u marker=%u dropped=%u\n",
           good, crc, errors[0], errors[1], errors[2], errors[3]);
 } else {
  if (crc != p->crc || good == p->last_good ||
      memcmp(p->errors, errors, sizeof(errors))) {
   fail(p, "steady CRC/stalled good/error delta");
   return;
  }
  if (++p->stable == 8) {
   p->passed = true;
   dev_info(p->dev, "R107_SCANOUT_PASS samples=8 good=%u crc=%08x dma=%pad RUN=1 persistent=1; external screen and USB checks separate\n",
            good, crc, &p->handle);
  }
 }
 p->last_good = good;
again:
 schedule_delayed_work(&p->work, msecs_to_jiffies(p->passed ? 1000 : 100));
}

static int probe(struct platform_device *pdev)
{
 struct device *dev = &pdev->dev;
 struct scan_probe *p;
 struct resource *res;
 phys_addr_t physical;
 u32 *pixels, status;
 unsigned int x, y;
 int rc;
 if (dev_is_dma_coherent(dev))
  return dev_err_probe(dev, -EINVAL, "requires actual noncoherent DMA mapping\n");
 rc = dma_set_mask_and_coherent(dev, DMA_BIT_MASK(32));
 if (rc)
  return rc;
 res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
 if (!res || res->start != 0x04000000 || resource_size(res) < 0x60)
  return -EINVAL;
 p = kzalloc(sizeof(*p), GFP_KERNEL);
 if (!p)
  return -ENOMEM;
 p->dev = dev;
 p->ctl = devm_ioremap_resource(dev, res);
 if (IS_ERR(p->ctl)) {
  rc = PTR_ERR(p->ctl);
  goto free_state;
 }
 if (readl(p->ctl) != 0x52313033 || readl(p->ctl + 4) != 0x10001 ||
     readl(p->ctl + 0x14) != R107_FRAME_BYTES || readl(p->ctl + 0x5c) != 40000000) {
  rc = -ENODEV;
  goto free_state;
 }
 if (readl(p->ctl + REG_STATUS) & 0x17) {
  rc = -EBUSY;
  goto free_state;
 }
 p->frame = dma_alloc_coherent(dev, R107_FRAME_BYTES, &p->handle, GFP_KERNEL);
 if (!p->frame) {
  rc = -ENOMEM;
  goto free_state;
 }
 physical = dma_to_phys(dev, p->handle);
 if (p->handle < 0x07000000 || p->handle > 0x07800000 - R107_FRAME_BYTES ||
     physical != p->handle + 0x80000000ULL || physical < 0x87000000 ||
     physical > 0x87800000ULL - R107_FRAME_BYTES || (p->handle & 7)) {
  rc = -ERANGE;
  goto free_frame_before_run;
 }
 pixels = p->frame;
 for (y = 0; y < R107_HEIGHT; y++)
  for (x = 0; x < R107_WIDTH; x++)
   pixels[y * R107_WIDTH + x] = r107_pixel(x, y);
 p->crc = crc32_le(~0U, p->frame, R107_FRAME_BYTES) ^ ~0U;
 if (p->crc != 0xa0117b86U) {
  rc = -EILSEQ;
  goto free_frame_before_run;
 }
 dev_info(dev, "R107_SCANOUT_ALLOC bytes=%u order=%u cpu_phys=%pa dma=%pad crc=%08x\n",
          R107_FRAME_BYTES, get_order(R107_FRAME_BYTES), &physical, &p->handle, p->crc);
 INIT_DELAYED_WORK(&p->work, observe);
 platform_set_drvdata(pdev, p);
 dma_wmb();
 /* One atomic 64-bit transaction sets bus DMA BASE and RUN. No alias offset
  * subtraction here; dma-ranges already produced the device bus address. */
 writeq((1ULL << 32) | p->handle, p->ctl + 8);
 /* From this point every path retains the allocation, even readback failure. */
 rc = readl_poll_timeout(p->ctl + REG_STATUS, status, (status & 0x43) == 0x43,
                        100, 100000);
 if (rc || readl(p->ctl + 8) != (u32)p->handle) {
  fail(p, "BASE/RUN readback");
  return 0;
 }
 p->deadline = jiffies + msecs_to_jiffies(10000);
 schedule_delayed_work(&p->work, msecs_to_jiffies(100));
 return 0;
free_frame_before_run:
 dma_free_coherent(dev, R107_FRAME_BYTES, p->frame, p->handle);
free_state:
 kfree(p);
 return rc;
}

static const struct of_device_id matches[] = {
 { .compatible = "rv64lab,scanout-probe-v1" }, { }
};
static struct platform_driver scanout_driver = {
 .probe = probe,
 .driver = { .name = "rv64lab-scanout-probe", .of_match_table = matches,
             .suppress_bind_attrs = true },
};
builtin_platform_driver(scanout_driver);
MODULE_LICENSE("GPL");

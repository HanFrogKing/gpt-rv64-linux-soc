// SPDX-License-Identifier: GPL-2.0-only
/* Simulator-only PS source doorbell. Not a USB controller emulation. */
#include <linux/atomic.h>
#include <linux/delay.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/wait.h>

struct plic_test {
	void __iomem *doorbell;
	atomic_t count;
	unsigned int hold_until;
	wait_queue_head_t wait;
};
#define MUST(x) do { if (!(x)) panic("RV64LAB_PLIC_SELFTEST_FAIL line=%d: %s\n", __LINE__, #x); } while (0)
static irqreturn_t test_irq(int irq, void *data)
{
	struct plic_test *t = data;
	unsigned int n;
	MUST(readl(t->doorbell) == 2);
	n = atomic_inc_return(&t->count);
	if (n >= READ_ONCE(t->hold_until)) {
		writel(0, t->doorbell);
		MUST(readl(t->doorbell) == 0);
	}
	wake_up(&t->wait);
	return IRQ_HANDLED;
}
static int test_probe(struct platform_device *pdev)
{
	struct plic_test t = { };
	unsigned int n;
	int irq = platform_get_irq(pdev, 0);
	MUST(irq > 0);
	t.doorbell = ioremap(0xe0002ffc, 4);
	MUST(t.doorbell);
	init_waitqueue_head(&t.wait);
	atomic_set(&t.count, 0);
	writel(0, t.doorbell);
	MUST(!request_irq(irq, test_irq, 0, "rv64lab-plic-selftest", &t));
	for (n = 1; n <= 3; n++) {
		WRITE_ONCE(t.hold_until, n);
		writel(2, t.doorbell);
		MUST(wait_event_timeout(t.wait, atomic_read(&t.count) >= n, HZ));
		MUST(atomic_read(&t.count) == n && readl(t.doorbell) == 0);
	}
	/* First EOI must rearm the still-high gateway; second IRQ lowers it. */
	WRITE_ONCE(t.hold_until, 5);
	writel(2, t.doorbell);
	MUST(wait_event_timeout(t.wait, atomic_read(&t.count) >= 5, HZ));
	MUST(atomic_read(&t.count) == 5 && readl(t.doorbell) == 0);
	/* Linux disable/enable must mask notification without losing pending. */
	disable_irq(irq);
	WRITE_ONCE(t.hold_until, 6);
	writel(2, t.doorbell);
	msleep(20);
	MUST(atomic_read(&t.count) == 5);
	enable_irq(irq);
	MUST(wait_event_timeout(t.wait, atomic_read(&t.count) >= 6, HZ));
	MUST(atomic_read(&t.count) == 6 && readl(t.doorbell) == 0);
	free_irq(irq, &t);
	iounmap(t.doorbell);
	pr_info("RV64LAB_PLIC_SELFTEST_PASS irq_count=6 retrigger=2 masked_pending=1\n");
	return 0;
}
static const struct of_device_id test_match[] = {
	{ .compatible = "rv64lab,simulation-only-plic-selftest" }, { }
};
static struct platform_driver test_driver = {
	.probe = test_probe,
	.driver = { .name = "rv64lab-plic-selftest", .of_match_table = test_match },
};
module_platform_driver(test_driver);
MODULE_LICENSE("GPL");

// SPDX-License-Identifier: GPL-2.0-only
/* R108 staging DRM driver for the frozen R106 scanout ABI.
 * GEM SHMEM shadow planes -> CPU damage copy -> one persistent DMA allocation.
 * Built-in, explicit DT opt-in, no unbind/unload/PM/removal support. R103 STOP
 * is NOT drain. After first RUN every path retains the DMA allocation/binding
 * until coordinated whole-system reset. No true vblank or tear-free pageflip;
 * no_vblank explicitly requests DRM software completion events.
 * Based on Linux 6.6 simpledrm and simple-display-pipe/GEM shadow helpers.
 */
#include <linux/dma-direct.h>
#include <linux/dma-map-ops.h>
#include <linux/dma-mapping.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/module.h>
#include <linux/mm.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/workqueue.h>
#include <drm/drm_atomic_helper.h>
#include <drm/drm_damage_helper.h>
#include <drm/drm_drv.h>
#include <drm/drm_fbdev_generic.h>
#include <drm/drm_format_helper.h>
#include <drm/drm_fourcc.h>
#include <drm/drm_framebuffer.h>
#include <drm/drm_gem_atomic_helper.h>
#include <drm/drm_gem_framebuffer_helper.h>
#include <drm/drm_gem_shmem_helper.h>
#include <drm/drm_managed.h>
#include <drm/drm_modeset_helper.h>
#include <drm/drm_probe_helper.h>
#include <drm/drm_simple_kms_helper.h>

#define WIDTH 800
#define HEIGHT 600
#define PITCH (WIDTH * 4)
#define FRAME_BYTES (PITCH * HEIGHT)
#define REG_STATUS 0x10
#define REG_SEQUENCE 0x1c

struct lab_drm {
 struct drm_device drm;
 struct drm_simple_display_pipe pipe;
 struct drm_connector connector;
 struct mutex lock;
 void __iomem *ctl;
 void *frame;
 dma_addr_t handle;
 struct delayed_work observe;
 unsigned long deadline;
 u64 updates, copied_bytes;
 u32 last_good, last_crc, errors[4];
 bool qualified, failed, started;
};

static const struct drm_display_mode lab_mode = {
 DRM_MODE("800x600", DRM_MODE_TYPE_DRIVER, 40000, 800, 840, 968, 1056, 0,
          600, 601, 605, 628, 0, DRM_MODE_FLAG_PHSYNC | DRM_MODE_FLAG_PVSYNC),
};
static const u32 formats[] = { DRM_FORMAT_XRGB8888 };
static const u64 modifiers[] = { DRM_FORMAT_MOD_LINEAR, DRM_FORMAT_MOD_INVALID };

static struct lab_drm *to_lab(struct drm_device *dev)
{
 return container_of(dev, struct lab_drm, drm);
}

static enum drm_mode_status mode_valid(struct drm_simple_display_pipe *pipe,
                                      const struct drm_display_mode *mode)
{
 return drm_mode_match(mode, &lab_mode, DRM_MODE_MATCH_TIMINGS |
                       DRM_MODE_MATCH_CLOCK | DRM_MODE_MATCH_FLAGS) ? MODE_OK : MODE_BAD;
}

static int plane_check(struct drm_simple_display_pipe *pipe,
                       struct drm_plane_state *plane,
                       struct drm_crtc_state *crtc)
{
 struct lab_drm *p = to_lab(pipe->crtc.dev);
 struct drm_framebuffer *fb = plane->fb;
 /* Software completion only. Never report this as a physical vblank IRQ. */
 crtc->no_vblank = true;
 if (READ_ONCE(p->failed))
  return -EIO;
 if (!fb)
  return 0;
 if (fb->format->format != DRM_FORMAT_XRGB8888 ||
     fb->modifier != DRM_FORMAT_MOD_LINEAR || fb->width != WIDTH ||
     fb->height != HEIGHT || fb->pitches[0] < PITCH ||
     plane->src_x || plane->src_y || plane->src_w != (WIDTH << 16) ||
     plane->src_h != (HEIGHT << 16))
  return -EINVAL;
 return 0;
}

static void update(struct drm_simple_display_pipe *pipe,
                   struct drm_plane_state *old)
{
 struct drm_plane_state *state = pipe->plane.state;
 struct drm_shadow_plane_state *shadow = to_drm_shadow_plane_state(state);
 struct lab_drm *p = to_lab(pipe->crtc.dev);
 struct drm_framebuffer *fb = state->fb;
 struct drm_atomic_helper_damage_iter iter;
 struct drm_rect damage;
 const unsigned int pitch = PITCH;
 int rc;
 if (!fb || !state->visible || READ_ONCE(p->failed))
  return;
 rc = drm_gem_fb_begin_cpu_access(fb, DMA_FROM_DEVICE);
 if (rc) {
  WRITE_ONCE(p->failed, true);
  return;
 }
 mutex_lock(&p->lock);
 drm_atomic_helper_damage_iter_init(&iter, old, state);
 drm_atomic_for_each_plane_damage(&iter, &damage) {
  struct drm_rect screen = DRM_RECT_INIT(0, 0, WIDTH, HEIGHT);
  struct iosys_map dst = IOSYS_MAP_INIT_VADDR(p->frame);
  if (!drm_rect_intersect(&damage, &screen))
   continue;
  /* SHMEM mapping + helper data[] preserves GEM offsets and source pitch.
   * drm_fb_memcpy offsets only its source: advance destination explicitly. */
  iosys_map_incr(&dst, damage.y1 * PITCH + damage.x1 * 4);
  drm_fb_memcpy(&dst, &pitch, shadow->data, fb, &damage);
  p->copied_bytes += (u64)drm_rect_width(&damage) * drm_rect_height(&damage) * 4;
 }
 dma_wmb();
 p->updates++;
 mutex_unlock(&p->lock);
 drm_gem_fb_end_cpu_access(fb, DMA_FROM_DEVICE);
 /* No printk here: fbcon could re-enter a shadow update. */
}

static void disable(struct drm_simple_display_pipe *pipe)
{
 struct lab_drm *p = to_lab(pipe->crtc.dev);
 mutex_lock(&p->lock);
 memset(p->frame, 0, FRAME_BYTES);
 dma_wmb();
 mutex_unlock(&p->lock);
 /* Blank by copying black; do NOT stop/rebase/free an active DMA reader. */
}

static const struct drm_simple_display_pipe_funcs pipe_funcs = {
 .mode_valid = mode_valid, .check = plane_check, .update = update, .disable = disable,
 DRM_GEM_SIMPLE_DISPLAY_PIPE_SHADOW_PLANE_FUNCS,
};

static int get_modes(struct drm_connector *connector)
{
 struct drm_display_mode *mode = drm_mode_duplicate(connector->dev, &lab_mode);
 if (!mode)
  return -ENOMEM;
 mode->type |= DRM_MODE_TYPE_PREFERRED;
 drm_mode_probed_add(connector, mode);
 return 1;
}
static const struct drm_connector_helper_funcs connector_helpers = { .get_modes = get_modes };
static const struct drm_connector_funcs connector_funcs = {
 .fill_modes = drm_helper_probe_single_connector_modes,
 .destroy = drm_connector_cleanup, .reset = drm_atomic_helper_connector_reset,
 .atomic_duplicate_state = drm_atomic_helper_connector_duplicate_state,
 .atomic_destroy_state = drm_atomic_helper_connector_destroy_state,
};
static const struct drm_mode_config_funcs mode_funcs = {
 .fb_create = drm_gem_fb_create_with_dirty,
 .atomic_check = drm_atomic_helper_check, .atomic_commit = drm_atomic_helper_commit,
};
DEFINE_DRM_GEM_FOPS(lab_fops);
static const struct drm_driver lab_driver = {
 DRM_GEM_SHMEM_DRIVER_OPS,
 .name = "rv64lab", .desc = "Persistent RV64 fixed-DMA shadow scanout",
 .date = "20261026", .major = 1, .minor = 0,
 .driver_features = DRIVER_GEM | DRIVER_MODESET | DRIVER_ATOMIC,
 .fops = &lab_fops,
};

static ssize_t scanout_state_show(struct device *dev,
                                 struct device_attribute *attr, char *buf)
{
 struct lab_drm *p = dev_get_drvdata(dev);
 ssize_t n;
 mutex_lock(&p->lock);
 n = sysfs_emit(buf, "R108_STATE dma=%pad bytes=%u updates=%llu copied=%llu good=%u crc=%08x qualified=%u failed=%u errors=%u,%u,%u,%u hardware_vblank=0 hardware_pageflip=0 retained=%u\n",
                &p->handle, FRAME_BYTES, p->updates, p->copied_bytes,
                p->last_good, p->last_crc, p->qualified, p->failed,
                p->errors[0], p->errors[1], p->errors[2], p->errors[3], p->started);
 mutex_unlock(&p->lock);
 return n;
}
static DEVICE_ATTR_RO(scanout_state);
static struct attribute *lab_attrs[] = { &dev_attr_scanout_state.attr, NULL };
ATTRIBUTE_GROUPS(lab);

static void observe(struct work_struct *work)
{
 struct lab_drm *p = container_of(to_delayed_work(work), struct lab_drm, observe);
 u32 seq, status, good, errors[4];
 unsigned int i;
 bool first = false, fail = false;
 int rc;
 if (READ_ONCE(p->failed))
  return;
 mutex_lock(&p->lock);
 seq = readl(p->ctl + REG_SEQUENCE);
 if (readl(p->ctl + REG_STATUS) & BIT(4)) {
  fail = true;
  goto out;
 }
 writel(1, p->ctl + 0x18);
 rc = readl_poll_timeout(p->ctl + REG_STATUS, status,
                        !(status & BIT(4)) && readl(p->ctl + REG_SEQUENCE) != seq,
                        100, 100000);
 if (rc || readl(p->ctl + REG_SEQUENCE) != seq + 1 || (status & 0x63) != 0x63 ||
     readl(p->ctl + 0x50) || readl(p->ctl + 0x54)) {
  fail = true;
  goto out;
 }
 good = readl(p->ctl + 0x28);
 p->last_crc = readl(p->ctl + 0x20);
 for (i = 0; i < 4; i++)
  errors[i] = readl(p->ctl + 0x2c + i * 4);
 if (!p->qualified) {
  if (good >= 3) {
   memcpy(p->errors, errors, sizeof(errors));
   p->qualified = true;
   first = true;
  } else if (time_after(jiffies, p->deadline)) {
   fail = true;
  }
 } else if (good == p->last_good || memcmp(p->errors, errors, sizeof(errors))) {
  fail = true;
 }
 p->last_good = good;
out:
 if (fail)
  WRITE_ONCE(p->failed, true);
 mutex_unlock(&p->lock);
 if (fail) {
  dev_err(p->drm.dev, "R108_DRM_SCANOUT_FAIL; RUN/buffer retained until common reset\n");
  return;
 }
 if (first)
  dev_info(p->drm.dev, "R108_DRM_SCANOUT_READY dma=%pad persistent=1; software-copy commits, no hardware VBlank\n", &p->handle);
 schedule_delayed_work(&p->observe, msecs_to_jiffies(1000));
}

static int probe(struct platform_device *pdev)
{
 struct device *dev = &pdev->dev;
 struct resource *res;
 struct lab_drm *p;
 phys_addr_t physical;
 u32 status;
 int rc;
 if (dev_is_dma_coherent(dev))
  return -EINVAL;
 rc = dma_set_mask_and_coherent(dev, DMA_BIT_MASK(32));
 if (rc)
  return rc;
 res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
 if (!res || res->start != 0x04000000 || resource_size(res) != 0x60)
  return -EINVAL;
 p = devm_drm_dev_alloc(dev, &lab_driver, struct lab_drm, drm);
 if (IS_ERR(p))
  return PTR_ERR(p);
 p->ctl = devm_ioremap_resource(dev, res);
 if (IS_ERR(p->ctl))
  return PTR_ERR(p->ctl);
 if (readl(p->ctl) != 0x52313033 || readl(p->ctl + 4) != 0x10001 ||
     readl(p->ctl + 0x14) != FRAME_BYTES || readl(p->ctl + 0x5c) != 40000000 ||
     (readl(p->ctl + REG_STATUS) & 0x17))
  return -ENODEV;
 mutex_init(&p->lock);
 platform_set_drvdata(pdev, p);
 rc = drmm_mode_config_init(&p->drm);
 if (rc)
  return rc;
 p->drm.mode_config.min_width = p->drm.mode_config.max_width = WIDTH;
 p->drm.mode_config.min_height = p->drm.mode_config.max_height = HEIGHT;
 p->drm.mode_config.preferred_depth = 24;
 p->drm.mode_config.funcs = &mode_funcs;
 rc = drm_connector_init(&p->drm, &p->connector, &connector_funcs, DRM_MODE_CONNECTOR_HDMIA);
 if (rc)
  return rc;
 drm_connector_helper_add(&p->connector, &connector_helpers);
 rc = drm_simple_display_pipe_init(&p->drm, &p->pipe, &pipe_funcs, formats,
                                   ARRAY_SIZE(formats), modifiers, &p->connector);
 if (rc)
  return rc;
 drm_plane_enable_fb_damage_clips(&p->pipe.plane);
 drm_mode_config_reset(&p->drm);
 p->frame = dma_alloc_coherent(dev, FRAME_BYTES, &p->handle, GFP_KERNEL);
 if (!p->frame)
  return -ENOMEM;
 physical = dma_to_phys(dev, p->handle);
 if (p->handle < 0x07000000 || p->handle > 0x07800000 - FRAME_BYTES ||
     physical != p->handle + 0x80000000ULL || (p->handle & 7)) {
  rc = -ERANGE;
  goto free_before_run;
 }
 memset(p->frame, 0, FRAME_BYTES);
 INIT_DELAYED_WORK(&p->observe, observe);
 rc = drm_dev_register(&p->drm, 0);
 if (rc)
  goto free_before_run;
 dev_info(dev, "R108_DRM_ALLOC bytes=%u order=%u cpu_phys=%pa dma=%pad shadow=shmem format=XR24\n",
          FRAME_BYTES, get_order(FRAME_BYTES), &physical, &p->handle);
 dma_wmb();
 p->started = true;
 writeq((1ULL << 32) | p->handle, p->ctl + 8);
 /* NO failure return or allocation release after this point. */
 rc = readl_poll_timeout(p->ctl + REG_STATUS, status, (status & 0x43) == 0x43, 100, 100000);
 if (rc || readl(p->ctl + 8) != (u32)p->handle) {
  WRITE_ONCE(p->failed, true);
  dev_err(dev, "R108_DRM_SCANOUT_FAIL BASE/RUN readback; allocation retained\n");
  return 0;
 }
 p->deadline = jiffies + msecs_to_jiffies(10000);
 schedule_delayed_work(&p->observe, msecs_to_jiffies(100));
 drm_fbdev_generic_setup(&p->drm, 32);
 return 0;
free_before_run:
 dma_free_coherent(dev, FRAME_BYTES, p->frame, p->handle);
 return rc;
}

static const struct of_device_id matches[] = {
 { .compatible = "rv64lab,scanout-drm-shadow-v1" }, { }
};
static struct platform_driver lab_platform_driver = {
 .probe = probe,
 .driver = { .name = "rv64lab-drm-shadow", .of_match_table = matches,
             .suppress_bind_attrs = true, .dev_groups = lab_groups },
};
builtin_platform_driver(lab_platform_driver);
MODULE_LICENSE("GPL");

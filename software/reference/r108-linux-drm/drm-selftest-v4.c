/* SPDX-License-Identifier: GPL-2.0-only
 * Real target DRM ioctls, not libdrm emulation. No disk or /dev/mem access.
 * Software pageflip events explicitly do not prove hardware VBlank.
 */
#define _GNU_SOURCE
#include <drm/drm.h>
#include <drm/drm_mode.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include "../r107-linux-scanout/pattern.h"

#define XR24 0x34325258U
#define AR24 0x34325241U
struct buffer {
 struct drm_mode_create_dumb dumb;
 uint32_t fb, offset;
 unsigned char *map;
};
static void require(int ok, const char *why)
{
 if (!ok) {
  fprintf(stderr, "R108_DRM_SELFTEST_FAIL %s errno=%d\n", why, errno);
  exit(1);
 }
}
static uint64_t ptr(const void *p) { return (uint64_t)(uintptr_t)p; }
static void pause_scan(void)
{
 struct timespec t = { 0, 500000000 };
 while (nanosleep(&t, &t) && errno == EINTR) {}
}
static void marker(const char *s)
{
 puts(s);fflush(stdout);
}
static void create(int fd, struct buffer *b, int padded, uint32_t format)
{
 struct drm_mode_map_dumb m = { 0 };
 struct drm_mode_fb_cmd2 f = { 0 };
 b->dumb.width = padded ? 808 : 800;
 b->dumb.height = padded ? 601 : 600;
 b->dumb.bpp = 32;
 require(ioctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &b->dumb) == 0, "create-dumb");
 require(b->dumb.pitch >= b->dumb.width * 4 && b->dumb.size >= (uint64_t)b->dumb.pitch * b->dumb.height, "dumb-size-pitch");
 m.handle = b->dumb.handle;
 require(ioctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &m) == 0, "map-dumb-offset");
 b->map = mmap(NULL, b->dumb.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, m.offset);
 require(b->map != MAP_FAILED, "mmap-dumb");
 memset(b->map, 0xa5, b->dumb.size);
 b->offset = padded ? 128 : 0;
 f.width = 800;f.height = 600;f.pixel_format = format;
 f.handles[0] = b->dumb.handle;f.pitches[0] = b->dumb.pitch;f.offsets[0] = b->offset;
 require(ioctl(fd, DRM_IOCTL_MODE_ADDFB2, &f) == 0, "addfb2");
 b->fb = f.fb_id;
}
static void paint(struct buffer *b, unsigned int phase)
{
 unsigned int x, y;
 for (y = 0; y < 600; y++) {
  uint32_t *row = (uint32_t *)(b->map + b->offset + y * b->dumb.pitch);
  for (x = 0; x < 800; x++)
   row[x] = r107_pixel(x, y) ^ (phase ? 0x00ffffffU : 0U);
 }
}
static void set_mode(int fd, uint32_t crtc, uint32_t connector, uint32_t fb,
                     const struct drm_mode_modeinfo *mode)
{
 struct drm_mode_crtc s = { 0 };
 s.crtc_id = crtc;s.fb_id = fb;s.mode = *mode;s.mode_valid = 1;
 s.set_connectors_ptr = ptr(&connector);s.count_connectors = 1;
 require(ioctl(fd, DRM_IOCTL_MODE_SETCRTC, &s) == 0, "setcrtc");
}
static void reject_mode(int fd, uint32_t crtc, uint32_t connector, uint32_t fb,
                        const struct drm_mode_modeinfo *mode, unsigned int x,
                        const char *name, int expected_errno)
{
 struct drm_mode_crtc s = { 0 };
 s.crtc_id = crtc;s.fb_id = fb;s.mode = *mode;s.mode_valid = 1;s.x = x;
 s.set_connectors_ptr = ptr(&connector);s.count_connectors = 1;
 printf("R108_DRM_MODE_REJECT_BEGIN case=%s expected_errno=%d\n", name, expected_errno);fflush(stdout);
 errno = 0;
 int result = ioctl(fd, DRM_IOCTL_MODE_SETCRTC, &s);
 int actual_errno = errno;
 if (result != -1 || actual_errno != expected_errno) {
  fprintf(stderr, "R108_DRM_SELFTEST_FAIL mode-reject case=%s result=%d errno=%d expected_errno=%d\n", name, result, actual_errno, expected_errno);
  exit(1);
 }
 printf("R108_DRM_MODE_REJECT_PASS case=%s ioctl=SETCRTC errno=%d\n", name, actual_errno);fflush(stdout);
}
/* The atomic GEM helper rejects an unsupported format at ADDFB2,
 * before it can become a framebuffer for SETCRTC. Exercise that real API
 * boundary with an otherwise valid, already allocated XRGB dumb object. */
static void reject_format(int fd, const struct buffer *b)
{
 struct drm_mode_fb_cmd2 f = { 0 };
 f.width = 800;f.height = 600;f.pixel_format = AR24;
 f.handles[0] = b->dumb.handle;f.pitches[0] = b->dumb.pitch;
 errno = 0;
 require(ioctl(fd, DRM_IOCTL_MODE_ADDFB2, &f) == -1 && errno == EINVAL,
         "invalid-format-addfb2-must-reject");
 marker("R108_DRM_FORMAT_REJECT_PASS ioctl=ADDFB2 errno=22");
}
static void destroy(int fd, struct buffer *b)
{
 struct drm_mode_destroy_dumb d = { .handle = b->dumb.handle };
 require(ioctl(fd, DRM_IOCTL_MODE_RMFB, &b->fb) == 0, "rmfb");
 require(munmap(b->map, b->dumb.size) == 0, "munmap");
 require(ioctl(fd, DRM_IOCTL_MODE_DESTROY_DUMB, &d) == 0, "destroy-dumb");
}

int main(void)
{
 struct drm_version version = { 0 };
 char name[64] = { 0 };
 struct drm_get_cap cap = { .capability = DRM_CAP_DUMB_BUFFER };
 struct drm_set_client_cap atomic = { .capability = DRM_CLIENT_CAP_ATOMIC, .value = 1 };
 struct drm_mode_card_res resources = { 0 };
 struct drm_mode_get_connector con = { 0 };
 struct drm_mode_modeinfo modes[4] = { { 0 } }, invalid;
 struct drm_mode_crtc saved = { 0 };
 uint32_t crtc[4] = { 0 }, connectors[4] = { 0 }, encoders[4] = { 0 };
 struct buffer a = { 0 }, b = { 0 };
 struct drm_mode_fb_dirty_cmd dirty = { 0 };
 struct drm_clip_rect clip = { .x1 = 37, .y1 = 51, .x2 = 46, .y2 = 58 };
 struct drm_mode_crtc_page_flip flip = { 0 };
 struct pollfd pollfd;
 struct drm_event_vblank event;
 unsigned int x, y;
 int fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
 require(fd >= 0, "open-card0");
 version.name_len = sizeof(name)-1;version.name = name;
 require(ioctl(fd, DRM_IOCTL_VERSION, &version) == 0 && !strcmp(name, "rv64lab"), "driver-name");
 require(ioctl(fd, DRM_IOCTL_GET_CAP, &cap) == 0 && cap.value == 1, "dumb-capability");
 require(ioctl(fd, DRM_IOCTL_SET_CLIENT_CAP, &atomic) == 0, "atomic-capability");
 require(ioctl(fd, DRM_IOCTL_SET_MASTER, 0) == 0, "set-master");
 require(ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &resources) == 0, "get-resources-counts");
 require(resources.count_crtcs == 1 && resources.count_connectors == 1 && resources.count_encoders == 1, "single-pipeline");
 resources.crtc_id_ptr = ptr(crtc);resources.connector_id_ptr = ptr(connectors);resources.encoder_id_ptr = ptr(encoders);
 /* Count-only queries return sizes even for omitted arrays. Do not ask the
  * second ioctl to copy framebuffer/property arrays to null pointers. */
 resources.count_fbs = 0;
 require(ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &resources) == 0 && crtc[0] && connectors[0], "get-resources-ids");
 con.connector_id = connectors[0];
 require(ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &con) == 0 && con.count_modes == 1 && con.count_encoders == 1, "get-connector-counts");
 con.modes_ptr = ptr(modes);con.encoders_ptr = ptr(encoders);con.count_props = 0;
 require(ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &con) == 0 && con.count_modes == 1, "get-fixed-mode");
 require(modes[0].clock == 40000 && modes[0].hdisplay == 800 && modes[0].hsync_start == 840 && modes[0].hsync_end == 968 && modes[0].htotal == 1056 && modes[0].vdisplay == 600 && modes[0].vsync_start == 601 && modes[0].vsync_end == 605 && modes[0].vtotal == 628 && (modes[0].flags & (DRM_MODE_FLAG_PHSYNC | DRM_MODE_FLAG_PVSYNC)) == (DRM_MODE_FLAG_PHSYNC | DRM_MODE_FLAG_PVSYNC), "mode-timings");
 saved.crtc_id = crtc[0];
 require(ioctl(fd, DRM_IOCTL_MODE_GETCRTC, &saved) == 0 && saved.mode_valid && saved.fb_id, "fbcon-initial-mode");
 create(fd, &a, 0, XR24);marker("R108_DRM_BUFFER_READY A");
 create(fd, &b, 1, XR24);marker("R108_DRM_BUFFER_READY B");
 marker("R108_DRM_WRITE_A");paint(&a, 0);set_mode(fd, crtc[0], connectors[0], a.fb, &modes[0]);
 marker("R108_DRM_PHASE_A_COMMITTED");pause_scan();
 invalid = modes[0];invalid.clock++;
 reject_mode(fd, crtc[0], connectors[0], a.fb, &invalid, 0, "clock", EINVAL);
 invalid = modes[0];invalid.flags ^= DRM_MODE_FLAG_PHSYNC | DRM_MODE_FLAG_NHSYNC;
 reject_mode(fd, crtc[0], connectors[0], a.fb, &invalid, 0, "polarity", EINVAL);
 invalid = modes[0];invalid.vdisplay--;
 reject_mode(fd, crtc[0], connectors[0], a.fb, &invalid, 0, "size", EINVAL);
 reject_mode(fd, crtc[0], connectors[0], a.fb, &modes[0], 1, "origin", ENOSPC);
 reject_format(fd, &a);
 marker("R108_DRM_NEGATIVES_PASS clock,polarity,size,origin,format");
 marker("R108_DRM_WRITE_B");paint(&b, 1);set_mode(fd, crtc[0], connectors[0], b.fb, &modes[0]);
 marker("R108_DRM_PHASE_B_COMMITTED pitch-padding=1 offset=128");pause_scan();
 marker("R108_DRM_WRITE_C");
 for (y = clip.y1; y < clip.y2; y++) {
  uint32_t *row = (uint32_t *)(b.map + b.offset + y * b.dumb.pitch);
  for (x = clip.x1; x < clip.x2; x++)row[x] = 0x5a24d9afU;
 }
 dirty.fb_id = b.fb;dirty.num_clips = 1;dirty.clips_ptr = ptr(&clip);
 require(ioctl(fd, DRM_IOCTL_MODE_DIRTYFB, &dirty) == 0, "dirtyfb-partial-damage");
 marker("R108_DRM_PHASE_C_COMMITTED clip=37,51,46,58");pause_scan();
 marker("R108_DRM_WRITE_A_SOFTWARE_EVENT");
 flip.crtc_id = crtc[0];flip.fb_id = a.fb;flip.flags = DRM_MODE_PAGE_FLIP_EVENT;flip.user_data = 0x108a;
 require(ioctl(fd, DRM_IOCTL_MODE_PAGE_FLIP, &flip) == 0, "software-pageflip-submit");
 pollfd.fd = fd;pollfd.events = POLLIN;pollfd.revents = 0;
 require(poll(&pollfd, 1, 5000) == 1 && (pollfd.revents & POLLIN), "software-pageflip-event-poll");
 require(read(fd, &event, sizeof(event)) == (ssize_t)sizeof(event) && event.base.type == DRM_EVENT_FLIP_COMPLETE && event.base.length == sizeof(event) && event.user_data == 0x108a, "software-pageflip-event-data");
 marker("R108_DRM_PHASE_A_EVENT_COMMITTED hardware_vblank=0");pause_scan();
 marker("R108_DRM_RESTORE_FBCON");set_mode(fd, crtc[0], connectors[0], saved.fb_id, &saved.mode);
 destroy(fd, &a);destroy(fd, &b);
 require(close(fd) == 0, "close-card0");
 fd = open("/dev/tty1", O_WRONLY | O_NOCTTY);
 require(fd >= 0, "open-fbcon-tty1");
 { const char text[] = "\033[2J\033[HSelf-designed RV64 Linux DRM/KMS 800x600\nRV64_LINUX_DRM_CONSOLE_READY\n";
   require(write(fd, text, sizeof(text)-1) == (ssize_t)sizeof(text)-1, "write-fbcon-tty1"); }
 close(fd);pause_scan();
 marker("R108_DRM_SELFTEST_PASS modeset=1 padded_pitch=1 gem_offset=1 damage=1 rejects=5 software_event=1 console_write=1 hardware_vblank=0");
 return 0;
}

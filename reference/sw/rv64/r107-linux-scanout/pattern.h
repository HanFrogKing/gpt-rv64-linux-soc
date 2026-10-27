/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef RV64LAB_R107_PATTERN_H
#define RV64LAB_R107_PATTERN_H
#define R107_WIDTH 800u
#define R107_HEIGHT 600u
#define R107_FRAME_BYTES (R107_WIDTH * R107_HEIGHT * 4u)
/* XRGB8888, little endian. The padding byte also participates in CRC. */
static inline unsigned int r107_pixel(unsigned int x, unsigned int y)
{
 static const unsigned int bars[8] = {0xe0e0e0,0xe0e000,0x00e0e0,0x00e000,
                                     0xd000d0,0xe00000,0x0000e0,0x101010};
 unsigned int rgb;
 if (x < 4 || x >= 796 || y < 4 || y >= 596)
  rgb = 0xffffff;
 else if (y < 300)
  rgb = bars[x / 100] ^ ((x & 1) ? 0x010101 : 0);
 else
  rgb = (((x / 32) ^ (y / 32)) & 1) ? 0x3040e0 : 0xe04030;
 return 0x5a000000 | rgb;
}
#endif

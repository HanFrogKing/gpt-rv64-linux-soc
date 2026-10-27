/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef _ASM_RV64LAB_DMA_H
#define _ASM_RV64LAB_DMA_H
#ifdef CONFIG_RV64LAB_DMA
void rv64lab_dma_early_init(void);
#else
static inline void rv64lab_dma_early_init(void) {}
#endif
#endif

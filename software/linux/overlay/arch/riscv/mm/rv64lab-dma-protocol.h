/* SPDX-License-Identifier: GPL-2.0-only */
/* R85 register protocol shared by Linux and the real-CPU firmware test.
 * Caller supplies u64/u32, errno constants and serialized, ordered IO.
 * Timeout bounds returned reads; it cannot recover an AXI read that never returns.
 */
#ifndef RV64LAB_DMA_PROTOCOL_H
#define RV64LAB_DMA_PROTOCOL_H
#define RV64LAB_DMA_LINE 32UL
#define RV64LAB_DMA_ID 0x5238350000200001ULL
#define RV64LAB_DMA_POLLS 4096U
struct rv64lab_dma_io {
	u64 (*read)(void *ctx, unsigned int offset);
	void (*write)(void *ctx, unsigned int offset, u64 value);
	void *ctx;
};

static inline int rv64lab_dma_line(const struct rv64lab_dma_io *io,
		u64 address, unsigned int op, u64 *last_status)
{
	u64 status = io->read(io->ctx, 16);
	u32 count = (u32)(status >> 32);
	unsigned int n;
	*last_status = status;
	if (op > 2)
		return -EINVAL;
	if (status & 8)
		return -EIO;
	if (status & 1)
		return -EBUSY;
	/* A stale DONE or error from the previous owner is not our completion. */
	io->write(io->ctx, 8, 4);
	status = io->read(io->ctx, 16);
	*last_status = status;
	if ((status & 15) || (u32)(status >> 32) != count)
		return -EPROTO;
	io->write(io->ctx, 0, address);
	io->write(io->ctx, 8, op);
	for (n = 0; n < RV64LAB_DMA_POLLS; n++) {
		status = io->read(io->ctx, 16);
		*last_status = status;
		if (status & 8)
			return -EIO;
		if (status & 1)
			continue;
		if (status & 2) {
			if ((u32)(status >> 32) != (u32)(count + 1) ||
			    io->read(io->ctx, 24) != address)
				return -EPROTO;
			return status & 0x34 ? -EIO : 0;
		}
	}
	return -ETIMEDOUT;
}

/* Inclusive aligned first/last line, avoiding wrap at either end. */
static inline int rv64lab_dma_range(u64 address, u64 bytes, u64 *first, u64 *last)
{
	if (!bytes)
		return 1;
	if (address < 0x80200000ULL || address >= 0x88000000ULL ||
	    bytes > 0x88000000ULL - address)
		return -EINVAL;
	*first = address & ~(u64)(RV64LAB_DMA_LINE - 1);
	*last = (address + bytes - 1) & ~(u64)(RV64LAB_DMA_LINE - 1);
	return 0;
}
#endif

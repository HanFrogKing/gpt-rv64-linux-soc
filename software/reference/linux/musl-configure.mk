# Adapter only for running upstream configure in an out-of-tree build directory.
.PHONY: configure
configure:
	$(SOURCE)/configure --target=riscv64-linux-musl --prefix=$(PREFIX) --disable-shared --enable-wrapper=gcc CC=$(CROSS)gcc CROSS_COMPILE=$(CROSS) CFLAGS="$(TARGET_CFLAGS)"

# SPDX-License-Identifier: BSD-2-Clause

# slotwatch.mk -- the single-slot writer watch: who stored what, at which
# instruction, without stopping the guest (README.rst: what it proves, what it
# cannot).  Same shape as rules/guard.mk: built here, exercised by the
# consumer's run script, because the kernel under test is not a guest of this
# tree.

SLOTWATCH_CFLAGS := $(shell pkg-config --cflags glib-2.0)
SLOTWATCH_LIBS := $(shell pkg-config --libs glib-2.0)

plugins/slotwatch.so: plugins/slotwatch.c $(BUILD_DEPS)
	$(CC) -O2 -g -Wall -fvisibility=hidden -shared -fPIC \
	    -I../include/qemu $(SLOTWATCH_CFLAGS) \
	    -o $@ $< $(SLOTWATCH_LIBS) -lpthread

slotwatch: plugins/slotwatch.so

slotwatch-smoke: plugins/slotwatch.so
	QEMU=$(QEMU) PLUGIN=plugins/slotwatch.so $(SHELL) tests/slotwatch-smoke.sh

EXTRA_BUILT += plugins/slotwatch.so
RUNTARGETS += slotwatch slotwatch-smoke

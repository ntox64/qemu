# SPDX-License-Identifier: BSD-2-Clause

# guard.mk -- the hbguard TCG plugin: a guarded field set vs the lock that
# is supposed to guard it (README.rst: what it proves, what it cannot).
#
# This is the only non-guest artifact in this tree: a plugin is loaded with
# `-plugin file=plugins/hbguard.so,<options>` into our own qemu, so it is
# built here but exercised by the consumer's run script (the kernel under
# test is not a guest of this tree).

HBGUARD_CFLAGS := $(shell pkg-config --cflags glib-2.0)
HBGUARD_LIBS := $(shell pkg-config --libs glib-2.0)

plugins/hbguard.so: plugins/hbguard.c $(BUILD_DEPS)
	$(CC) -O2 -g -Wall -fvisibility=hidden -shared -fPIC \
	    -I../include/qemu $(HBGUARD_CFLAGS) \
	    -o $@ $< $(HBGUARD_LIBS) -lpthread

guard: plugins/hbguard.so

EXTRA_BUILT += plugins/hbguard.so
RUNTARGETS += guard

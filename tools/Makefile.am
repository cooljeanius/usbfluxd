AM_CFLAGS = $(GLOBAL_CFLAGS) $(libplist_CFLAGS)
AM_LDFLAGS = $(libplist_LIBS) $(libpthread_LIBS)

bin_PROGRAMS = usbfluxctl

usbfluxctl_SOURCES = usbfluxctl.c
usbfluxctl_CFLAGS = $(AM_CFLAGS)
usbfluxctl_LDFLAGS = $(AM_LDFLAGS)

distclean-local:
	-rm -rfv *.dSYM || rmdir *.dSYM
	-rm -rfv .deps || rmdir .deps

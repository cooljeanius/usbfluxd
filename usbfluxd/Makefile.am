AM_CPPFLAGS = -I$(top_srcdir)/include -I$(top_srcdir)

AM_CFLAGS = $(GLOBAL_CFLAGS) $(libplist_CFLAGS) $(avahi_client_CFLAGS)
AM_LDFLAGS = $(libplist_LIBS) $(libpthread_LIBS) $(avahi_client_LIBS) $(AC_LDADD)

sbin_PROGRAMS = usbfluxd

usbfluxd_CFLAGS = $(AM_CFLAGS)
usbfluxd_LDFLAGS = $(AM_LDFLAGS) -no-undefined
usbfluxd_SOURCES = client.c client.h \
		usbmuxd-proto.h \
		socket.c socket.h \
		usbmux_remote.c usbmux_remote.h \
		log.c log.h \
		utils.c utils.h \
		main.c

distclean-local:
	-rm -rfv .deps || rmdir .deps

check-local: $(sbin_PROGRAMS)
	if test -x usbfluxd; then echo "ok"; fi

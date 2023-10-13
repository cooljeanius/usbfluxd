AUTOMAKE_OPTIONS = foreign
ACLOCAL_AMFLAGS = -I m4 --install
SUBDIRS = usbfluxd tools

EXTRA_DIST = COPYING.GPLv2 COPYING.GPLv3

DISTCLEANFILES = *~ m4/*~ autoscan*.log

check-local:
	if test "x$(SHELLCHECK)" != "x"; then \
	  test -x "$(SHELLCHECK)" && echo "using $(SHELLCHECK)"; \
	  for myscript in autogen.sh build-gui.sh makedmg.sh; do \
	    if test -e $${myscript}; then \
	      echo "$(SHELLCHECK) $${myscript}" && $(SHELLCHECK) $${myscript}; \
	    elif test -e $(srcdir)/$${myscript}; then \
	      echo "check $(srcdir)" && $(SHELLCHECK) $(srcdir)/$${myscript}; \
	    elif test -e $(builddir)/$${myscript}; then \
	      echo "check $(builddir)" && $(SHELLCHECK) $(builddir)/$${myscript}; \
	    fi; \
	  done; \
	else \
	  test -z "$(SHELLCHECK)" && echo "shellcheck required to lint shell scripts!"; \
	fi

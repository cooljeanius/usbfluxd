AUTOMAKE_OPTIONS = foreign
ACLOCAL_AMFLAGS = -I m4 --install
SUBDIRS = usbfluxd tools

EXTRA_DIST = COPYING.GPLv2 COPYING.GPLv3

DISTCLEANFILES = *~ m4/*~ autoscan*.log

check-local:
	if test "x$(SHELLCHECK)" != "x"; then \
	  test -x "$(SHELLCHECK)" && echo "using $(SHELLCHECK)"; \
	  if test -e build-gui.sh; then \
	    echo "$(SHELLCHECK) build-gui.sh" && $(SHELLCHECK) build-gui.sh; \
	  elif test -e $(srcdir)/build-gui.sh; then \
	    echo "shellcheck $(srcdir)" && $(SHELLCHECK) $(srcdir)/build-gui.sh; \
	  elif test -e $(builddir)/build-gui.sh; then \
	    echo "check $(builddir)" && $(SHELLCHECK) $(builddir)/build-gui.sh; \
	  fi; \
	  if test -e makedmg.sh; then \
	    echo "$(SHELLCHECK) makedmg.sh" && $(SHELLCHECK) makedmg.sh; \
	  elif test -e $(srcdir)/makedmg.sh; then \
	    echo "shellcheck $(srcdir)" && $(SHELLCHECK) $(srcdir)/makedmg.sh; \
	  elif test -e $(builddir)/makedmg.sh; then \
	    echo "check $(builddir)" && $(SHELLCHECK) $(builddir)/makedmg.sh; \
	  fi; \
	else \
	  test -z "$(SHELLCHECK)" && echo "shellcheck required to lint shell scripts!"; \
	fi

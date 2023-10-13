#!/bin/sh

echo "You could also just run autoreconf instead of this script, but whatever"

# shellcheck disable=SC2181

gprefix=$(which glibtoolize 2>&1 >/dev/null)
if [ $? -eq 0 ]; then
  echo "Running glibtoolize"
  glibtoolize --force --install --copy --automake
else
  echo "Running libtoolize"
  libtoolize --force --install --copy --automake
fi
echo "Running aclocal"
aclocal -I m4 --install
echo "Running autoheader"
autoheader --force -Wall
echo "Running automake" 
automake --add-missing --force-missing --copy -Wall
echo "Running autoconf"
autoconf --force -Wall
requires_pkgconfig=$(which pkg-config 2>&1 >/dev/null)
if [ $? -ne 0 ]; then
  echo "Missing required pkg-config. Please install it on your system and run again."
fi

if test -n "${gprefix}"; then export gprefix; fi
if test -n "{requires_pkgconfig}"; then export requires_pkgconfig; fi

if [ -z "${NOCONFIGURE}" ]; then
    echo "Running generated configure script..."
    ./configure "$@"
else
    echo "NOCONFIGURE set; skipping running configure script (from autogen.sh, at least)"
fi

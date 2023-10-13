dnl#                                               -*- Autoconf -*-
dnl# Process this file with autoconf to produce a configure script.

AC_PREREQ([2.64])
AC_INIT([usbfluxd],[1.2.0],[https://corellium.com],[],[https://corellium.com])
AM_INIT_AUTOMAKE([dist-bzip2 no-dist-gzip check-news])
m4_ifdef([AM_SILENT_RULES],[AM_SILENT_RULES])
AC_CONFIG_SRCDIR([usbfluxd/])
AC_CONFIG_HEADERS([config.h])
AC_CONFIG_MACRO_DIR([m4])dnl

# Checks for programs.
AC_PROG_CC
AC_PROG_CPP
AC_PROG_CXX
AM_PROG_CC_C_O
AC_PROG_OBJC
LT_INIT([win32-dll])
LT_LANG([C])
AC_DEFUN([AC_REQUIRE_PROGS],[
  AC_REQUIRE([AC_PROG_INSTALL])dnl
  AC_REQUIRE([AC_PROG_LN_S])dnl
  AC_REQUIRE([AC_PROG_MAKE_SET])dnl
  AC_REQUIRE([AC_PROG_RANLIB])dnl
  AC_REQUIRE([AC_PROG_SED])dnl
  AC_REQUIRE([AC_PROG_EGREP])dnl
])dnl
AC_REQUIRE_PROGS

# Checks for libraries.
PKG_CHECK_MODULES([libplist],[libplist >= 2.2.0],
  [
    AC_DEFINE([HAVE_LIBPLIST],[1],[Use libplist])
    LIBPLIST=libplist
  ],[
    PKG_CHECK_MODULES([libplist],[libplist-2.0 >= 2.2.0],[
    LIBPLIST=libplist-2.0
    AC_DEFINE([HAVE_LIBPLIST_2_0],[1],[Use libplist-2.0])
  ])],
[])dnl

if test "x${LIBPLIST}" != "x"; then
  CFLAGS_save="${CFLAGS}"
  CFLAGS="${CFLAGS} ${libplist_CFLAGS}"
  AC_CHECK_DECLS([plist_format_typedef],[],[],[
    #include <plist/plist.h>
    plist_format_t plist_format_typedef;
  ])
  CFLAGS="${CFLAGS_save}"
fi
AC_CHECK_LIB([pthread],[pthread_create, pthread_mutex_lock],
             [AC_SUBST([libpthread_LIBS],[-lpthread])],
             [AC_MSG_ERROR([libpthread is required to build usbfluxd])])dnl

AC_SEARCH_LIBS([fmin],[m])dnl

# Checks for header files.
AC_DEFUN([AC_REQUIRE_HEADER_STDC],[
  AC_REQUIRE([AC_HEADER_STDC])dnl
  AC_REQUIRE([AC_CHECK_INCLUDES_DEFAULT])dnl
])dnl
AC_REQUIRE_HEADER_STDC
AC_HEADER_STDBOOL dnl# also "_CHECK"s it
AC_HEADER_TIME
AC_CHECK_HEADERS([CFNetwork/CFNetServices.h])
AC_CHECK_HEADERS([arpa/inet.h fcntl.h mach/mach_time.h netdb.h netinet/in.h \
                  sys/statvfs.h sys/time.h syslog.h])dnl

if test "x${ac_cv_header_stdint_h}" = "x"; then
  test -z "${ac_cv_header_stdint_h}"
  AC_CHECK_HEADERS([stdint.h])
fi
if test "x${ac_cv_header_unistd_h}" = "x"; then
  test -z "${ac_cv_header_unistd_h}"
  AC_CHECK_HEADERS([unistd.h])
fi

# Checks for typedefs, structures, and compiler characteristics.
AC_C_CONST
AC_STRUCT_TM
AC_TYPE_PID_T
AC_TYPE_SIZE_T
AC_TYPE_SSIZE_T
AC_TYPE_INT64_T
AC_TYPE_UINT8_T
AC_TYPE_UINT16_T
AC_TYPE_UINT32_T
AC_TYPE_UINT64_T

# Checks for library functions.
AC_DEFUN([AC_REQUIRE_FUNCS],[
  AC_REQUIRE([AC_FUNC_FORK])dnl
  AC_REQUIRE([AC_FUNC_MEMCMP])dnl
  AC_REQUIRE([AC_FUNC_MALLOC])dnl
  AC_REQUIRE([AC_FUNC_REALLOC])dnl
  AC_REQUIRE([AC_FUNC_SELECT_ARGTYPES])dnl
  AC_REQUIRE([AC_FUNC_STAT])dnl
  AC_REQUIRE([AC_FUNC_STRFTIME])dnl
  m4_ifdef([AC_FUNC_VFPRINTF],[
    AC_REQUIRE([AC_FUNC_VFPRINTF])dnl
  ])dnl
])dnl
AC_REQUIRE_FUNCS
AC_CHECK_FUNCS([strcasecmp strdup strerror strndup stpcpy localtime_r])
AC_CHECK_FUNCS([bzero client_clear_remote gethostbyname gettimeofday memmove \
                memset select socket strchr strrchr strtol strtoul])
AC_CHECK_FUNCS([ppoll clock_gettime])dnl

# Check for operating system
AC_MSG_CHECKING([whether to enable WIN32 build settings])
AC_LDADD=""
case ${host_os} in
  *mingw32*|*cygwin*)
    win32=true
    AC_MSG_RESULT([yes])
    AC_CHECK_TOOL([WINDRES],[windres],[AC_MSG_ERROR([windres not found])])
    AC_SUBST([WINDRES])
    ;;
  darwin*)
    win32=false
    AC_MSG_RESULT([no])
    # No support for launchd yet, TODO
    AC_DEFINE([HAVE_CFNETWORK],[1],[Define to enable CFNetwork support])
    AC_LDADD="-framework CoreFoundation -framework CFNetwork"
    ;;
  *)
    win32=false
    AC_MSG_RESULT([no])
    PKG_CHECK_MODULES([avahi_client],[avahi-client >= 0.6.32],
                      [have_avahi=yes],[have_avahi=no])
    if test "x${have_avahi}" = "xyes"; then
      AC_HEADER_ASSERT
      AC_DEFINE([HAVE_AVAHI_CLIENT],[1],
                [Define to 1 to enable avahi-client support])
    fi
    ;;
esac
AC_SUBST([AC_LDADD])dnl
AM_CONDITIONAL([WIN32],[test "x${win32}" = "xtrue"])dnl

AC_ARG_WITH([static-libplist],
            [AS_HELP_STRING([--with-static-libplist[=/path/to/static/libplist]],
                            [link against a static libplist])],
            [with_static_libplist=${withval}],
            [with_static_libplist=yes])
echo "with_static_libplist is ${with_static_libplist}"
if test "x${with_static_libplist}" != "xno"; then
  if test "x${with_static_libplist}" = "xyes"; then
    if test "x${LIBPLIST}" != "x"; then
      test -n "${LIBPLIST}" && echo "seeing if ${LIBPLIST} is available statically"
      LIBPLIST_PKG_CONFIG_LIBDIR="`pkg-config --libs-only-L ${LIBPLIST}`"
      if test "x${LIBPLIST_PKG_CONFIG_LIBDIR}" != "x"; then
        test -n "${LIBPLIST_PKG_CONFIG_LIBDIR}" && echo "pkg-config says: ${LIBPLIST_PKG_CONFIG_LIBDIR}"
      else
        echo "outputting some attempts at debugging the relevant pkg-config file"
        echo "'pkg-config --debug --libs-only-L ${LIBPLIST}' says:" && pkg-config --debug --libs-only-L ${LIBPLIST}
        echo "'pkg-config --print-variables ${LIBPLIST}' says:" && pkg-config --print-variables ${LIBPLIST}
        echo "'pkg-config --print-errors ${LIBPLIST}' says:" && pkg-config --print-errors ${LIBPLIST}
        echo "'pkg-config --debug --validate ${LIBPLIST}' says:" && pkg-config --debug --validate ${LIBPLIST}
        PKG_CONFIG_LIBDIR_LIBPLIST="`pkg-config --variable=libdir ${LIBPLIST}`"
        if test "x${PKG_CONFIG_LIBDIR_LIBPLIST}" != "x"; then
          test -n "${PKG_CONFIG_LIBDIR_LIBPLIST}" && echo "trying to use ${PKG_CONFIG_LIBDIR_LIBPLIST} as the relevant libdir here..."
          test -z "${LIBPLIST_PKG_CONFIG_LIBDIR}" && export LIBPLIST_PKG_CONFIG_LIBDIR="${PKG_CONFIG_LIBDIR_LIBPLIST}"
        else
          test -z "${PKG_CONFIG_LIBDIR_LIBPLIST}" && echo "bad news: PKG_CONFIG_LIBDIR_LIBPLIST is empty!"
        fi
      fi
      STATIC_LIBPLIST="`echo ${LIBPLIST_PKG_CONFIG_LIBDIR} | sed "s/^..//; s/[ ]*$/\/${LIBPLIST}.a/"`"
      if test ! -e "${STATIC_LIBPLIST}"; then
        STATIC_LIBPLIST="${LIBPLIST_PKG_CONFIG_LIBDIR}/${LIBPLIST}.a"
      fi
      test -n "${STATIC_LIBPLIST}" && echo "STATIC_LIBPLIST is now ${STATIC_LIBPLIST}"
    else
      STATIC_LIBPLIST="`pkg-config --libs-only-L libplist | sed "s/^..//; s/[ ]*$/\/libplist.a/"`"
    fi
  else
    if test "x${with_static_libplist}" != "x"; then
      test -n "${with_static_libplist}" && STATIC_LIBPLIST="${with_static_libplist}"
    elif test -x "`which locate`"; then
      echo "attempting to locate libplist.a; this may take awhile..."
      STATIC_LIBPLIST="`locate libplist.a | head -n 1`"
    elif test -x "`which find`"; then
      echo "attempting to find libplist.a; this may take awhile..."
      STATIC_LIBPLIST="`find / -name libplist.a 2>/dev/null | head -n 1`"
    else
      STATIC_LIBPLIST=libplist.a
    fi
    if test "x${STATIC_LIBPLIST}" = "x"; then
      test -z "${STATIC_LIBPLIST}" && export STATIC_LIBPLIST=libplist.a
    fi
  fi
  if ! test -f "${STATIC_LIBPLIST}"; then
    AC_MSG_ERROR([The file ${STATIC_LIBPLIST} passed to --with-static-libplist does not exist])
  fi
  echo "*** Note: Will link with static libplist found at ${STATIC_LIBPLIST} ***"
  AC_SUBST([libplist_LIBS],[${STATIC_LIBPLIST}])
else
  echo "*** Note: Skipping checks about linking with static libplist ***"
fi

if test "x${ac_cv_header_sys_socket_h}" = "x"; then
  test -z "${ac_cv_header_sys_socket_h}"
  AC_CHECK_HEADERS([sys/socket.h])
fi

AS_COMPILER_FLAGS([GLOBAL_CFLAGS],["-g -Wall -Wextra -Wmissing-declarations -Wredundant-decls -Wshadow -Wpointer-arith -Wwrite-strings -Wswitch-default -Wno-unused-parameter"])
AC_SUBST([GLOBAL_CFLAGS])dnl

m4_ifdef([AM_SILENT_RULES],[AM_SILENT_RULES([yes])])dnl

# Output.
AC_CONFIG_FILES([
Makefile
usbfluxd/Makefile
tools/Makefile
])
AC_OUTPUT

echo "
Configuration for ${PACKAGE} ${VERSION}:
-------------------------------------------

  install prefix ............: ${prefix}

  Now type 'make' to build ${PACKAGE} ${VERSION},
  and then 'make install' for installation.
"

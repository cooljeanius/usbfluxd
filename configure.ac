dnl#                                               -*- Autoconf -*-
dnl# Process this file with autoconf to produce a configure script.

AC_PREREQ([2.64])
AC_INIT([usbfluxd],[1.2.0],[https://corellium.com],[],[https://corellium.com])
AM_INIT_AUTOMAKE([dist-bzip2 no-dist-gzip check-news])
m4_ifdef([AM_SILENT_RULES],[AM_SILENT_RULES])
AC_CONFIG_SRCDIR([src/])
AC_CONFIG_HEADERS([config.h])
AC_CONFIG_MACRO_DIR([m4])dnl

# Checks for programs.
AC_PROG_CC
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
])dnl
AC_REQUIRE_PROGS

# Checks for libraries.
PKG_CHECK_MODULES([libplist],[libplist >= 1.11])
AC_CHECK_LIB([pthread],[pthread_create, pthread_mutex_lock],
             [AC_SUBST([libpthread_LIBS],[-lpthread])],
             [AC_MSG_ERROR([libpthread is required to build usbfluxd])])dnl

# Checks for header files.
AC_DEFUN([AC_REQUIRE_HEADER_STDC],[
  AC_REQUIRE([AC_HEADER_STDC])dnl
])dnl
AC_REQUIRE_HEADER_STDC
AC_HEADER_STDBOOL dnl# also "_CHECK"s it
AC_HEADER_TIME
AC_CHECK_HEADERS([CFNetwork/CFNetServices.h])
AC_CHECK_HEADERS([arpa/inet.h fcntl.h netdb.h netinet/in.h sys/statvfs.h \
                  sys/time.h syslog.h])dnl

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
AC_CHECK_FUNCS([bzero gethostbyname gettimeofday memmove memset select socket \
                strchr strrchr strtol strtoul])
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
AC_SUBST([AC_LDADD])
AM_CONDITIONAL([WIN32],[test "x${win32}" = "xtrue"])dnl

AC_ARG_WITH([static-libplist],
            [AS_HELP_STRING(["--with-static-libplist[=/path/to/static/libplist"]],
                            [link against a static libplist])],
            [with_static_libplist=${withval}],
            [with_static_libplist=yes])
if test "x$with_static_libplist" != "xno"; then
  if test "x${with_static_libplist}" = "xyes"; then
    STATIC_LIBPLIST="`pkg-config --libs-only-L libplist | sed 's/^..//; s/[ ]*$/\/libplist.a/'`"
  else
    STATIC_LIBPLIST="${with_static_libplist}"
  fi
  if ! test -f "${STATIC_LIBPLIST}"; then
    AC_MSG_ERROR([The file ${STATIC_LIBPLIST} passed to --with-static-libplist does not exist])
  fi
  echo "*** Note: Will link with static libplist found at ${STATIC_LIBPLIST} ***"
  AC_SUBST([libplist_LIBS],[${STATIC_LIBPLIST}])
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
src/Makefile
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

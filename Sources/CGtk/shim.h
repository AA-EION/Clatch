// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group
//
// The C API Clatch for Linux uses: GTK 4, libadwaita, GIO and pangocairo.
// Swift cannot call C macros or variadic functions, so the few that are
// needed have small inline wrappers here.
#pragma once
#include <adwaita.h>
#include <gtk/gtk.h>
#include <gio/gio.h>
#include <glib-unix.h>
#include <pango/pangocairo.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <signal.h>
#include <spawn.h>

/// g_signal_connect is a macro.
static inline gulong clatch_connect(gpointer instance, const char *signal, GCallback handler,
                                    gpointer data, GClosureNotify destroy) {
    return g_signal_connect_data(instance, signal, handler, data, destroy, (GConnectFlags)0);
}

/// pidfd_open(2): a file descriptor that becomes readable when the process exits.
static inline int clatch_pidfd_open(pid_t pid) {
#ifdef SYS_pidfd_open
    return (int)syscall(SYS_pidfd_open, pid, 0);
#else
    return -1;
#endif
}

static inline GType clatch_string_type(void) { return G_TYPE_STRING; }

// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group
//
// A stand-in for Claude Desktop for Linux, for Clatch's end-to-end tests. It
// behaves the way Clatch relies on (as measured on the real app):
//  * one instance per data folder (--user-data-dir, default ~/.config/Claude):
//    the folder's SingletonLock symlink points to "<hostname>-<pid>";
//  * a second start on the same folder hands its arguments over (appended to
//    <folder>/handoff.log) and exits 0;
//  * SIGTERM, SIGHUP and SIGINT ask it to quit: it logs "marking readyForQuit"
//    in <folder>/logs/main.log, removes the lock and exits. With
//    STAND_IN_DECLINE=1 it says no to the first request, like a user who
//    chose "Keep working" in Claude's dialog;
//  * a helper process (--type=utility) that outlives the main one briefly.
#define _GNU_SOURCE
#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static char folder[PATH_MAX], lockPath[PATH_MAX + 32], logPath[PATH_MAX + 32];
static volatile sig_atomic_t quitRequested = 0;
static int declined = 0;

static void logLine(const char *message) {
    char stamp[32];
    time_t now = time(NULL);
    strftime(stamp, sizeof stamp, "%Y-%m-%d %H:%M:%S", localtime(&now));
    FILE *f = fopen(logPath, "a");
    if (f) { fprintf(f, "%s [info] %s\n", stamp, message); fclose(f); }
}

static void onSignal(int sig) { (void)sig; quitRequested = 1; }

int main(int argc, char **argv) {
    const char *dir = NULL;
    int helper = 0;
    for (int i = 1; i < argc; i++) {
        if (!strncmp(argv[i], "--user-data-dir=", 16)) dir = argv[i] + 16;
        if (!strncmp(argv[i], "--type=", 7)) helper = 1;
    }
    if (helper) {
        // A helper lingers 0.6 s after its parent ends, like Chromium's processes shutting down.
        prctl(PR_SET_PDEATHSIG, SIGUSR1);
        signal(SIGUSR1, onSignal);
        while (!quitRequested) pause();
        usleep(600 * 1000);
        return 0;
    }
    if (dir) snprintf(folder, sizeof folder, "%s", dir);
    else snprintf(folder, sizeof folder, "%s/.config/Claude", getenv("HOME"));
    snprintf(lockPath, sizeof lockPath, "%s/SingletonLock", folder);
    char logs[PATH_MAX + 16];
    snprintf(logs, sizeof logs, "%s/logs", folder);
    snprintf(logPath, sizeof logPath, "%s/main.log", logs);

    char host[256] = "", target[PATH_MAX];
    gethostname(host, sizeof host - 1);
    ssize_t n = readlink(lockPath, target, sizeof target - 1);
    if (n > 0) {
        target[n] = 0;
        char *dash = strrchr(target, '-');
        pid_t owner = dash ? (pid_t)atoi(dash + 1) : 0;
        if (owner > 0 && kill(owner, 0) == 0) {
            // Hand over to the running instance (Electron's second-instance).
            char handoff[PATH_MAX + 32];
            snprintf(handoff, sizeof handoff, "%s/handoff.log", folder);
            FILE *f = fopen(handoff, "a");
            if (f) {
                for (int i = 1; i < argc; i++) fprintf(f, "%s%s", i > 1 ? " " : "", argv[i]);
                fprintf(f, "\n");
                fclose(f);
            }
            return 0;
        }
        unlink(lockPath); // stale
    }
    mkdir(folder, 0700);
    mkdir(logs, 0700);
    snprintf(target, sizeof target, "%s-%d", host, (int)getpid());
    if (symlink(target, lockPath) != 0) { perror("SingletonLock"); return 1; }
    // The files real Claude always creates in its folder (Clatch's layout check looks for them).
    const char *files[] = { "Local State", "Preferences", "config.json" };
    for (int i = 0; i < 3; i++) {
        char path[PATH_MAX + 32];
        snprintf(path, sizeof path, "%s/%s", folder, files[i]);
        if (access(path, F_OK) != 0) { FILE *f = fopen(path, "w"); if (f) { fputs("{}", f); fclose(f); } }
    }
    logLine("Claude stand-in started");

    pid_t child = fork();
    if (child == 0) {
        char typeArg[] = "--type=utility";
        char dirArg[PATH_MAX + 32];
        snprintf(dirArg, sizeof dirArg, "--user-data-dir=%s", folder);
        char *args[] = { argv[0], typeArg, dirArg, NULL };
        execv("/proc/self/exe", args);
        _exit(1);
    }

    signal(SIGTERM, onSignal);
    signal(SIGHUP, onSignal);
    signal(SIGINT, onSignal);
    declined = getenv("STAND_IN_DECLINE") && !strcmp(getenv("STAND_IN_DECLINE"), "1");
    for (;;) {
        pause();
        if (!quitRequested) continue;
        quitRequested = 0;
        if (declined) {
            declined = 0;
            logLine("beforeQuit: vetoed by before-quit interceptor");
            continue;
        }
        logLine("Successully ran all onQuitCleanup handlers, marking readyForQuit");
        unlink(lockPath);
        return 0;
    }
}

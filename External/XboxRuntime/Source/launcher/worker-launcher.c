#include <mach-o/dyld.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    char executable[PATH_MAX];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) != 0) {
        fputs("WinLauncher worker path is too long.\n", stderr);
        return 126;
    }

    char resolved[PATH_MAX];
    if (realpath(executable, resolved) == NULL) {
        perror("WinLauncher worker path");
        return 126;
    }
    char *separator = strrchr(resolved, '/');
    if (separator == NULL) {
        fputs("WinLauncher worker path is invalid.\n", stderr);
        return 126;
    }
    *separator = '\0';

    char python[PATH_MAX];
    char setup[PATH_MAX];
    if (snprintf(python, sizeof(python), "%s/python/bin/python3", resolved) >= (int)sizeof(python) ||
        snprintf(setup, sizeof(setup), "%s/setup.py", resolved) >= (int)sizeof(setup)) {
        fputs("WinLauncher worker path is too long.\n", stderr);
        return 126;
    }

    char **arguments = calloc((size_t)argc + 3, sizeof(char *));
    if (arguments == NULL) {
        fputs("WinLauncher could not allocate worker arguments.\n", stderr);
        return 126;
    }
    arguments[0] = python;
    arguments[1] = "-I";
    arguments[2] = setup;
    for (int index = 1; index < argc; index++) {
        arguments[index + 2] = argv[index];
    }
    arguments[argc + 2] = NULL;

    execv(python, arguments);
    perror("WinLauncher portable Python");
    free(arguments);
    return 126;
}

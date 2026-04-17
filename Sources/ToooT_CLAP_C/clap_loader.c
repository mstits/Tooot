/*
 *  CLAP bundle loader (dlopen + symbol resolution).
 *
 *  A .clap bundle on macOS is a regular CFBundle with an executable that exports
 *  a single `clap_entry` symbol of type `clap_plugin_entry_t`. We open the binary
 *  with dlopen and look up that symbol — no CFBundle plumbing required.
 */

#include "clap_loader.h"

#include <dirent.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>

struct tooot_clap_bundle {
    void                      *dl;
    const clap_plugin_entry_t *entry;
    char                      *path;
};

/// On macOS, a `.clap` bundle typically contains Contents/MacOS/<name>.
/// If `path` points to the bundle directory, walk into Contents/MacOS and
/// pick the first executable file.
static char *resolve_binary_path(const char *path) {
    struct stat st;
    if (stat(path, &st) != 0) return NULL;
    if (!S_ISDIR(st.st_mode)) {
        // Direct executable path — just dup it.
        return strdup(path);
    }

    size_t baseLen = strlen(path);
    char   macos[1024];
    snprintf(macos, sizeof(macos), "%s/Contents/MacOS", path);
    DIR *d = opendir(macos);
    if (!d) return NULL;
    struct dirent *ent;
    char *result = NULL;
    while ((ent = readdir(d)) != NULL) {
        if (ent->d_name[0] == '.') continue;
        char full[2048];
        snprintf(full, sizeof(full), "%s/%s", macos, ent->d_name);
        struct stat fst;
        if (stat(full, &fst) == 0 && S_ISREG(fst.st_mode) && (fst.st_mode & S_IXUSR)) {
            result = strdup(full);
            break;
        }
    }
    closedir(d);
    (void)baseLen;
    return result;
}

tooot_clap_bundle_t *tooot_clap_bundle_open(const char *path) {
    if (!path) return NULL;
    char *bin = resolve_binary_path(path);
    if (!bin) return NULL;

    void *dl = dlopen(bin, RTLD_LAZY | RTLD_LOCAL);
    free(bin);
    if (!dl) return NULL;

    const clap_plugin_entry_t *entry =
        (const clap_plugin_entry_t *)dlsym(dl, "clap_entry");
    if (!entry || !entry->init) {
        dlclose(dl);
        return NULL;
    }
    if (!entry->init(path)) {
        dlclose(dl);
        return NULL;
    }

    tooot_clap_bundle_t *b = (tooot_clap_bundle_t *)calloc(1, sizeof(*b));
    if (!b) {
        if (entry->deinit) entry->deinit();
        dlclose(dl);
        return NULL;
    }
    b->dl    = dl;
    b->entry = entry;
    b->path  = strdup(path);
    return b;
}

void tooot_clap_bundle_close(tooot_clap_bundle_t *b) {
    if (!b) return;
    if (b->entry && b->entry->deinit) b->entry->deinit();
    if (b->dl)   dlclose(b->dl);
    if (b->path) free(b->path);
    free(b);
}

const clap_plugin_entry_t *tooot_clap_bundle_entry(const tooot_clap_bundle_t *b) {
    return b ? b->entry : NULL;
}

const clap_plugin_factory_t *tooot_clap_bundle_factory(const tooot_clap_bundle_t *b) {
    if (!b || !b->entry || !b->entry->get_factory) return NULL;
    return (const clap_plugin_factory_t *)b->entry->get_factory(CLAP_PLUGIN_FACTORY_ID);
}

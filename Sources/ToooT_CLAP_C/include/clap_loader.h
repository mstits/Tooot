/*
 *  C-side dlopen wrapper for CLAP bundles.
 *  Swift calls into these from `CLAPHost` rather than touching dlfcn directly.
 */

#ifndef TOOOT_CLAP_LOADER_H
#define TOOOT_CLAP_LOADER_H

#include "clap_min.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Opens a .clap bundle at `path`, resolves the `clap_entry` symbol, calls its
/// `init(path)`, and returns the entry struct. Returns NULL on any failure.
/// The returned pointer must be freed via `tooot_clap_bundle_close`.
typedef struct tooot_clap_bundle tooot_clap_bundle_t;

tooot_clap_bundle_t *tooot_clap_bundle_open(const char *path);
void                 tooot_clap_bundle_close(tooot_clap_bundle_t *bundle);

/// Returns the bundle's `clap_plugin_entry_t` (non-owning).
const clap_plugin_entry_t *tooot_clap_bundle_entry(const tooot_clap_bundle_t *bundle);

/// Fetches the plugin factory from the bundle. NULL if the bundle doesn't export one.
const clap_plugin_factory_t *tooot_clap_bundle_factory(const tooot_clap_bundle_t *bundle);

#ifdef __cplusplus
}
#endif

#endif

/*
 *  Umbrella header for the ToooT_CLAP_C module.
 *  Exposes the minimal CLAP ABI declarations plus our C-side bundle loader
 *  (which wraps dlopen so Swift doesn't have to deal with symbol resolution).
 */

#ifndef TOOOT_CLAP_C_UMBRELLA_H
#define TOOOT_CLAP_C_UMBRELLA_H

#include "clap_min.h"
#include "clap_loader.h"

#endif

/*
 * Minimal subset of the CLAP plugin ABI, sufficient for discovery, instantiation,
 * activation, event-driven processing, and teardown.
 *
 * Based on the public CLAP SDK (BSD-3-Clause). See:
 *   https://github.com/free-audio/clap
 *
 * This header is vendored only to avoid a git submodule. When you eventually
 * `git submodule add https://github.com/free-audio/clap Sources/ToooT_CLAP/clap-sdk`
 * and point `headerSearchPath` at it, delete this file — the upstream headers are
 * a drop-in replacement. Struct layouts and constants here match upstream 1.2.x.
 *
 * BSD-3-Clause — the CLAP project's license. Copy included verbatim in LICENSES/CLAP.txt.
 */

#ifndef TOOOT_CLAP_MIN_H
#define TOOOT_CLAP_MIN_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ───── clap_version_t ─────────────────────────────────────────────── */
typedef struct clap_version {
    uint32_t major;
    uint32_t minor;
    uint32_t revision;
} clap_version_t;

#define CLAP_VERSION_MAJOR    1
#define CLAP_VERSION_MINOR    2
#define CLAP_VERSION_REVISION 0
#define CLAP_VERSION_INIT { CLAP_VERSION_MAJOR, CLAP_VERSION_MINOR, CLAP_VERSION_REVISION }

#define CLAP_PLUGIN_FACTORY_ID "clap.plugin-factory"
#define CLAP_CORE_EVENT_SPACE_ID 0

/* ───── descriptor ─────────────────────────────────────────────────── */
typedef struct clap_plugin_descriptor {
    clap_version_t clap_version;
    const char    *id;
    const char    *name;
    const char    *vendor;
    const char    *url;
    const char    *manual_url;
    const char    *support_url;
    const char    *version;
    const char    *description;
    const char *const *features;
} clap_plugin_descriptor_t;

/* ───── audio i/o ──────────────────────────────────────────────────── */
typedef struct clap_audio_buffer {
    float   **data32;
    double  **data64;
    uint32_t  channel_count;
    uint32_t  latency;
    uint64_t  constant_mask;
} clap_audio_buffer_t;

/* ───── events ─────────────────────────────────────────────────────── */
typedef struct clap_event_header {
    uint32_t size;
    uint32_t time;
    uint16_t space_id;
    uint16_t type;
    uint32_t flags;
} clap_event_header_t;

enum {
    CLAP_EVENT_NOTE_ON     = 0,
    CLAP_EVENT_NOTE_OFF    = 1,
    CLAP_EVENT_NOTE_CHOKE  = 2,
    CLAP_EVENT_NOTE_END    = 3,
    CLAP_EVENT_PARAM_VALUE = 5,
    CLAP_EVENT_MIDI        = 8
};

typedef struct clap_event_note {
    clap_event_header_t header;
    int32_t note_id;
    int16_t port_index;
    int16_t channel;
    int16_t key;
    double  velocity;
} clap_event_note_t;

typedef struct clap_event_midi {
    clap_event_header_t header;
    uint16_t port_index;
    uint8_t  data[3];
} clap_event_midi_t;

typedef struct clap_input_events {
    void *ctx;
    uint32_t (*size)(const struct clap_input_events *);
    const clap_event_header_t *(*get)(const struct clap_input_events *, uint32_t index);
} clap_input_events_t;

typedef struct clap_output_events {
    void *ctx;
    bool (*try_push)(const struct clap_output_events *, const clap_event_header_t *);
} clap_output_events_t;

/* ───── transport (minimum) ────────────────────────────────────────── */
typedef struct clap_event_transport {
    clap_event_header_t header;
    uint32_t flags;
    int64_t  song_pos_beats;
    int64_t  song_pos_seconds;
    double   tempo;
    double   tempo_inc;
    int64_t  loop_start_beats;
    int64_t  loop_end_beats;
    int64_t  loop_start_seconds;
    int64_t  loop_end_seconds;
    int64_t  bar_start;
    int32_t  bar_number;
    int16_t  tsig_num;
    int16_t  tsig_denom;
} clap_event_transport_t;

/* ───── process ────────────────────────────────────────────────────── */
enum {
    CLAP_PROCESS_ERROR                 = 0,
    CLAP_PROCESS_CONTINUE              = 1,
    CLAP_PROCESS_CONTINUE_IF_NOT_QUIET = 2,
    CLAP_PROCESS_TAIL                  = 3,
    CLAP_PROCESS_SLEEP                 = 4
};
typedef int32_t clap_process_status;

typedef struct clap_process {
    int64_t steady_time;
    uint32_t frames_count;
    const clap_event_transport_t *transport;
    const clap_audio_buffer_t    *audio_inputs;
    uint32_t audio_inputs_count;
    const clap_audio_buffer_t    *audio_outputs;
    uint32_t audio_outputs_count;
    const clap_input_events_t    *in_events;
    const clap_output_events_t   *out_events;
} clap_process_t;

/* ───── host ───────────────────────────────────────────────────────── */
typedef struct clap_host {
    clap_version_t clap_version;
    void          *host_data;
    const char    *name;
    const char    *vendor;
    const char    *url;
    const char    *version;

    const void *(*get_extension)(const struct clap_host *, const char *extension_id);
    void        (*request_restart)(const struct clap_host *);
    void        (*request_process)(const struct clap_host *);
    void        (*request_callback)(const struct clap_host *);
} clap_host_t;

/* ───── plugin vtable ──────────────────────────────────────────────── */
typedef struct clap_plugin {
    const clap_plugin_descriptor_t *desc;
    void *plugin_data;

    bool (*init)(const struct clap_plugin *);
    void (*destroy)(const struct clap_plugin *);
    bool (*activate)(const struct clap_plugin *, double sample_rate,
                     uint32_t min_frames, uint32_t max_frames);
    void (*deactivate)(const struct clap_plugin *);
    bool (*start_processing)(const struct clap_plugin *);
    void (*stop_processing)(const struct clap_plugin *);
    void (*reset)(const struct clap_plugin *);
    clap_process_status (*process)(const struct clap_plugin *, const clap_process_t *);
    const void *(*get_extension)(const struct clap_plugin *, const char *id);
    void (*on_main_thread)(const struct clap_plugin *);
} clap_plugin_t;

/* ───── factory ────────────────────────────────────────────────────── */
typedef struct clap_plugin_factory {
    uint32_t (*get_plugin_count)(const struct clap_plugin_factory *);
    const clap_plugin_descriptor_t *(*get_plugin_descriptor)(const struct clap_plugin_factory *,
                                                             uint32_t index);
    const clap_plugin_t *(*create_plugin)(const struct clap_plugin_factory *,
                                          const clap_host_t *host,
                                          const char *plugin_id);
} clap_plugin_factory_t;

/* ───── bundle entry ───────────────────────────────────────────────── */
typedef struct clap_plugin_entry {
    clap_version_t clap_version;
    bool        (*init)(const char *plugin_path);
    void        (*deinit)(void);
    const void *(*get_factory)(const char *factory_id);
} clap_plugin_entry_t;

#ifdef __cplusplus
}
#endif

#endif /* TOOOT_CLAP_MIN_H */

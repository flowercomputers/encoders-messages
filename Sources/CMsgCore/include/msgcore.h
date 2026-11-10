// C interface to the Rust core (core/src/lib.rs).
//
// The index has MS_LAYERS layers: the same messages embedded at different
// granularities. A message's score is a weighted blend across layers.
#ifndef MSGCORE_H
#define MSGCORE_H

#include <stddef.h>
#include <stdint.h>

#define MS_LAYERS 3

/// Width of the embedding vectors.
size_t ms_dimensions(void);
/// Number of messages (the size of layer 0).
size_t ms_count(void);
/// Drop one layer so it can be embedded again.
void ms_clear_layer(size_t layer);
/// Embed `n` texts and append them to `layer`. Text i is
/// bytes[offsets[i]..offsets[i+1]], so `offsets` has n + 1 entries.
void ms_add(size_t layer, const uint8_t *bytes, const size_t *offsets, size_t n);
/// For a layer with fewer vectors than messages: message i uses vector rows[i].
void ms_set_map(size_t layer, const uint32_t *rows, size_t n);
/// Top-k search. A message scores sum(weights[l] * similarity in layer l);
/// `weights` has MS_LAYERS entries. Each similarity is the cosine scaled by
/// len / (len + brevity[l]), len being the text's length in bytes. Writes up to `k` message indices and
/// scores, best first; returns how many were written. `filter` is NULL or one
/// byte per message, where 0 means "skip". Only messages ranked strictly after
/// (after_score, after_index) are returned: pass the previous page's last
/// result to get the next page, or INFINITY for the first.
size_t ms_search(const uint8_t *query, size_t query_len, const float *weights,
                 const float *brevity, size_t k,
                 const uint8_t *filter, float after_score, uint32_t after_index,
                 uint32_t *out_indices, float *out_scores);
/// Where in time the matches are: scores every message, then counts those
/// scoring at least `cutoff` times the best score into out[bins[i]]. `bins`
/// has one bucket number per message; `out` has `bin_count` entries. Returns
/// the best score (0 if nothing matched).
float ms_histogram(const uint8_t *query, size_t query_len, const float *weights,
                   const float *brevity, const uint8_t *filter, const uint32_t *bins,
                   size_t bin_count, float cutoff, float *out);

#endif

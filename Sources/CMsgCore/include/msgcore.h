// C interface to the Rust core (core/src/lib.rs).
#ifndef MSGCORE_H
#define MSGCORE_H

#include <stddef.h>
#include <stdint.h>

/// Width of the embedding vectors.
size_t ms_dimensions(void);
/// Number of messages in the index.
size_t ms_count(void);
/// Drop the whole index.
void ms_clear(void);
/// Embed `n` texts and append them. Text i is bytes[offsets[i]..offsets[i+1]],
/// so `offsets` has n + 1 entries.
void ms_add(const uint8_t *bytes, const size_t *offsets, size_t n);
/// Top-k search. Writes up to `k` indices (insertion order) and scores, best
/// first; returns how many were written. `filter` is NULL or one byte per
/// entry, where 0 means "skip this entry". Only entries ranked strictly after
/// (after_score, after_index) are returned: pass the previous page's last
/// result to get the next page, or INFINITY for the first.
size_t ms_search(const uint8_t *query, size_t query_len, size_t k,
                 const uint8_t *filter, float after_score, uint32_t after_index,
                 uint32_t *out_indices, float *out_scores);

#endif

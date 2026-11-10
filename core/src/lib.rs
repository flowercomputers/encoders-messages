//! The data plane of Message Search: embed text with `encoders`, keep the
//! vectors in flat int8 arrays, and answer queries with a parallel brute-force
//! scan. No ANN index, no persistence: embedding is fast enough that the whole
//! index is rebuilt from scratch on every launch, and again whenever a message
//! arrives.
//!
//! The index has `LAYERS` layers, each an embedding of the same messages at a
//! different granularity (the message alone, the exchange around it, the whole
//! sitting). A message's score is a weighted blend of its similarity in each
//! layer. A layer either has one vector per message, or fewer vectors plus a
//! map from message to vector (many messages share one sitting).
//!
//! Each vector is stored as `D` int8 components (scaled so the largest
//! component is ±127) plus one f32 inverse norm, so cosine similarity is
//! `dot_i8(q, v) * inv_norm(q) * inv_norm(v)`. That is 260 bytes a vector at
//! D = 256.

use rayon::prelude::*;
use std::sync::RwLock;

const D: usize = encoders::DIMENSIONS;
pub const LAYERS: usize = 3;
/// Texts embedded per `encoders::encode` call while indexing.
const ENCODE_BATCH: usize = 1 << 15;
/// Messages scanned per rayon task while searching.
const SCAN_ROWS: usize = 1 << 13;

struct Layer {
    vecs: Vec<i8>,
    /// Inverse norm of each vector.
    inv_norms: Vec<f32>,
    /// Length in bytes of the text each vector was made from.
    lengths: Vec<f32>,
    /// Message index -> vector index, or empty when they are the same.
    map: Vec<u32>,
}

impl Layer {
    const EMPTY: Layer = Layer { vecs: Vec::new(), inv_norms: Vec::new(), lengths: Vec::new(), map: Vec::new() };
}

static INDEX: RwLock<[Layer; LAYERS]> = RwLock::new([Layer::EMPTY; LAYERS]);

/// Quantize `v` into `out`, returning the inverse norm of the quantized vector
/// (0 for an all-zero vector, which then scores 0 against everything).
fn quantize(v: &[f32; D], out: &mut [i8]) -> f32 {
    let max = v.iter().fold(0f32, |m, x| m.max(x.abs()));
    if !(max > 0.0) || !max.is_finite() {
        out.fill(0);
        return 0.0;
    }
    let scale = 127.0 / max;
    let mut sq = 0i32;
    for (o, x) in out.iter_mut().zip(v) {
        let q = (x * scale).round() as i8;
        *o = q;
        sq += q as i32 * q as i32;
    }
    1.0 / (sq as f32).sqrt()
}

#[inline]
fn dot(a: &[i8], b: &[i8]) -> i32 {
    a.iter().zip(b).map(|(x, y)| *x as i32 * *y as i32).sum()
}

#[unsafe(no_mangle)]
pub extern "C" fn ms_dimensions() -> usize {
    D
}

/// Number of messages: the size of layer 0, which always has one vector each.
#[unsafe(no_mangle)]
pub extern "C" fn ms_count() -> usize {
    INDEX.read().unwrap()[0].inv_norms.len()
}

/// Drop one layer, so it can be embedded again with different settings.
#[unsafe(no_mangle)]
pub extern "C" fn ms_clear_layer(layer: usize) {
    if layer < LAYERS {
        INDEX.write().unwrap()[layer] = Layer::EMPTY;
    }
}

/// Embed `n` texts and append them to `layer`. Text `i` is the UTF-8 bytes
/// `bytes[offsets[i]..offsets[i + 1]]`, so `offsets` holds `n + 1` entries.
///
/// # Safety
/// `offsets` must point to `n + 1` ascending values and `bytes` must be valid
/// for reads up to `offsets[n]`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ms_add(layer: usize, bytes: *const u8, offsets: *const usize, n: usize) {
    if n == 0 || layer >= LAYERS {
        return;
    }
    let offsets = unsafe { std::slice::from_raw_parts(offsets, n + 1) };
    let bytes = unsafe { std::slice::from_raw_parts(bytes, offsets[n]) };

    let mut vecs = vec![0i8; n * D];
    let mut inv_norms = vec![0f32; n];
    let lengths: Vec<f32> = offsets.windows(2).map(|w| (w[1] - w[0]) as f32).collect();
    for start in (0..n).step_by(ENCODE_BATCH) {
        let end = (start + ENCODE_BATCH).min(n);
        let texts = (start..end).map(|i| String::from_utf8_lossy(&bytes[offsets[i]..offsets[i + 1]]));
        let embedded = encoders::encode(texts);
        vecs[start * D..end * D]
            .par_chunks_mut(D)
            .zip(inv_norms[start..end].par_iter_mut())
            .zip(embedded.par_iter())
            .for_each(|((out, inv), v)| *inv = quantize(v, out));
    }

    let mut index = INDEX.write().unwrap();
    index[layer].vecs.extend_from_slice(&vecs);
    index[layer].inv_norms.extend_from_slice(&inv_norms);
    index[layer].lengths.extend_from_slice(&lengths);
}

/// Say which of `layer`'s vectors each message uses: message `i` uses vector
/// `rows[i]`. Layers without a map have one vector per message.
///
/// # Safety
/// `rows` must be valid for `n` entries.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ms_set_map(layer: usize, rows: *const u32, n: usize) {
    if layer < LAYERS {
        INDEX.write().unwrap()[layer].map = unsafe { std::slice::from_raw_parts(rows, n) }.to_vec();
    }
}

/// The ranking: higher score first, ties broken by lower index. It is a total
/// order, which is what lets a (score, index) pair act as a paging cursor.
#[inline]
fn rank(a: &(f32, u32), b: &(f32, u32)) -> std::cmp::Ordering {
    b.0.total_cmp(&a.0).then(a.1.cmp(&b.1))
}

/// Keep the best `k` of `hits`.
fn keep_top(hits: &mut Vec<(f32, u32)>, k: usize) {
    if hits.len() > k {
        hits.select_nth_unstable_by(k - 1, rank);
        hits.truncate(k);
    }
}

/// How one layer contributes to a message's score.
enum Source<'a> {
    /// One vector per message: compare during the scan.
    Direct { weight: f32, brevity: f32, layer: &'a Layer },
    /// Shared vectors: every vector's similarity is computed once up front.
    Mapped { weight: f32, scores: Vec<f32>, map: &'a [u32] },
}

/// Find the `k` messages most similar to the query. A message's score is
/// `sum(weights[l] * similarity in layer l)`; `weights` has `LAYERS` entries
/// and a zero weight skips the layer entirely. Writes up to `k` message
/// indices and scores, best first, and returns how many were written.
///
/// `brevity` also has `LAYERS` entries. A layer's similarity is its cosine
/// scaled by `len / (len + brevity)`, where `len` is the text's length in
/// bytes. Mean-pooled embeddings make a two-word text that shares one word
/// with the query look like a near-perfect match; this pulls such texts down.
/// Zero turns it off.
///
/// `filter` is either null or one byte per message; messages whose byte is 0
/// are skipped.
///
/// `after_score` and `after_index` page through the ranking: only messages
/// ranked strictly after that (score, index) pair are returned. Pass the last
/// result of the previous page, or `f32::INFINITY` for the first page. Every
/// page is one scan, so reaching result 10,000 costs no more memory than
/// reaching result 10.
///
/// # Safety
/// `query` must be valid for `query_len` bytes; `weights` and `brevity` for
/// `LAYERS` floats each;
/// `filter`, if not null, for `ms_count()` bytes; `out_indices` and
/// `out_scores` must each have room for `k` entries.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ms_search(
    query: *const u8,
    query_len: usize,
    weights: *const f32,
    brevity: *const f32,
    k: usize,
    filter: *const u8,
    after_score: f32,
    after_index: u32,
    out_indices: *mut u32,
    out_scores: *mut f32,
) -> usize {
    if k == 0 {
        return 0;
    }
    let query = unsafe { std::slice::from_raw_parts(query, query_len) };
    let weights = unsafe { std::slice::from_raw_parts(weights, LAYERS) };
    let brevity = unsafe { std::slice::from_raw_parts(brevity, LAYERS) };
    let embedded = encoders::encode_single(String::from_utf8_lossy(query));
    let mut q = [0i8; D];
    let q_inv = quantize(&embedded, &mut q);
    if q_inv == 0.0 {
        return 0;
    }

    let index = INDEX.read().unwrap();
    let count = index[0].inv_norms.len();
    let filter = (!filter.is_null()).then(|| unsafe { std::slice::from_raw_parts(filter, count) });

    let sources: Vec<Source> = index
        .iter()
        .zip(weights.iter().zip(brevity))
        .filter(|(layer, (weight, _))| **weight != 0.0 && !layer.inv_norms.is_empty())
        .filter_map(|(layer, (&weight, &brevity))| {
            if layer.map.is_empty() {
                (layer.inv_norms.len() >= count).then_some(Source::Direct { weight, brevity, layer })
            } else if layer.map.len() >= count {
                let scores = layer
                    .vecs
                    .par_chunks_exact(D)
                    .zip(layer.inv_norms.par_iter().zip(&layer.lengths))
                    .map(|(v, (inv, len))| dot(&q, v) as f32 * inv * q_inv * (len / (len + brevity)))
                    .collect();
                Some(Source::Mapped { weight, scores, map: &layer.map })
            } else {
                None
            }
        })
        .collect();
    if sources.is_empty() {
        return 0;
    }

    let mut hits = (0..count.div_ceil(SCAN_ROWS))
        .into_par_iter()
        .map(|chunk| {
            let start = chunk * SCAN_ROWS;
            let end = (start + SCAN_ROWS).min(count);
            let mut local: Vec<(f32, u32)> = Vec::with_capacity(2 * k);
            let mut floor = f32::NEG_INFINITY;
            for i in start..end {
                if filter.is_some_and(|f| f[i] == 0) {
                    continue;
                }
                let mut score = 0f32;
                for source in &sources {
                    score += match source {
                        Source::Direct { weight, brevity, layer } => {
                            let len = layer.lengths[i];
                            let cosine = dot(&q, &layer.vecs[i * D..(i + 1) * D]) as f32 * layer.inv_norms[i] * q_inv;
                            weight * cosine * (len / (len + brevity))
                        }
                        Source::Mapped { weight, scores, map } => weight * scores[map[i] as usize],
                    };
                }
                let index = i as u32;
                if score > after_score || (score == after_score && index <= after_index) {
                    continue;
                }
                if score > floor {
                    local.push((score, index));
                    if local.len() == 2 * k {
                        keep_top(&mut local, k);
                        floor = local.iter().fold(f32::INFINITY, |m, h| m.min(h.0));
                    }
                }
            }
            keep_top(&mut local, k);
            local
        })
        .reduce(Vec::new, |mut a, b| {
            a.extend(b);
            keep_top(&mut a, k);
            a
        });
    drop(sources);
    drop(index);

    hits.sort_unstable_by(rank);
    let out_indices = unsafe { std::slice::from_raw_parts_mut(out_indices, k) };
    let out_scores = unsafe { std::slice::from_raw_parts_mut(out_scores, k) };
    for (i, (score, idx)) in hits.iter().enumerate() {
        out_indices[i] = *idx;
        out_scores[i] = *score;
    }
    hits.len()
}

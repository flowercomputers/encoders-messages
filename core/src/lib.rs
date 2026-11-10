//! The data plane of Message Search: embed text with `encoders`, keep the
//! vectors in one flat int8 array, and answer queries with a parallel
//! brute-force scan. No ANN index, no persistence: embedding is fast enough
//! that the whole index is rebuilt from scratch on every launch.
//!
//! Each vector is stored as `D` int8 components (scaled so the largest
//! component is ±127) plus one f32 inverse norm, so cosine similarity is
//! `dot_i8(q, v) * inv_norm(q) * inv_norm(v)`. That is 260 bytes a message
//! at D = 256.

use rayon::prelude::*;
use std::sync::RwLock;

const D: usize = encoders::DIMENSIONS;
/// Texts embedded per `encoders::encode` call while indexing.
const ENCODE_BATCH: usize = 1 << 15;
/// Texts shorter than this many bytes are pulled down the ranking. Mean-pooled
/// embeddings make a two-word text that shares one word with the query look
/// like a near-perfect match; this keeps "What news" from beating a real
/// exchange about the news.
const BREVITY_BYTES: f32 = 24.0;
/// Rows scanned per rayon task while searching.
const SCAN_ROWS: usize = 1 << 13;

struct Index {
    vecs: Vec<i8>,
    inv_norms: Vec<f32>,
}

static INDEX: RwLock<Index> = RwLock::new(Index { vecs: Vec::new(), inv_norms: Vec::new() });

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

#[unsafe(no_mangle)]
pub extern "C" fn ms_count() -> usize {
    INDEX.read().unwrap().inv_norms.len()
}

#[unsafe(no_mangle)]
pub extern "C" fn ms_clear() {
    let mut index = INDEX.write().unwrap();
    index.vecs = Vec::new();
    index.inv_norms = Vec::new();
}

/// Embed `n` texts and append them to the index. Text `i` is the UTF-8 bytes
/// `bytes[offsets[i]..offsets[i + 1]]`, so `offsets` holds `n + 1` entries.
///
/// # Safety
/// `offsets` must point to `n + 1` ascending values and `bytes` must be valid
/// for reads up to `offsets[n]`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ms_add(bytes: *const u8, offsets: *const usize, n: usize) {
    if n == 0 {
        return;
    }
    let offsets = unsafe { std::slice::from_raw_parts(offsets, n + 1) };
    let bytes = unsafe { std::slice::from_raw_parts(bytes, offsets[n]) };

    let mut vecs = vec![0i8; n * D];
    let mut inv_norms = vec![0f32; n];
    for start in (0..n).step_by(ENCODE_BATCH) {
        let end = (start + ENCODE_BATCH).min(n);
        let texts = (start..end).map(|i| String::from_utf8_lossy(&bytes[offsets[i]..offsets[i + 1]]));
        let embedded = encoders::encode(texts);
        vecs[start * D..end * D]
            .par_chunks_mut(D)
            .zip(inv_norms[start..end].par_iter_mut())
            .zip(embedded.par_iter())
            .enumerate()
            .for_each(|(i, ((out, inv), v))| {
                let len = (offsets[start + i + 1] - offsets[start + i]) as f32;
                *inv = quantize(v, out) * len / (len + BREVITY_BYTES);
            });
    }

    let mut index = INDEX.write().unwrap();
    index.vecs.extend_from_slice(&vecs);
    index.inv_norms.extend_from_slice(&inv_norms);
}

/// Keep the best `k` of `hits`, best first.
fn keep_top(hits: &mut Vec<(f32, u32)>, k: usize) {
    if hits.len() > k {
        hits.select_nth_unstable_by(k - 1, |a, b| b.0.total_cmp(&a.0));
        hits.truncate(k);
    }
}

/// Find the `k` entries most similar to the query. Writes up to `k` indices
/// (in insertion order, 0-based) and scores (cosine similarity scaled by the
/// brevity prior), best first, and returns how many were written.
///
/// `filter` is either null or one byte per entry; entries whose byte is 0 are
/// skipped.
///
/// # Safety
/// `query` must be valid for `query_len` bytes; `filter`, if not null, for
/// `ms_count()` bytes; `out_indices` and `out_scores` must each have room for
/// `k` entries.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ms_search(
    query: *const u8,
    query_len: usize,
    k: usize,
    filter: *const u8,
    out_indices: *mut u32,
    out_scores: *mut f32,
) -> usize {
    if k == 0 {
        return 0;
    }
    let query = unsafe { std::slice::from_raw_parts(query, query_len) };
    let embedded = encoders::encode_single(String::from_utf8_lossy(query));
    let mut q = [0i8; D];
    let q_inv = quantize(&embedded, &mut q);
    if q_inv == 0.0 {
        return 0;
    }

    let index = INDEX.read().unwrap();
    let filter = (!filter.is_null()).then(|| unsafe { std::slice::from_raw_parts(filter, index.inv_norms.len()) });
    let mut hits = index
        .vecs
        .par_chunks(D * SCAN_ROWS)
        .zip(index.inv_norms.par_chunks(SCAN_ROWS))
        .enumerate()
        .map(|(chunk, (vecs, inv_norms))| {
            let base = (chunk * SCAN_ROWS) as u32;
            let mut local: Vec<(f32, u32)> = Vec::with_capacity(2 * k);
            let mut floor = f32::NEG_INFINITY;
            let allowed = filter.map(|f| &f[chunk * SCAN_ROWS..]);
            for (i, (v, inv)) in vecs.chunks_exact(D).zip(inv_norms).enumerate() {
                if allowed.is_some_and(|f| f[i] == 0) {
                    continue;
                }
                let score = dot(&q, v) as f32 * inv;
                if score > floor {
                    local.push((score, base + i as u32));
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
    drop(index);

    hits.sort_unstable_by(|a, b| b.0.total_cmp(&a.0).then(a.1.cmp(&b.1)));
    let out_indices = unsafe { std::slice::from_raw_parts_mut(out_indices, k) };
    let out_scores = unsafe { std::slice::from_raw_parts_mut(out_scores, k) };
    for (i, (score, idx)) in hits.iter().enumerate() {
        out_indices[i] = *idx;
        out_scores[i] = score * q_inv;
    }
    hits.len()
}

/*
 * boost_dsp.h — RT-safe gain + lookahead peak limiter kernel for Snowball Boost.
 *
 * No allocation after boost_dsp_create(). No locks. Mono Float32 in place.
 */
#ifndef BOOST_DSP_H
#define BOOST_DSP_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BoostDSPState BoostDSPState;

/// The only gain values the product exposes (dB). Any other value passed to
/// boost_dsp_set_gain_db is still accepted (clamped 0...18) but is not part of the UI contract.
enum {
    kBoostGainMinDB = 0,
    kBoostGainMaxDB = 18,
    kBoostGainDefaultDB = 12,
};

/// Snapshot of meter state since the last boost_dsp_reset_meters call (or since creation).
typedef struct {
    float inputPeak;             // linear, 0...
    float inputRMS;               // linear
    float outputPeak;             // linear, post-limiter
    float outputRMS;              // linear, post-limiter
    float maxGainReductionDB;     // 0 = no limiting occurred; positive dB = amount reduced
    uint64_t limitedSampleCount;  // samples where the limiter reduced gain below 1.0
    uint64_t totalSampleCount;
} BoostDSPMeterSnapshot;

/// Creates a kernel instance for the given sample rate (Hz) and limiter ceiling (dBFS, e.g. -1.0).
/// Returns NULL on allocation failure.
BoostDSPState *boost_dsp_create(double sampleRate, float ceilingDBFS);

void boost_dsp_destroy(BoostDSPState *state);

/// Sets target gain in dB; actual applied gain ramps linearly toward this over ~20 ms to avoid
/// zipper noise. Value is clamped to [0, 18].
void boost_dsp_set_gain_db(BoostDSPState *state, float gainDB);

float boost_dsp_current_gain_db(const BoostDSPState *state);

/// Processes frameCount mono Float32 samples. `in` and `out` may be the same buffer.
/// Non-finite inputs (NaN/Inf) are sanitized to 0 before processing; if any are encountered the
/// limiter's internal history is reset to a safe state on that call.
void boost_dsp_process(BoostDSPState *state, const float *in, float *out, size_t frameCount);

/// Converts Int16 PCM to Float32 in [-1, 1], symmetric (both +32767 and -32768 map within range).
void boost_dsp_int16_to_float(const int16_t *in, float *out, size_t frameCount);

BoostDSPMeterSnapshot boost_dsp_get_meters(const BoostDSPState *state);
void boost_dsp_reset_meters(BoostDSPState *state);

#ifdef __cplusplus
}
#endif

#endif /* BOOST_DSP_H */

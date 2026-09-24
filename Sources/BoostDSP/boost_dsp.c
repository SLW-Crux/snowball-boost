#include "boost_dsp.h"

#include <stdlib.h>
#include <string.h>
#include <math.h>

#define MAX_LOOKAHEAD 512u
#define DEQUE_CAP (MAX_LOOKAHEAD + 1u)

typedef struct {
    uint64_t index;
    float value;
} DequeEntry;

struct BoostDSPState {
    double sampleRate;
    float ceilingLinear;

    // gain ramp (zipper-free gain changes)
    float currentGainMult;
    float targetGainMult;
    float gainRampStep;   // magnitude of change applied per sample while ramping
    float rampSamples;    // samples to complete a full ramp (~20 ms)

    // lookahead peak limiter
    size_t lookahead;                 // L, in samples (~1 ms)
    float delayLine[MAX_LOOKAHEAD];
    size_t delayWriteIndex;
    uint64_t sampleCounter;

    DequeEntry deque[DEQUE_CAP];      // monotonic increasing min-deque of required gain
    size_t dequeHead;
    size_t dequeTail;                 // one past the last valid entry
    size_t dequeCount;

    float appliedGain;                // smoothed limiter gain currently in effect (<=1.0)
    float releaseCoeff;                // one-pole release coefficient (~150 ms)

    // meters (accumulate since last reset)
    float inPeak;
    double inSumSq;
    float outPeak;
    double outSumSq;
    float maxGainReductionDB;
    uint64_t limitedSampleCount;
    uint64_t totalSampleCount;
};

BoostDSPState *boost_dsp_create(double sampleRate, float ceilingDBFS) {
    if (!(sampleRate > 0.0)) return NULL;

    BoostDSPState *s = (BoostDSPState *)calloc(1, sizeof(BoostDSPState));
    if (!s) return NULL;

    s->sampleRate = sampleRate;
    s->ceilingLinear = powf(10.0f, ceilingDBFS / 20.0f);

    float defaultMult = powf(10.0f, (float)kBoostGainDefaultDB / 20.0f);
    s->currentGainMult = defaultMult;
    s->targetGainMult = defaultMult;
    s->rampSamples = (float)(0.02 * sampleRate);
    if (s->rampSamples < 1.0f) s->rampSamples = 1.0f;
    s->gainRampStep = 0.0f;

    size_t L = (size_t)lround(sampleRate * 0.001); // 1 ms lookahead
    if (L < 1) L = 1;
    if (L > MAX_LOOKAHEAD) L = MAX_LOOKAHEAD;
    s->lookahead = L;

    s->appliedGain = 1.0f;
    double releaseSeconds = 0.15;
    s->releaseCoeff = (float)exp(-1.0 / (releaseSeconds * sampleRate));

    return s;
}

void boost_dsp_destroy(BoostDSPState *state) {
    free(state);
}

void boost_dsp_set_gain_db(BoostDSPState *state, float gainDB) {
    if (!state) return;
    if (gainDB < (float)kBoostGainMinDB) gainDB = (float)kBoostGainMinDB;
    if (gainDB > (float)kBoostGainMaxDB) gainDB = (float)kBoostGainMaxDB;

    float newTarget = powf(10.0f, gainDB / 20.0f);
    float diff = fabsf(newTarget - state->currentGainMult);
    state->targetGainMult = newTarget;
    state->gainRampStep = diff / state->rampSamples;
}

float boost_dsp_current_gain_db(const BoostDSPState *state) {
    if (!state) return 0.0f;
    return 20.0f * log10f(state->currentGainMult);
}

void boost_dsp_int16_to_float(const int16_t *in, float *out, size_t frameCount) {
    for (size_t i = 0; i < frameCount; i++) {
        out[i] = (float)in[i] / 32768.0f;
    }
}

void boost_dsp_process(BoostDSPState *s, const float *in, float *out, size_t frameCount) {
    if (!s) return;

    for (size_t i = 0; i < frameCount; i++) {
        bool nonFinite = false;
        float x = in[i];
        if (!isfinite(x)) {
            x = 0.0f;
            nonFinite = true;
        }

        float ax = fabsf(x);
        if (ax > s->inPeak) s->inPeak = ax;
        s->inSumSq += (double)x * (double)x;

        // advance gain ramp
        if (s->currentGainMult != s->targetGainMult) {
            float diff = s->targetGainMult - s->currentGainMult;
            if (fabsf(diff) <= s->gainRampStep || s->gainRampStep <= 0.0f) {
                s->currentGainMult = s->targetGainMult;
            } else {
                s->currentGainMult += (diff > 0.0f) ? s->gainRampStep : -s->gainRampStep;
            }
        }

        float y = x * s->currentGainMult;
        if (!isfinite(y)) {
            y = 0.0f;
            nonFinite = true;
        }

        float ay = fabsf(y);
        float r = (ay > s->ceilingLinear) ? (s->ceilingLinear / ay) : 1.0f;
        if (r > 1.0f) r = 1.0f;
        if (r < 0.0f || !isfinite(r)) r = 1.0f;

        if (nonFinite) {
            // Non-finite input observed: wipe limiter history so stale NaN/Inf can never
            // resurface from the delay line or the gain-reduction deque.
            memset(s->delayLine, 0, sizeof(s->delayLine));
            s->dequeHead = s->dequeTail = s->dequeCount = 0;
            s->appliedGain = 1.0f;
            y = 0.0f;
            r = 1.0f;
        }

        uint64_t n = s->sampleCounter++;

        // Maintain a monotonic increasing min-deque of r over the trailing `lookahead` samples.
        while (s->dequeCount > 0) {
            size_t lastSlot = (s->dequeTail + DEQUE_CAP - 1) % DEQUE_CAP;
            if (s->deque[lastSlot].value < r) break;
            s->dequeTail = lastSlot;
            s->dequeCount--;
        }
        s->deque[s->dequeTail].index = n;
        s->deque[s->dequeTail].value = r;
        s->dequeTail = (s->dequeTail + 1) % DEQUE_CAP;
        s->dequeCount++;

        uint64_t windowStart = (n >= (uint64_t)s->lookahead - 1) ? (n - ((uint64_t)s->lookahead - 1)) : 0;
        while (s->dequeCount > 0 && s->deque[s->dequeHead].index < windowStart) {
            s->dequeHead = (s->dequeHead + 1) % DEQUE_CAP;
            s->dequeCount--;
        }

        float desiredGain = (s->dequeCount > 0) ? s->deque[s->dequeHead].value : 1.0f;

        if (desiredGain < s->appliedGain) {
            // Attack: the sliding minimum already ramps smoothly as a peak enters the lookahead
            // window, so following it directly reaches the needed reduction exactly by the peak.
            s->appliedGain = desiredGain;
        } else {
            // Release: ease gain back up over ~150 ms so recovery doesn't pump.
            s->appliedGain += (desiredGain - s->appliedGain) * (1.0f - s->releaseCoeff);
        }

        // Circular delay of `lookahead` samples: emit the oldest stored sample, store the newest.
        float delayed = s->delayLine[s->delayWriteIndex];
        s->delayLine[s->delayWriteIndex] = y;
        s->delayWriteIndex = (s->delayWriteIndex + 1) % s->lookahead;

        float outSample = delayed * s->appliedGain;

        // Final hard clamp: an unconditional guarantee output never exceeds the ceiling,
        // regardless of any floating-point edge case above.
        if (outSample > s->ceilingLinear) outSample = s->ceilingLinear;
        if (outSample < -s->ceilingLinear) outSample = -s->ceilingLinear;
        if (!isfinite(outSample)) outSample = 0.0f;

        out[i] = outSample;

        if (s->appliedGain < 0.999f) {
            s->limitedSampleCount++;
            float safeGain = (s->appliedGain > 1e-9f) ? s->appliedGain : 1e-9f;
            float grDB = -20.0f * log10f(safeGain);
            if (grDB > s->maxGainReductionDB) s->maxGainReductionDB = grDB;
        }
        s->totalSampleCount++;

        float aOut = fabsf(outSample);
        if (aOut > s->outPeak) s->outPeak = aOut;
        s->outSumSq += (double)outSample * (double)outSample;
    }
}

BoostDSPMeterSnapshot boost_dsp_get_meters(const BoostDSPState *s) {
    BoostDSPMeterSnapshot snap;
    memset(&snap, 0, sizeof(snap));
    if (!s) return snap;

    snap.inputPeak = s->inPeak;
    snap.outputPeak = s->outPeak;
    snap.maxGainReductionDB = s->maxGainReductionDB;
    snap.limitedSampleCount = s->limitedSampleCount;
    snap.totalSampleCount = s->totalSampleCount;
    snap.inputRMS = (s->totalSampleCount > 0) ? (float)sqrt(s->inSumSq / (double)s->totalSampleCount) : 0.0f;
    snap.outputRMS = (s->totalSampleCount > 0) ? (float)sqrt(s->outSumSq / (double)s->totalSampleCount) : 0.0f;
    return snap;
}

void boost_dsp_reset_meters(BoostDSPState *s) {
    if (!s) return;
    s->inPeak = 0.0f;
    s->inSumSq = 0.0;
    s->outPeak = 0.0f;
    s->outSumSq = 0.0;
    s->maxGainReductionDB = 0.0f;
    s->limitedSampleCount = 0;
    s->totalSampleCount = 0;
}

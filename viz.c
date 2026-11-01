// lofi-viz — tiny PCM → spectrum helper for the lofi-radio visualizer.
//
// Reads mono signed 16-bit little-endian PCM on stdin (parec feeds it), runs an
// overlapping 1024-point FFT roughly every 12 ms, folds the bins into 12
// log-spaced bands plus an overall energy value, and rewrites a single
// fixed-width line of levels into the file given as argv[1]. The QML widget
// polls that file with FileView.
//
// Updates are written to a sibling temp file and renamed into place, so the
// reader can never observe a half-written line (which shows up as a stutter).
//
// Build: gcc -O2 -o lofi-viz viz.c -lm
#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define FFT_SIZE 1024
#define HOP (FFT_SIZE / 2)
#define BANDS 12
#define RATE 44100.0f

static float re[FFT_SIZE];
static float im[FFT_SIZE];
static float tw_re[FFT_SIZE / 2];
static float tw_im[FFT_SIZE / 2];
static float window[FFT_SIZE];
static int band_edge[BANDS + 1];
static float smooth[BANDS + 1];
static float agc = 0.06f;

static void fft(void) {
  int i, j, k, len, half, step;
  for (i = 1, j = 0; i < FFT_SIZE; i++) {
    int bit = FFT_SIZE >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) {
      float tr = re[i]; re[i] = re[j]; re[j] = tr;
      float ti = im[i]; im[i] = im[j]; im[j] = ti;
    }
  }
  for (len = 2; len <= FFT_SIZE; len <<= 1) {
    half = len >> 1;
    step = FFT_SIZE / len;
    for (i = 0; i < FFT_SIZE; i += len) {
      for (k = 0; k < half; k++) {
        float wr = tw_re[k * step];
        float wi = tw_im[k * step];
        float xr = re[i + k + half];
        float xi = im[i + k + half];
        float vr = xr * wr - xi * wi;
        float vi = xr * wi + xi * wr;
        float ur = re[i + k];
        float ui = im[i + k];
        re[i + k] = ur + vr;
        im[i + k] = ui + vi;
        re[i + k + half] = ur - vr;
        im[i + k + half] = ui - vi;
      }
    }
  }
}

static void write_levels(const char *path, const char *tmp) {
  char line[256];
  int i, fd;
  size_t off = 0;
  for (i = 0; i <= BANDS; i++) {
    off += (size_t)snprintf(line + off, sizeof(line) - off, "%.3f ", smooth[i]);
  }
  line[off++] = '\n';
  fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) return;
  if (write(fd, line, off) != (ssize_t)off) {
    close(fd);
    return;
  }
  close(fd);
  rename(tmp, path);
}

int main(int argc, char **argv) {
  int i, b;
  int16_t samples[FFT_SIZE];
  char tmp[4096];
  const float floor_db = -70.0f;
  const float ceil_db = -10.0f;

  if (argc < 2) {
    fprintf(stderr, "usage: %s <levels-file>\n", argv[0]);
    return 2;
  }
  if (snprintf(tmp, sizeof(tmp), "%s.tmp", argv[1]) >= (int)sizeof(tmp)) {
    fprintf(stderr, "levels path too long\n");
    return 1;
  }

  for (i = 0; i < FFT_SIZE; i++) {
    window[i] = 0.5f - 0.5f * cosf(2.0f * (float)M_PI * i / (FFT_SIZE - 1));
    re[i] = im[i] = 0.0f;
  }
  for (i = 0; i < FFT_SIZE / 2; i++) {
    float a = -2.0f * (float)M_PI * i / FFT_SIZE;
    tw_re[i] = cosf(a);
    tw_im[i] = sinf(a);
  }

  // Log-spaced band edges from 40 Hz to 8 kHz (where lofi actually lives).
  for (b = 0; b <= BANDS; b++) {
    float hz = 40.0f * powf(8000.0f / 40.0f, (float)b / BANDS);
    int bin = (int)lrintf(hz * FFT_SIZE / RATE);
    if (bin < 1) bin = 1;
    if (bin > FFT_SIZE / 2 - 1) bin = FFT_SIZE / 2 - 1;
    if (b > 0 && bin <= band_edge[b - 1]) bin = band_edge[b - 1] + 1;
    band_edge[b] = bin;
  }
  for (b = 0; b <= BANDS; b++) smooth[b] = 0.0f;

  // Prime the sliding window.
  {
    size_t have = fread(samples, sizeof(int16_t), FFT_SIZE, stdin);
    if (have < FFT_SIZE) memset(samples + have, 0, (FFT_SIZE - have) * sizeof(int16_t));
    if (have == 0) {
      write_levels(argv[1], tmp);
      return 0;
    }
  }

  for (;;) {
    for (i = 0; i < FFT_SIZE; i++) {
      re[i] = ((float)samples[i] / 32768.0f) * window[i];
      im[i] = 0.0f;
    }
    fft();

    float total = 0.0f;
    float peak = 0.0f;
    for (b = 0; b < BANDS; b++) {
      int lo = band_edge[b];
      int hi = band_edge[b + 1];
      float sum = 0.0f;
      int count = 0;
      int k;
      if (hi <= lo) hi = lo + 1;
      for (k = lo; k < hi && k <= FFT_SIZE / 2; k++) {
        sum += re[k] * re[k] + im[k] * im[k];
        count++;
      }
      float mag = sqrtf(sum / (count > 0 ? count : 1)) / (FFT_SIZE * 0.25f);
      float db = 20.0f * log10f(mag + 1e-9f);
      // Lift the highs a little: music energy falls off with frequency.
      db += b * 2.0f;
      float level = (db - floor_db) / (ceil_db - floor_db);
      if (level < 0.0f) level = 0.0f;
      if (level > 2.0f) level = 2.0f;
      // Meter ballistics: quick but not instant attack, gentle release. At
      // ~86 frames/s these give ~25 ms rise and ~160 ms fall, which reads as
      // motion instead of flicker.
      if (level > smooth[b]) smooth[b] += (level - smooth[b]) * 0.45f;
      else smooth[b] += (level - smooth[b]) * 0.08f;
      if (smooth[b] > peak) peak = smooth[b];
      total += smooth[b];
    }

    // Automatic gain: track the loudest band so the meter keeps using the full
    // height regardless of the stream's level. Instant attack, slow release
    // (~1 s) reads like a compressor instead of a flicker; the gain cap stops
    // near-silence from blowing up into noise.
    if (peak > agc) agc = peak;
    else agc += (peak - agc) * 0.008f;
    if (agc < 0.06f) agc = 0.06f;
    float gain = 1.0f / agc;
    if (gain > 4.0f) gain = 4.0f;

    for (b = 0; b < BANDS; b++) {
      float v = smooth[b] * gain;
      if (v < 0.0f) v = 0.0f;
      if (v > 1.0f) v = 1.0f;
      smooth[b] = v;
    }
    smooth[BANDS] = total / BANDS;

    write_levels(argv[1], tmp);

    // Slide the window forward by half a frame and block for the next hop.
    memmove(samples, samples + HOP, (FFT_SIZE - HOP) * sizeof(int16_t));
    size_t got = fread(samples + FFT_SIZE - HOP, sizeof(int16_t), HOP, stdin);
    if (got < HOP) {
      memset(samples + FFT_SIZE - HOP + got, 0,
             (HOP - got) * sizeof(int16_t));
      if (got == 0) break;
    }
  }

  for (i = 0; i <= BANDS; i++) smooth[i] = 0.0f;
  write_levels(argv[1], tmp);
  return 0;
}

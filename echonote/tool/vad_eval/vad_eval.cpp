// Compares voice activity detectors on a 16 kHz mono WAV, 100 ms at a time
// (the chunk size of a live recording in echonote):
//
//   energy  echo_core's ec_vad (same algorithm as the gate in whisper_ggml's
//           live stream) — the current behavior, as the baseline
//   silero  whisper.cpp's built-in Silero VAD, streaming (LSTM state kept
//           across chunks)
//
// With a label file (speech intervals, one "start end" pair in seconds per
// line, '#' comments), it scores each detector per 100 ms chunk:
// speech recall and non-speech false-positive rate.
//
// usage: vad_eval <silero-model.bin> <audio.wav> [labels.txt] [--csv]

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#define DR_WAV_IMPLEMENTATION
#include "dr_wav.h"
#include "echo_core.h"
#include "whisper.h"

static const int kRate = 16000;
static const int kChunk = 1600;  // 100 ms
static const float kSileroThreshold = 0.5f;

struct Score {
    int speech = 0, speech_hit = 0, silence = 0, silence_hit = 0;
    double us = 0;
    void add(bool truth, bool decided) {
        if (truth) { ++speech; speech_hit += decided; }
        else { ++silence; silence_hit += decided; }
    }
};

static std::vector<std::pair<double, double>> read_labels(const char *path) {
    std::vector<std::pair<double, double>> out;
    std::ifstream in(path);
    std::string line;
    while (std::getline(in, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::istringstream ss(line);
        double a, b;
        if (ss >> a >> b) out.push_back({a, b});
    }
    return out;
}

// A chunk counts as speech when its midpoint falls inside a labeled interval.
static bool labeled_speech(const std::vector<std::pair<double, double>> &labels, int chunk) {
    const double mid = (chunk + 0.5) * kChunk / kRate;
    for (const auto &l : labels) {
        if (mid >= l.first && mid < l.second) return true;
    }
    return false;
}

static void print_score(const char *name, const Score &s, int chunks) {
    std::printf("%-7s", name);
    if (s.speech + s.silence > 0) {
        std::printf("  recall %5.1f%% (%d/%d)  false-pos %5.1f%% (%d/%d)",
                    s.speech ? 100.0 * s.speech_hit / s.speech : 0.0, s.speech_hit, s.speech,
                    s.silence ? 100.0 * s.silence_hit / s.silence : 0.0, s.silence_hit,
                    s.silence);
    }
    std::printf("  %.1f us/chunk\n", s.us / chunks);
}

int main(int argc, char **argv) {
    if (argc < 3) {
        std::fprintf(stderr, "usage: %s <silero-model.bin> <audio.wav> [labels.txt] [--csv]\n",
                     argv[0]);
        return 2;
    }
    const char *model = argv[1];
    const char *wav_path = argv[2];
    const char *labels_path = nullptr;
    bool csv = false;
    for (int i = 3; i < argc; ++i) {
        if (std::strcmp(argv[i], "--csv") == 0) csv = true;
        else labels_path = argv[i];
    }

    drwav wav;
    if (!drwav_init_file(&wav, wav_path, nullptr)) {
        std::fprintf(stderr, "cannot open %s\n", wav_path);
        return 1;
    }
    if (wav.sampleRate != kRate || wav.channels != 1) {
        std::fprintf(stderr, "need 16 kHz mono, got %u Hz x %u\n", wav.sampleRate, wav.channels);
        return 1;
    }
    std::vector<int16_t> pcm(wav.totalPCMFrameCount);
    drwav_read_pcm_frames_s16(&wav, pcm.size(), pcm.data());
    drwav_uninit(&wav);

    const auto labels = labels_path ? read_labels(labels_path) : decltype(read_labels("")){};

    whisper_log_set([](ggml_log_level, const char *, void *) {}, nullptr);
    whisper_vad_context_params cparams = whisper_vad_default_context_params();
    cparams.n_threads = 1;
    whisper_vad_context *silero = whisper_vad_init_from_file_with_params(model, cparams);
    if (!silero) {
        std::fprintf(stderr, "cannot load %s\n", model);
        return 1;
    }
    ec_vad *energy = ec_vad_create(ec_vad_default_config());

    // Silero runs on fixed 512-sample windows; samples left over from one
    // chunk carry into the next so no window is zero-padded mid-stream.
    const int window = 512;
    std::vector<float> pending;
    bool silero_voiced = false;

    Score e_score, s_score;
    const int chunks = (int)(pcm.size() / kChunk);
    if (csv) std::printf("t_sec,label,energy,silero,silero_max_prob\n");
    for (int c = 0; c < chunks; ++c) {
        const int16_t *in = pcm.data() + (size_t)c * kChunk;

        auto t0 = std::chrono::steady_clock::now();
        const bool e = ec_vad_process(energy, in, kChunk) == 1;
        auto t1 = std::chrono::steady_clock::now();

        for (int i = 0; i < kChunk; ++i) pending.push_back(in[i] / 32768.0f);
        const int usable = (int)pending.size() / window * window;
        float max_prob = 0;
        if (usable > 0) {
            whisper_vad_detect_speech_no_reset(silero, pending.data(), usable);
            const float *probs = whisper_vad_probs(silero);
            for (int i = 0; i < whisper_vad_n_probs(silero); ++i) {
                max_prob = std::fmax(max_prob, probs[i]);
            }
            pending.erase(pending.begin(), pending.begin() + usable);
            silero_voiced = max_prob >= kSileroThreshold;
        }
        auto t2 = std::chrono::steady_clock::now();

        e_score.us += std::chrono::duration<double, std::micro>(t1 - t0).count();
        s_score.us += std::chrono::duration<double, std::micro>(t2 - t1).count();
        const bool truth = labeled_speech(labels, c);
        if (labels_path) {
            e_score.add(truth, e);
            s_score.add(truth, silero_voiced);
        }
        if (csv) {
            std::printf("%.1f,%d,%d,%d,%.3f\n", (double)c * kChunk / kRate, labels_path ? truth : -1,
                        e, silero_voiced, max_prob);
        }
    }

    if (!csv) {
        std::printf("%s: %.1f s, %d chunks\n", wav_path, (double)pcm.size() / kRate, chunks);
        print_score("energy", e_score, chunks);
        print_score("silero", s_score, chunks);
    }
    ec_vad_destroy(energy);
    whisper_vad_free(silero);
    return 0;
}

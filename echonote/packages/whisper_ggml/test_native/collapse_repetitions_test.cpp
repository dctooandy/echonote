// [echonote] Checks ios/Classes/collapse_repetitions.h against the fixture
// the Dart side uses (lib/services/repetition.dart), so both stay in step.
// Run from the app root (echonote/):
//   clang++ -std=c++17 -I packages/whisper_ggml/ios/Classes \
//     packages/whisper_ggml/test_native/collapse_repetitions_test.cpp \
//     -o /tmp/collapse_test && /tmp/collapse_test test/fixtures/repetition_cases.json
#include "collapse_repetitions.h"
#include "json/json.hpp"

#include <cstdio>
#include <fstream>

using json = nlohmann::json;
using echonote::append_collapsed;
using echonote::collapse_repetitions;

static int failures = 0;

static void expect(bool ok, const std::string &name, const std::string &detail) {
    std::printf("%s %s\n", ok ? "PASS" : "FAIL", name.c_str());
    if (!ok) {
        std::printf("     %s\n", detail.c_str());
        failures++;
    }
}

int main(int argc, char **argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s <repetition_cases.json>\n", argv[0]);
        return 2;
    }
    std::ifstream in(argv[1]);
    const json fixture = json::parse(in);

    for (const auto &c : fixture["cases"]) {
        const auto name = c["name"].get<std::string>();
        const auto r = collapse_repetitions(c["input"].get<std::string>());
        const auto want = c["output"].get<std::string>();
        const int want_n = c["collapsed"].get<int>();
        expect(r.text == want && r.collapsed == want_n, name,
               "got [" + std::to_string(r.collapsed) + "] " + r.text + "\n     want [" +
                   std::to_string(want_n) + "] " + want);
    }

    // A loop straddling a commit: the tail of what's committed counts.
    {
        const auto r = append_collapsed("開場白。經常經常", "經常經常經常，下一句");
        expect(r.text == "開場白。經常，下一句" && r.collapsed == 1, "loop across a commit",
               "got [" + std::to_string(r.collapsed) + "] " + r.text);
    }
    // Text before the 40-character tail is never touched.
    {
        // 42 characters with no loop of their own push the old loop out of the tail.
        const std::string old_loop = std::string("好好好好") + "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOP";
        const auto r = append_collapsed(old_loop, "。");
        expect(r.text.rfind("好好好好", 0) == 0, "committed text outside the tail is kept",
               "got " + r.text.substr(0, 30));
    }
    // Malformed UTF-8 doesn't throw.
    {
        const auto r = collapse_repetitions(std::string("ab\xE4\xB8", 4));
        expect(r.collapsed == 0, "malformed UTF-8 is tolerated", r.text);
    }

    std::printf("%d failure(s)\n", failures);
    return failures == 0 ? 0 : 1;
}

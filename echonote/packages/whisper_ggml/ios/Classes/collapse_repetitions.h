// [echonote] Collapsing the repetition loops `tiny` falls into during live
// preview ("經常經常經常…", "Helps,Helps,…"). With temperature fallback off,
// nothing in whisper stops a loop; it runs to the token limit and, once a
// window is committed, stays in the preview for good. The app applies the
// same rules on the Dart side (lib/services/repetition.dart); both are
// checked against test/fixtures/repetition_cases.json, so keep them in step.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace echonote {

constexpr int kRepetitionMinUnit = 1;
constexpr int kRepetitionMaxUnit = 10;
constexpr int kRepetitionMinRepeats = 4;

// Whitespace and punctuation between repeats don't break a loop. The same
// explicit ranges as isRepetitionSeparator() on the Dart side.
inline bool is_repetition_separator(uint32_t cp) {
    return cp <= 0x20 ||
           (cp >= 0x21 && cp <= 0x2F) ||
           (cp >= 0x3A && cp <= 0x40) ||
           (cp >= 0x5B && cp <= 0x60) ||
           (cp >= 0x7B && cp <= 0x7E) ||
           (cp >= 0x2010 && cp <= 0x2027) ||
           (cp >= 0x3000 && cp <= 0x303F) ||
           (cp >= 0xFF01 && cp <= 0xFF0F) ||
           (cp >= 0xFF1A && cp <= 0xFF20) ||
           (cp >= 0xFF3B && cp <= 0xFF40) ||
           (cp >= 0xFF5B && cp <= 0xFF65);
}

// Lenient UTF-8 decoding: whisper can split a multi-byte character across
// tokens, so a malformed byte becomes U+FFFD instead of failing.
inline std::vector<uint32_t> utf8_decode(const std::string &s) {
    std::vector<uint32_t> out;
    out.reserve(s.size());
    size_t i = 0;
    while (i < s.size()) {
        const unsigned char c = (unsigned char)s[i];
        int len = c < 0x80 ? 1 : (c >> 5) == 0x6 ? 2 : (c >> 4) == 0xE ? 3 : (c >> 3) == 0x1E ? 4 : 0;
        if (len == 0 || i + len > s.size()) {
            out.push_back(0xFFFD);
            i++;
            continue;
        }
        uint32_t cp = len == 1 ? c : len == 2 ? (c & 0x1F) : len == 3 ? (c & 0x0F) : (c & 0x07);
        bool ok = true;
        for (int k = 1; k < len; k++) {
            const unsigned char cc = (unsigned char)s[i + k];
            if ((cc >> 6) != 0x2) { ok = false; break; }
            cp = (cp << 6) | (cc & 0x3F);
        }
        if (!ok) {
            out.push_back(0xFFFD);
            i++;
            continue;
        }
        out.push_back(cp);
        i += len;
    }
    return out;
}

inline void utf8_append(std::string &out, uint32_t cp) {
    if (cp < 0x80) {
        out += (char)cp;
    } else if (cp < 0x800) {
        out += (char)(0xC0 | (cp >> 6));
        out += (char)(0x80 | (cp & 0x3F));
    } else if (cp < 0x10000) {
        out += (char)(0xE0 | (cp >> 12));
        out += (char)(0x80 | ((cp >> 6) & 0x3F));
        out += (char)(0x80 | (cp & 0x3F));
    } else {
        out += (char)(0xF0 | (cp >> 18));
        out += (char)(0x80 | ((cp >> 12) & 0x3F));
        out += (char)(0x80 | ((cp >> 6) & 0x3F));
        out += (char)(0x80 | (cp & 0x3F));
    }
}

inline std::string utf8_encode(const std::vector<uint32_t> &cps, size_t from, size_t to) {
    std::string out;
    for (size_t i = from; i < to; i++) utf8_append(out, cps[i]);
    return out;
}

struct CollapseResult {
    std::string text;
    int collapsed = 0;
};

// Every loop (a unit of kRepetitionMinUnit–kRepetitionMaxUnit code points
// repeated kRepetitionMinRepeats+ times in a row, separators ignored) cut
// down to its first occurrence; everything else kept as is.
inline CollapseResult collapse_repetitions(const std::string &text) {
    const std::vector<uint32_t> runes = utf8_decode(text);
    std::vector<uint32_t> core;
    std::vector<size_t> at;
    for (size_t i = 0; i < runes.size(); i++) {
        if (is_repetition_separator(runes[i])) continue;
        core.push_back(runes[i]);
        at.push_back(i);
    }

    auto same_unit = [&](size_t a, size_t b, size_t len) {
        for (size_t k = 0; k < len; k++) {
            if (core[a + k] != core[b + k]) return false;
        }
        return true;
    };

    CollapseResult result;
    size_t copied_up_to = 0;
    size_t i = 0;
    while (i < core.size()) {
        size_t unit = 0, repeats = 0;
        for (size_t u = kRepetitionMinUnit; u <= (size_t)kRepetitionMaxUnit; u++) {
            if (i + u * kRepetitionMinRepeats > core.size()) break;
            size_t r = 1;
            while (i + u * (r + 1) <= core.size() && same_unit(i, i + u * r, u)) r++;
            if (r >= (size_t)kRepetitionMinRepeats) {
                unit = u;
                repeats = r;
                break;
            }
        }
        if (unit == 0) {
            i++;
            continue;
        }
        const size_t first_end = at[i + unit - 1] + 1;
        const size_t loop_end = at[i + unit * repeats - 1] + 1;
        result.text += utf8_encode(runes, copied_up_to, first_end);
        copied_up_to = loop_end;
        result.collapsed++;
        i += unit * repeats;
    }
    result.text += utf8_encode(runes, copied_up_to, runes.size());
    return result;
}

// Appends [text] to [committed], collapsing loops in the new text together
// with the last [context] code points already committed, so a loop that
// straddles a commit is caught too. Text before that tail is left alone.
inline CollapseResult append_collapsed(const std::string &committed, const std::string &text,
                                       size_t context = 40) {
    const std::vector<uint32_t> head = utf8_decode(committed);
    const size_t split = head.size() > context ? head.size() - context : 0;
    CollapseResult tail = collapse_repetitions(utf8_encode(head, split, head.size()) + text);
    tail.text = utf8_encode(head, 0, split) + tail.text;
    return tail;
}

}  // namespace echonote

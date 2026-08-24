#include "parser.h"

namespace ffmpegpp {

std::vector<std::string> splitCommand(const std::string& cmd) {
    std::vector<std::string> tokens;
    std::string current;
    bool inQuote = false;
    char quoteChar = 0;

    for (size_t i = 0; i < cmd.size(); ++i) {
        char c = cmd[i];
        if (inQuote) {
            if (c == quoteChar) { inQuote = false; }
            else { current += c; }
        } else if (c == '"' || c == '\'') {
            inQuote = true;
            quoteChar = c;
        } else if (c == ' ' || c == '\t') {
            if (!current.empty()) { tokens.push_back(current); current.clear(); }
        } else {
            current += c;
        }
    }
    if (!current.empty()) tokens.push_back(current);
    return tokens;
}

} // namespace ffmpegpp

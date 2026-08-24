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
            // 支持引号内转义：\" 或 \'
            if (c == '\\' && i + 1 < cmd.size() && (cmd[i + 1] == quoteChar || cmd[i + 1] == '\\')) {
                current += cmd[i + 1];
                ++i;  // 跳过被转义的字符
            } else if (c == quoteChar) {
                inQuote = false;
            } else {
                current += c;
            }
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

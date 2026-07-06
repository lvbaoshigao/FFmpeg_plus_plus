#include "parser.h"
#include "constants.h"
#include <sstream>
#include <map>

namespace ffmpegpp {

namespace {
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

bool isParam(const std::string& token) {
    return !token.empty() && token[0] == '-';
}
} // namespace

json explainCommand(const std::string& command_str) {
    if (command_str.empty()) {
        return {{"success", false}, {"explanations", json::array()}, {"categories", json::object()}, {"error", "命令为空"}};
    }

    auto tokens = splitCommand(command_str);
    if (tokens.empty()) {
        return {{"success", false}, {"explanations", json::array()}, {"categories", json::object()}, {"error", "命令中未找到有效参数"}};
    }

    // 跳过 ffmpeg（可能是裸名或完整路径）
    if (!tokens.empty() && tokens[0].find("ffmpeg") != std::string::npos) tokens.erase(tokens.begin());

    // 提取输出文件
    std::string output_file;
    if (!tokens.empty() && !isParam(tokens.back())) {
        output_file = tokens.back();
        tokens.pop_back();
    }

    json explanations = json::array();
    for (size_t i = 0; i < tokens.size(); ++i) {
        if (!isParam(tokens[i])) continue;

        std::string param = tokens[i];
        std::string value;
        if (i + 1 < tokens.size() && !isParam(tokens[i + 1])) {
            value = tokens[i + 1];
            ++i;
        }

        json exp;
        exp["param"] = param;
        exp["value"] = value;

        auto it = FFMPEG_PARAMS_DESCRIPTION.find(param);
        if (it != FFMPEG_PARAMS_DESCRIPTION.end()) {
            exp["name"] = it->second.name;
            exp["category"] = it->second.category;
            exp["description"] = it->second.desc;
        } else {
            exp["name"] = "未知参数";
            exp["category"] = "其他";
            exp["description"] = "参数 '" + param + "' 未收录在参数库中";
        }
        explanations.push_back(exp);
    }

    // 追加输出文件
    if (!output_file.empty()) {
        explanations.push_back({
            {"param", "(output)"},
            {"value", output_file},
            {"name", "输出文件"},
            {"category", "输入/输出"},
            {"description", "输出文件路径"},
        });
    }

    // 按 category 分组
    json categories = json::object();
    for (auto& exp : explanations) {
        std::string cat = exp["category"].get<std::string>();
        if (!categories.contains(cat)) categories[cat] = json::array();
        categories[cat].push_back(exp);
    }

    return {{"success", true}, {"explanations", explanations}, {"categories", categories}, {"error", nullptr}};
}

std::string formatExplanations(const json& result) {
    if (!result["success"].get<bool>()) {
        return "解析失败: " + result.value("error", "");
    }

    std::ostringstream oss;
    oss << "============================================================\n";
    oss << "FFmpeg 命令解析结果（共 " << result["explanations"].size() << " 个参数）\n";
    oss << "============================================================\n";

    auto& categories = result["categories"];
    for (auto& [cat, items] : categories.items()) {
        oss << "\n▎" << cat << "\n";
        oss << "----------------------------------------\n";
        for (auto& item : items) {
            std::string param = item["param"].get<std::string>();
            std::string value = item.value("value", "");
            if (!value.empty()) oss << "  " << param << " " << value << "\n";
            else oss << "  " << param << "\n";
            oss << "    → " << item["description"].get<std::string>() << "\n";
        }
    }
    return oss.str();
}

} // namespace ffmpegpp

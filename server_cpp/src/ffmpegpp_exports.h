#pragma once

#ifdef FFMPEGPP_BUILDING_DLL
  #define FFMPEGPP_API __declspec(dllexport)
#else
  #define FFMPEGPP_API __declspec(dllimport)
#endif

extern "C" {
    // 启动工作线程，返回 0 表示成功
    FFMPEGPP_API int ffmpegpp_init();

    // 推送 JSON 请求（UTF-8），返回 0 表示成功
    FFMPEGPP_API int ffmpegpp_request(const char* json_utf8);

    // 非阻塞取下一条 JSON 响应，无数据时返回 NULL
    // 调用者必须用 ffmpegpp_free 释放返回的字符串
    FFMPEGPP_API char* ffmpegpp_poll();

    // 释放 ffmpegpp_poll 返回的字符串
    FFMPEGPP_API void ffmpegpp_free(char* ptr);

    // 关闭工作线程
    FFMPEGPP_API void ffmpegpp_shutdown();
}

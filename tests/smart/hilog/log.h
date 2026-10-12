// Host-only compile stub. No claim of OHOS logging or TLS behavior.
#pragma once
#define LOG_APP 0
#define LOG_DEBUG 0
#define LOG_INFO 0
#define LOG_WARN 0
#define LOG_ERROR 0
inline void OH_LOG_Print(int, int, int, const char*, const char*, ...) {}

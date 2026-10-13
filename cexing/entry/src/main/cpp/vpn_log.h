/*
 * vpn_log.h - native 层统一日志宏
 *
 * 全项目 hilog 约定: domain=0x3200, tag 前缀 CEXING（NAPI 桥）/ mihomo（Go 内核）
 * 过滤命令: hdc shell "hilog -D 0x3200" 或 hdc shell "hilog | grep mihomo"
 */
#ifndef CEXING_LOG_H
#define CEXING_LOG_H

#include <hilog/log.h>

#define CEXING_LOG_DOMAIN 0x3200
#define CEXING_LOG_TAG "CEXING-NAPI"

#define VPN_LOGD(fmt, ...) OH_LOG_Print(LOG_APP, LOG_DEBUG, CEXING_LOG_DOMAIN, CEXING_LOG_TAG, fmt, ##__VA_ARGS__)
#define VPN_LOGI(fmt, ...) OH_LOG_Print(LOG_APP, LOG_INFO,  CEXING_LOG_DOMAIN, CEXING_LOG_TAG, fmt, ##__VA_ARGS__)
#define VPN_LOGW(fmt, ...) OH_LOG_Print(LOG_APP, LOG_WARN,  CEXING_LOG_DOMAIN, CEXING_LOG_TAG, fmt, ##__VA_ARGS__)
#define VPN_LOGE(fmt, ...) OH_LOG_Print(LOG_APP, LOG_ERROR, CEXING_LOG_DOMAIN, CEXING_LOG_TAG, fmt, ##__VA_ARGS__)

#endif

#pragma once

/* Compile-time selector for the two native-window backends. Their
 * implementations and public headers remain completely separate. */
#ifdef _WIN32
#include "webxdc_windows.h"
#define parla_webxdc_open        parla_webxdc_win_open
#define parla_webxdc_load        parla_webxdc_win_load
#define parla_webxdc_finish_task parla_webxdc_win_finish_task
#define parla_webxdc_fail_task   parla_webxdc_win_fail_task
#define parla_webxdc_eval_js     parla_webxdc_win_eval_js
#define parla_webxdc_set_title   parla_webxdc_win_set_title
#define parla_webxdc_present     parla_webxdc_win_present
#define parla_webxdc_minimize    parla_webxdc_win_minimize
#define parla_webxdc_set_visible parla_webxdc_win_set_visible
#define parla_webxdc_close       parla_webxdc_win_close
#define parla_webxdc_free        parla_webxdc_win_free
#else
#include "webxdc_macos.h"
#endif

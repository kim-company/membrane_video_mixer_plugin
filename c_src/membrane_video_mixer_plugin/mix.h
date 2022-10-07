#pragma once

#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libavutil/parseutils.h>
#include <stdio.h>

typedef struct InOutCtx
{
    AVFilterContext *buffer_ctx;
    int width;
    int height;
    int pixel_format;
} InOutCtx;

typedef struct VfilterState
{
    AVFilterGraph *filter_graph;
    InOutCtx *in_ctx;
    InOutCtx out_ctx;
    int inputs_count;
} State;

#include "_generated/mix.h"
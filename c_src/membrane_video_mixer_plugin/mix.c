#include "mix.h"

static int get_pixel_format(char *fmt_name);
static int init_filters(const char *filters_descr, State *state);

UNIFEX_TERM init(UnifexEnv *env, int *width, unsigned int width_length, int *height, unsigned int height_length, char **pixel_format, unsigned int pixel_format_length, char *filter, int out_width, int out_height, char *out_format)
{
    UNIFEX_TERM result;
    State *state = unifex_alloc_state(env);

    // check if all arrays have the same length
    int inputs_count = width_length;
    if (width_length != height_length || width_length != pixel_format_length)
    {
        result = init_result_error(env, "unmatching array lengths");
        goto exit_create;
    }

    state->inputs_count = inputs_count;
    state->in_ctx = (InOutCtx *)unifex_alloc(inputs_count * sizeof(InOutCtx)); // needs to be freed

    // initialize all the input configs
    for (int i = 0; i < inputs_count; i++)
    {
        state->in_ctx[i].width = width[i];
        state->in_ctx[i].height = height[i];
        int pix_fmt = get_pixel_format(pixel_format[i]);
        if (pix_fmt < 0)
        {
            result = init_result_error(env, "unsupported_in_pixel_format");
            goto exit_create;
        }
        state->in_ctx[i].pixel_format = pix_fmt;
    }

    // initialize the output config
    state->out_ctx.width = out_width;
    state->out_ctx.height = out_height;

    int out_pix_fmt = get_pixel_format(out_format);
    if (out_pix_fmt < 0)
    {
        result = init_result_error(env, "unsupported_out_pixel_format");
        goto exit_create;
    }
    state->out_ctx.pixel_format = out_pix_fmt;

    // initialize the filtergraph
    if (init_filters(filter, state) < 0)
    {
        result = init_result_error(env, "error_initializing_filters");
        goto exit_create;
    }

    result = init_result_ok(env, state);

exit_create:
    unifex_release_state(env, state);
    return result;
}

UNIFEX_TERM mix(UnifexEnv *env, UnifexPayload **payload, uint32_t buffers_length, State *state)
{
    if ((int)buffers_length != state->inputs_count)
        return mix_result_error(env, "buffer_length_mismatch_with_state");

    // allocations
    UNIFEX_TERM result;
    int return_code;
    AVFrame **frame = (AVFrame **)av_calloc(state->inputs_count, sizeof(AVFrame *));

    // output frame
    AVFrame *filtered_frame = av_frame_alloc();
    if (!filtered_frame)
    {
        result = mix_result_error(env, "error_allocating_frame");
        goto exit_filter;
    }

    // input frames
    for (int i = 0; i < state->inputs_count; i++)
    {
        frame[i] = av_frame_alloc();
        if (!frame[i])
        {
            result = mix_result_error(env, "error_allocating_frame");
            goto exit_filter;
        }
        frame[i]->format = state->in_ctx[i].pixel_format;
        frame[i]->width = state->in_ctx[i].width;
        frame[i]->height = state->in_ctx[i].height;
        return_code = av_image_fill_arrays(frame[i]->data, frame[i]->linesize, payload[i]->data,
                                           frame[i]->format, frame[i]->width, frame[i]->height, 1);
        if (return_code < 0)
        {
            result = mix_result_error(env, "error_filling_frame");
            goto exit_filter;
        }

        // feed the filtergraph
        if (av_buffersrc_add_frame_flags(state->in_ctx[i].buffer_ctx, frame[i],
                                         AV_BUFFERSRC_FLAG_KEEP_REF) < 0)
        {
            result = mix_result_error(env, "error_feeding_filtergraph");
            goto exit_filter;
        }
    }

    // pull filtered frame from the filtergraph
    return_code = av_buffersink_get_frame(state->out_ctx.buffer_ctx, filtered_frame);
    if (return_code < 0)
    {
        result = mix_result_error(env, "error_pulling_from_filtergraph");
        goto exit_filter;
    }

    UnifexPayload payload_frame;
    size_t payload_size = av_image_get_buffer_size(
        filtered_frame->format, filtered_frame->width, filtered_frame->height, 1);
    unifex_payload_alloc(env, UNIFEX_PAYLOAD_BINARY, payload_size,
                         &payload_frame);

    if (av_image_copy_to_buffer(payload_frame.data, payload_size,
                                (const uint8_t *const *)filtered_frame->data,
                                filtered_frame->linesize, filtered_frame->format,
                                filtered_frame->width, filtered_frame->height,
                                1) < 0)
    {
        result = mix_result_error(env, "copy_to_payload");
        goto exit_filter;
    }

    result = mix_result_ok(env, &payload_frame);

exit_filter:
    for (int i = 0; i < state->inputs_count; i++)
        if (frame[i] != NULL)
            av_frame_free(&frame[i]);
    if (filtered_frame != NULL)
        av_frame_free(&filtered_frame);
    if (frame != NULL)
        av_free(frame);
    return result;
}

static int get_pixel_format(char *fmt_name)
{
    int pix_fmt = -1;
    if (strcmp(fmt_name, "I420") == 0)
    {
        pix_fmt = AV_PIX_FMT_YUV420P;
    }
    else if (strcmp(fmt_name, "I422") == 0)
    {
        pix_fmt = AV_PIX_FMT_YUV422P;
    }
    else if (strcmp(fmt_name, "I444") == 0)
    {
        pix_fmt = AV_PIX_FMT_YUV444P;
    }
    return pix_fmt;
}
static int init_filters(const char *filters, State *state)
{
    // allocations
    int return_code;
    enum AVPixelFormat out_pix_fmts[] = {state->out_ctx.pixel_format, AV_PIX_FMT_NONE};
    AVFilterInOut **outputs = av_calloc(state->inputs_count, sizeof(AVFilterInOut));

    // init the graph
    state->filter_graph = avfilter_graph_alloc();

    // create output
    const AVFilter *buffersink = avfilter_get_by_name("buffersink");
    AVFilterInOut *inputs = avfilter_inout_alloc();

    // initialize the buffersink
    return_code = avfilter_graph_create_filter(&state->out_ctx.buffer_ctx, buffersink, "out",
                                               NULL, NULL, state->filter_graph);
    if (return_code < 0)
    {
        av_log(NULL, AV_LOG_ERROR, "Cannot create buffer sink\n");
        goto exit_init_filter;
    }

    // set pixel format
    return_code = av_opt_set_int_list(state->out_ctx.buffer_ctx, "pix_fmts", out_pix_fmts,
                                      AV_PIX_FMT_NONE, AV_OPT_SEARCH_CHILDREN);
    if (return_code < 0)
    {
        av_log(NULL, AV_LOG_ERROR, "Cannot set output pixel format\n");
        goto exit_init_filter;
    }

    // fill output (somehow inputs and outputs are inverted)
    inputs->name = av_strdup("out");
    inputs->filter_ctx = state->out_ctx.buffer_ctx;
    inputs->pad_idx = 0;
    inputs->next = NULL;

    // error if allocations were unsuccessful
    if (!buffersink || !inputs || !state->filter_graph)
    {
        return_code = AVERROR(ENOMEM);
        goto exit_init_filter;
    }

    // create inputs
    for (int i = state->inputs_count - 1; i >= 0; i--)
    {
        // input filter
        char args[512];
        snprintf(args, sizeof(args), "video_size=%dx%d:pix_fmt=%d:time_base=1/1",
                 state->in_ctx[i].width, state->in_ctx[i].height, state->in_ctx[i].pixel_format);

        char *name;
        // name memory needs to be freed
        asprintf(&name, "%d:v", i);

        // initialize and fill the input[i]
        outputs[i] = avfilter_inout_alloc();

        // link a buffersrc for each input
        const AVFilter *buffersrc = avfilter_get_by_name("buffer");
        if (!buffersrc)
        {
            return_code = AVERROR(ENOMEM);
            free(name);
            goto exit_init_filter;
        }
        return_code = avfilter_graph_create_filter(&state->in_ctx[i].buffer_ctx, buffersrc, "in",
                                                   args, NULL, state->filter_graph);
        if (return_code < 0)
        {
            av_log(NULL, AV_LOG_ERROR, "Cannot create buffer src nr. %d\n", i);
            free(name);
            goto exit_init_filter;
        }

        outputs[i]->name = av_strdup(name);
        outputs[i]->filter_ctx = state->in_ctx[i].buffer_ctx;
        outputs[i]->pad_idx = 0;
        if (i == state->inputs_count - 1)
            outputs[i]->next = NULL;

        else
            outputs[i]->next = outputs[i + 1];

        free(name);
    }

    // build the final graph with the given filters
    return_code = avfilter_graph_parse_ptr(state->filter_graph, av_strdup(filters),
                                           &inputs, outputs, NULL);
    if (return_code < 0)
    {
        av_log(NULL, AV_LOG_ERROR, "Cannot create graph\n");
        goto exit_init_filter;
    }

    // configure the final graph
    return_code = avfilter_graph_config(state->filter_graph, NULL);
    if (return_code < 0)
        av_log(NULL, AV_LOG_ERROR, "Cannot configure graph\n");

exit_init_filter:
    // free the inputs and outputs before returning
    avfilter_inout_free(&inputs);
    avfilter_inout_free(outputs);

    return return_code;
}

void handle_destroy_state(UnifexEnv *env, State *state)
{
    if (state->filter_graph != NULL)
    {
        avfilter_graph_free(&state->filter_graph);
    }
    unifex_free(state->in_ctx);
    state->out_ctx.buffer_ctx = NULL;
    UNIFEX_UNUSED(env);
}

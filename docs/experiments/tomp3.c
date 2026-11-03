#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libswresample/swresample.h>
#include <libavutil/opt.h>
#include <stdio.h>
int main(int argc, char** argv) {
    AVFormatContext *ic = NULL;
    if (avformat_open_input(&ic, argv[1], NULL, NULL) < 0) return 1;
    if (avformat_find_stream_info(ic, NULL) < 0) return 2;
    int ai = av_find_best_stream(ic, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (ai < 0) return 3;
    const AVCodec *dec = avcodec_find_decoder(ic->streams[ai]->codecpar->codec_id);
    AVCodecContext *dc = avcodec_alloc_context3(dec);
    avcodec_parameters_to_context(dc, ic->streams[ai]->codecpar);
    avcodec_open2(dc, dec, NULL);
    const AVCodec *enc = avcodec_find_encoder_by_name("libmp3lame");
    AVCodecContext *ec = avcodec_alloc_context3(enc);
    ec->sample_rate = 44100; ec->ch_layout = (AVChannelLayout)AV_CHANNEL_LAYOUT_STEREO;
    ec->bit_rate = 192000; ec->sample_fmt = enc->sample_fmts[0];
    ec->time_base = (AVRational){1, 44100};
    avcodec_open2(ec, enc, NULL);
    SwrContext *sw = NULL;
    swr_alloc_set_opts2(&sw, &ec->ch_layout, ec->sample_fmt, ec->sample_rate,
                        &dc->ch_layout, dc->sample_fmt, dc->sample_rate, 0, NULL);
    swr_init(sw);
    AVFormatContext *oc = NULL;
    avformat_alloc_output_context2(&oc, NULL, "mp3", argv[2]);
    AVStream *ost = avformat_new_stream(oc, NULL);
    avcodec_parameters_from_context(ost->codecpar, ec);
    ost->time_base = ec->time_base;
    avio_open(&oc->pb, argv[2], AVIO_FLAG_WRITE);
    avformat_write_header(oc, NULL);
    AVPacket *pkt = av_packet_alloc(), *opkt = av_packet_alloc();
    AVFrame *fr = av_frame_alloc(), *ofr = av_frame_alloc();
    ofr->format = ec->sample_fmt; ofr->ch_layout = ec->ch_layout; ofr->sample_rate = ec->sample_rate;
    ofr->nb_samples = ec->frame_size ? ec->frame_size : 1152;
    av_frame_get_buffer(ofr, 0);
    while (av_read_frame(ic, pkt) >= 0) {
        if (pkt->stream_index != ai) { av_packet_unref(pkt); continue; }
        if (avcodec_send_packet(dc, pkt) < 0) { av_packet_unref(pkt); continue; }
        av_packet_unref(pkt);
        while (avcodec_receive_frame(dc, fr) == 0) {
            av_frame_make_writable(ofr);
            int out_n = swr_convert(sw, ofr->extended_data, ofr->nb_samples, (const uint8_t**)fr->extended_data, fr->nb_samples);
            ofr->nb_samples = out_n;
            if (avcodec_send_frame(ec, ofr) < 0) continue;
            while (avcodec_receive_packet(ec, opkt) == 0) { av_packet_rescale_ts(opkt, ec->time_base, ost->time_base); av_interleaved_write_frame(oc, opkt); av_packet_unref(opkt); }
        }
        av_frame_unref(fr);
    }
    avcodec_send_frame(ec, NULL);
    while (avcodec_receive_packet(ec, opkt) == 0) { av_packet_rescale_ts(opkt, ec->time_base, ost->time_base); av_interleaved_write_frame(oc, opkt); av_packet_unref(opkt); }
    av_write_trailer(oc);
    avio_closep(&oc->pb);
    printf("ok\n");
    return 0;
}

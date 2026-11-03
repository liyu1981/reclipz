#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <stdio.h>
int main(int argc, char** argv) {
    const AVOutputFormat *ofmt = av_guess_format(NULL, argv[2], NULL);
    AVFormatContext *ic = NULL, *oc = NULL;
    if (avformat_open_input(&ic, argv[1], NULL, NULL) < 0) return 1;
    if (avformat_find_stream_info(ic, NULL) < 0) return 2;
    avformat_alloc_output_context2(&oc, ofmt, NULL, argv[2]);
    for (unsigned i = 0; i < ic->nb_streams; i++) {
        AVStream *in = ic->streams[i];
        AVStream *out = avformat_new_stream(oc, NULL);
        avcodec_parameters_copy(out->codecpar, in->codecpar);
        out->codecpar->codec_tag = 0;
    }
    avio_open(&oc->pb, argv[2], AVIO_FLAG_WRITE);
    avformat_write_header(oc, NULL);
    AVPacket *pkt = av_packet_alloc();
    while (av_read_frame(ic, pkt) >= 0) { av_packet_rescale_ts(pkt, ic->streams[pkt->stream_index]->time_base, oc->streams[pkt->stream_index]->time_base); av_interleaved_write_frame(oc, pkt); av_packet_unref(pkt); }
    av_write_trailer(oc);
    avio_closep(&oc->pb);
    avformat_close_input(&ic);
    avformat_free_context(oc);
    return 0;
}

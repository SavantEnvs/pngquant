// Fuzz pngquant's PNG decode -> quantize -> remap -> PNG8 encode pipeline in memory.
// Mirrors pngquant_file_internal() (pngquant.c) without touching the filesystem.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "libimagequant.h"
#include "rwpng.h"

#define MAX_PIXELS (1u << 20)

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    static const uint8_t sig[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};
    if (size < 33) return -1;
    if (memcmp(data, sig, 8) == 0) {
        uint64_t w = ((uint64_t)data[16] << 24) | (data[17] << 16) | (data[18] << 8) | data[19];
        uint64_t h = ((uint64_t)data[20] << 24) | (data[21] << 16) | (data[22] << 8) | data[23];
        if (w * h > MAX_PIXELS) return -1;
    }

    FILE *in = fmemopen((void *)data, size, "rb");
    if (!in) return 0;
    png24_image img = {.width = 0};
    pngquant_error err = rwpng_read_image24(in, &img, 0, 0);
    fclose(in);

    if (err == SUCCESS) {
        liq_attr *attr = liq_attr_create();
        liq_set_speed(attr, 10);
        liq_image *li = liq_image_create_rgba_rows(attr, (void **)img.row_pointers,
                                                   img.width, img.height, img.gamma);
        liq_result *res = NULL;
        if (li && LIQ_OK == liq_image_quantize(li, attr, &res)) {
            liq_set_output_gamma(res, 0.45455);
            liq_set_dithering_level(res, 1.0f);

            png8_image out = {.width = 0};
            out.width = img.width;
            out.height = img.height;
            out.gamma = liq_get_output_gamma(res);
            out.output_color = img.output_color;
            out.fast_compression = 1;
            out.indexed_data = malloc((size_t)out.width * out.height);
            out.row_pointers = malloc((size_t)out.height * sizeof(out.row_pointers[0]));
            if (out.indexed_data && out.row_pointers) {
                for (size_t r = 0; r < out.height; r++)
                    out.row_pointers[r] = out.indexed_data + r * out.width;
                if (LIQ_OK == liq_write_remapped_image_rows(res, li, out.row_pointers)) {
                    const liq_palette *pal = liq_get_palette(res);
                    out.num_palette = pal->count;
                    for (unsigned i = 0; i < pal->count; i++) {
                        out.palette[i] = (rwpng_rgba){pal->entries[i].r, pal->entries[i].g,
                                                      pal->entries[i].b, pal->entries[i].a};
                    }
                    out.chunks = img.chunks;
                    img.chunks = NULL;
                    char *obuf = NULL;
                    size_t olen = 0;
                    FILE *o = open_memstream(&obuf, &olen);
                    if (o) {
                        rwpng_write_image8(o, &out);
                        fclose(o);
                        free(obuf);
                    }
                }
            }
            rwpng_free_image8(&out);
        }
        if (res) liq_result_destroy(res);
        if (li) liq_image_destroy(li);
        liq_attr_destroy(attr);
    }
    rwpng_free_image24(&img);
    return 0;
}

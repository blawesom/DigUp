// PDFs through pdfium (Chrome's PDF engine, BSD): opened documents, their pages' text, their title, and a
// page rendered as a picture — the primitives the Swift side (`LinuxPDF.swift`) builds the Mac's PDFKit flow
// on. pdfium comes prebuilt into Vendor/pdfium (scripts/fetch-pdfium.sh); its headers are on the include path
// Package.swift adds.

#include "linuxmedia.h"
#include "stb_image_write.h"
#include <fpdfview.h>
#include <fpdf_text.h>
#include <fpdf_doc.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

struct DigupPdfDoc {
    FPDF_DOCUMENT document;
};

static pthread_once_t pdfium_once = PTHREAD_ONCE_INIT;

/// pdfium's library init is one call for the process, and not thread-safe to make; the tests run in parallel,
/// so the first call in whatever thread gets there does it for everyone.
static void ensure_pdfium(void) {
    pthread_once(&pdfium_once, FPDF_InitLibrary);
}

DigupPdfDoc *digup_pdf_open(const char *path, int *out_status) {
    *out_status = 0;
    ensure_pdfium();
    FPDF_DOCUMENT document = FPDF_LoadDocument(path, NULL);
    if (!document) {
        *out_status = FPDF_GetLastError() == FPDF_ERR_PASSWORD ? 1 : 2;
        return NULL;
    }
    DigupPdfDoc *doc = malloc(sizeof(DigupPdfDoc));
    if (doc) doc->document = document;
    return doc;
}

int digup_pdf_count(DigupPdfDoc *doc) {
    return FPDF_GetPageCount(doc->document);
}

int digup_pdf_text(DigupPdfDoc *doc, int index, unsigned short **out_text, int *out_length) {
    *out_text = NULL;
    *out_length = 0;
    FPDF_PAGE page = FPDF_LoadPage(doc->document, index);
    if (!page) return -1;
    FPDF_TEXTPAGE text = FPDFText_LoadPage(page);
    if (text) {
        const int chars = FPDFText_CountChars(text);
        unsigned short *buffer = malloc(sizeof(unsigned short) * (size_t)(chars + 2));
        if (buffer) {
            const int written = FPDFText_GetText(text, 0, chars, buffer);
            *out_text = buffer;
            *out_length = written > 0 ? written : 0;   // what pdfium wrote, trailing NUL included
        }
        FPDFText_ClosePage(text);
    }
    FPDF_ClosePage(page);
    return 0;
}

int digup_pdf_title(DigupPdfDoc *doc, unsigned short **out_title, int *out_length) {
    *out_title = NULL;
    *out_length = 0;
    unsigned short wide[512];
    const unsigned long needed = FPDF_GetMetaText(doc->document, "Title", wide, sizeof(wide));
    const unsigned long chars = needed / sizeof(unsigned short);
    if (chars <= 1) return 0;   // nothing there but the NUL
    unsigned short *copy = malloc(needed > sizeof(wide) ? needed : sizeof(wide));
    if (!copy) return -1;
    if (needed > sizeof(wide)) {
        FPDF_GetMetaText(doc->document, "Title", copy, needed);
        *out_length = (int)(needed / sizeof(unsigned short)) - 1;
    } else {
        memcpy(copy, wide, chars * sizeof(unsigned short));
        *out_length = (int)chars - 1;
    }
    *out_title = copy;
    return 0;
}

int digup_pdf_render(DigupPdfDoc *doc, int index, int pixels, const char *out_path) {
    FPDF_PAGE page = FPDF_LoadPage(doc->document, index);
    if (!page) return -1;
    const double width = FPDF_GetPageWidth(page), height = FPDF_GetPageHeight(page);
    const double scale = (width > height ? width : height) > 0 ? pixels / (width > height ? width : height) : 1;
    const int bitmap_w = (int)(width * scale), bitmap_h = (int)(height * scale);
    FPDF_BITMAP bitmap = bitmap_w > 0 && bitmap_h > 0 ? FPDFBitmap_Create(bitmap_w, bitmap_h, 0) : NULL;
    if (!bitmap) {
        FPDF_ClosePage(page);
        return -1;
    }
    FPDFBitmap_FillRect(bitmap, 0, 0, bitmap_w, bitmap_h, 0xFFFFFFFF);
    FPDF_RenderPageBitmap(bitmap, page, 0, 0, bitmap_w, bitmap_h, 0, FPDF_ANNOT);
    // pdfium draws BGRA; the PNG writer takes RGB
    const uint8_t *buffer = (const uint8_t *)FPDFBitmap_GetBuffer(bitmap);
    const int stride = FPDFBitmap_GetStride(bitmap);
    uint8_t *rgb = malloc((size_t)bitmap_w * bitmap_h * 3);
    if (rgb) {
        for (int y = 0; y < bitmap_h; y++) {
            const uint8_t *row = buffer + (size_t)y * stride;
            uint8_t *out = rgb + (size_t)y * bitmap_w * 3;
            for (int x = 0; x < bitmap_w; x++) {
                out[x * 3] = row[x * 4 + 2];
                out[x * 3 + 1] = row[x * 4 + 1];
                out[x * 3 + 2] = row[x * 4];
            }
        }
    }
    FPDFBitmap_Destroy(bitmap);
    FPDF_ClosePage(page);
    if (!rgb) return -1;
    const int written = stbi_write_png(out_path, bitmap_w, bitmap_h, 3, rgb, bitmap_w * 3) == 0 ? -1 : 0;
    free(rgb);
    return written;
}

void digup_pdf_close(DigupPdfDoc *doc) {
    if (doc) {
        FPDF_CloseDocument(doc->document);
        free(doc);
    }
}

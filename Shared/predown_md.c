#include "predown_md.h"
#include "md4c-html.h"

int predown_render_html(const char *input, unsigned size,
                        predown_output_fn output, void *userdata)
{
    unsigned parser_flags = MD_DIALECT_GITHUB | MD_FLAG_HIGHLIGHT;
    unsigned render_flags = MD_HTML_FLAG_SKIP_UTF8_BOM;
    return md_html(input, size, output, userdata, parser_flags, render_flags);
}

#ifndef PREDOWN_MD_H
#define PREDOWN_MD_H

/* Thin wrapper around md4c-html so Swift never has to see md4c's
 * compound flag macros (Swift can't import those). */

typedef void (*predown_output_fn)(const char *data, unsigned size, void *userdata);

/* Renders CommonMark + GitHub extensions (tables, task lists, strikethrough,
 * autolinks, footnotes, admonitions) plus ==highlight==. Returns 0 on success. */
int predown_render_html(const char *input, unsigned size,
                        predown_output_fn output, void *userdata);

#endif

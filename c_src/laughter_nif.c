#include <string.h>

#include "erl_nif.h"
#include "lol_html.h"

ERL_NIF_TERM atom_ok;
ERL_NIF_TERM atom_true;
ERL_NIF_TERM atom_false;
ERL_NIF_TERM atom_comment;
ERL_NIF_TERM atom_text;
ERL_NIF_TERM atom_element;
ERL_NIF_TERM atom_end;
ERL_NIF_TERM atom_enomem;

typedef struct {
  lol_html_rewriter_builder_t *builder;
} laughter_builder_ctx_t;

typedef struct {
  lol_html_rewriter_t *rewriter;
} laughter_rewriter_ctx_t;

typedef struct {
  ErlNifEnv *env;
  ErlNifPid to_pid;
} laughter_handler_t;

static ErlNifResourceType *laughter_rewriter_ctx_rtype;
static ErlNifResourceType *laughter_builder_ctx_rtype;
static ErlNifResourceType *laughter_handler_rtype;

static lol_html_rewriter_directive_t send_element(lol_html_element_t *comment,
                                                  void *user_data);
static lol_html_rewriter_directive_t send_text_chunk(
    lol_html_text_chunk_t *chunk, void *user_data);
static lol_html_rewriter_directive_t send_document_end(
    lol_html_doc_end_t *doc_end, void *user_data);

static void output_sink_stub(const char *chunk, size_t chunk_len,
                             void *user_data) {}

static ERL_NIF_TERM make_binary_from_lol_html_str(ErlNifEnv *en,
                                                  lol_html_str_t str);
static ERL_NIF_TERM raise_last_lol_html_error(ErlNifEnv *env);

static ERL_NIF_TERM laughter_build_nif(ErlNifEnv *env, int argc,
                                       ERL_NIF_TERM const argv[]) {
  ERL_NIF_TERM ret;

  laughter_builder_ctx_t *ctx;

  ctx = enif_alloc_resource(laughter_builder_ctx_rtype,
                            sizeof(laughter_builder_ctx_t));

  if (ctx == NULL)
    return enif_raise_exception(env, atom_enomem);

  if ((ctx->builder = lol_html_rewriter_builder_new()) == NULL)
    return enif_raise_exception(env, atom_enomem);

  ret = enif_make_resource(env, ctx);

  enif_release_resource(ctx);

  return ret;
}

static ERL_NIF_TERM laughter_stream_elements_nif(ErlNifEnv *env, int argc,
                                                 ERL_NIF_TERM const argv[]) {
  laughter_builder_ctx_t *ctx;
  laughter_handler_t *handler;
  lol_html_selector_t *selector;

  ErlNifBinary selector_bin;

  if (!enif_get_resource(env, argv[0], laughter_builder_ctx_rtype,
                         (void **)&ctx))
    return enif_make_badarg(env);

  if (!enif_is_pid(env, argv[1]))
    return enif_make_badarg(env);

  if (!enif_inspect_binary(env, argv[2], &selector_bin))
    return enif_make_badarg(env);

  if (argv[3] != atom_true && argv[3] != atom_false)
    return enif_make_badarg(env);

  handler =
      enif_alloc_resource(laughter_handler_rtype, sizeof(laughter_handler_t));

  if (handler == NULL)
    return enif_raise_exception(env, atom_enomem);

  selector = lol_html_selector_parse((const char *)selector_bin.data,
                                     selector_bin.size);

  if (!selector)
    return raise_last_lol_html_error(env);

  enif_get_local_pid(env, argv[1], &handler->to_pid);

  handler->env = env;

  lol_html_rewriter_builder_add_element_content_handlers(
      ctx->builder, selector, &send_element, handler,
      /* comment_handler */ NULL, /* comment_handler_user_data */ NULL,
      argv[3] == atom_true ? &send_text_chunk : NULL,
      argv[3] == atom_true ? handler : NULL);

  lol_html_rewriter_builder_add_document_content_handlers(
      ctx->builder, /* doctype_handler */ NULL,
      /* doctype_handler_user_data */ NULL, /* text_handler */ NULL,
      /* text_handler_user_data */ NULL, /* doc_end_handler */ NULL,
      /* doc_end_user_data */ NULL, &send_document_end, handler);

  return enif_make_resource(env, handler);
}

static ERL_NIF_TERM laughter_create_nif(ErlNifEnv *env, int argc,
                                        ERL_NIF_TERM const argv[]) {
  ERL_NIF_TERM ret;
  ErlNifBinary encoding;
  int max_memory;

  laughter_builder_ctx_t *builder_ctx;
  laughter_rewriter_ctx_t *rewriter_ctx;

  if (!enif_get_resource(env, argv[0], laughter_builder_ctx_rtype,
                         (void **)&builder_ctx))
    return enif_make_badarg(env);

  if (!enif_inspect_binary(env, argv[1], &encoding))
    return enif_make_badarg(env);

  if (!enif_get_int(env, argv[2], &max_memory))
    return enif_make_badarg(env);

  rewriter_ctx = enif_alloc_resource(laughter_rewriter_ctx_rtype,
                                     sizeof(laughter_rewriter_ctx_t));

  if (rewriter_ctx == NULL)
    return enif_raise_exception(env, atom_enomem);

  rewriter_ctx->rewriter = lol_html_rewriter_build(
      builder_ctx->builder, (const char *)encoding.data, encoding.size,
      (lol_html_memory_settings_t){.preallocated_parsing_buffer_size = 0,
                                   .max_allowed_memory_usage = max_memory},
      output_sink_stub, NULL, true);

  if (rewriter_ctx->rewriter == NULL)
    return enif_raise_exception(env, atom_enomem);

  ret = enif_make_resource(env, rewriter_ctx);

  enif_release_resource(rewriter_ctx);

  return ret;
}

static ERL_NIF_TERM laughter_parse_nif(ErlNifEnv *env, int argc,
                                       ERL_NIF_TERM const argv[]) {
  ErlNifBinary bin;
  laughter_rewriter_ctx_t *ctx;

  if (!enif_get_resource(env, argv[0], laughter_rewriter_ctx_rtype,
                         (void **)&ctx))
    return enif_make_badarg(env);

  if (!enif_inspect_binary(env, argv[1], &bin))
    return enif_make_badarg(env);

  if (lol_html_rewriter_write(ctx->rewriter, (const char *)bin.data, bin.size))
    return raise_last_lol_html_error(env);

  return argv[0];
}

static ERL_NIF_TERM laughter_done_nif(ErlNifEnv *env, int argc,
                                      ERL_NIF_TERM const argv[]) {
  laughter_rewriter_ctx_t *ctx;

  if (!enif_get_resource(env, argv[0], laughter_rewriter_ctx_rtype,
                         (void **)&ctx))
    return enif_make_badarg(env);

  if (lol_html_rewriter_end(ctx->rewriter))
    return raise_last_lol_html_error(env);

  return atom_ok;
}

static void laughter_builder_ctx_dtor(ErlNifEnv *env,
                                      laughter_builder_ctx_t *ctx) {
  if (ctx == NULL)
    return;

  if (ctx->builder)
    lol_html_rewriter_builder_free(ctx->builder);
}

static void laughter_rewriter_ctx_dtor(ErlNifEnv *env,
                                       laughter_rewriter_ctx_t *ctx) {
  if (ctx == NULL)
    return;

  if (ctx->rewriter)
    lol_html_rewriter_free(ctx->rewriter);
}

static lol_html_rewriter_directive_t send_element(lol_html_element_t *element,
                                                  void *user_data) {
  ERL_NIF_TERM ref, msg, tag, attrs;
  lol_html_str_t str;

  lol_html_attributes_iterator_t *attr_iter;
  const lol_html_attribute_t *attr;
  laughter_handler_t *handler = user_data;

  str = lol_html_element_tag_name_get(element);

  if (!(tag = make_binary_from_lol_html_str(handler->env, str)))
    return LOL_HTML_STOP;

  lol_html_str_free(str);

  attrs = enif_make_list(handler->env, 0);
  attr_iter = lol_html_attributes_iterator_get(element);

  while ((attr = lol_html_attributes_iterator_next(attr_iter))) {
    ERL_NIF_TERM name;
    ERL_NIF_TERM value;

    str = lol_html_attribute_name_get(attr);

    if (!(name = make_binary_from_lol_html_str(handler->env, str)))
      return LOL_HTML_STOP;

    lol_html_str_free(str);

    str = lol_html_attribute_value_get(attr);

    if (!(value = make_binary_from_lol_html_str(handler->env, str)))
      return LOL_HTML_STOP;

    lol_html_str_free(str);

    attrs = enif_make_list_cell(
        handler->env, enif_make_tuple2(handler->env, name, value), attrs);
  }

  ref = enif_make_resource(handler->env, handler);

  enif_make_reverse_list(handler->env, attrs, &attrs);

  msg = enif_make_tuple3(handler->env, atom_element, ref,
                         enif_make_tuple2(handler->env, tag, attrs));

  enif_send(handler->env, &handler->to_pid, NULL, msg);

  return LOL_HTML_CONTINUE;
}

static lol_html_rewriter_directive_t send_text_chunk(
    lol_html_text_chunk_t *chunk, void *user_data) {
  ERL_NIF_TERM ref, bin;
  unsigned char *dest = NULL;

  laughter_handler_t *handler = user_data;
  lol_html_text_chunk_content_t content =
      lol_html_text_chunk_content_get(chunk);

  if ((dest = enif_make_new_binary(handler->env, content.len, &bin)) == NULL) {
    enif_raise_exception(handler->env, atom_enomem);
    return LOL_HTML_STOP;
  }

  memcpy(dest, content.data, content.len);

  ref = enif_make_resource(handler->env, handler);

  enif_release_resource(handler);

  enif_send(handler->env, &handler->to_pid, NULL,
            enif_make_tuple3(handler->env, atom_text, ref, bin));

  return LOL_HTML_CONTINUE;
}

static lol_html_rewriter_directive_t send_document_end(
    lol_html_doc_end_t *doc_end, void *user_data) {
  ERL_NIF_TERM ref;

  laughter_handler_t *handler = user_data;

  ref = enif_make_resource(handler->env, handler);

  enif_release_resource(handler);

  enif_send(handler->env, &handler->to_pid, NULL,
            enif_make_tuple2(handler->env, atom_end, ref));

  return LOL_HTML_CONTINUE;
}

static ERL_NIF_TERM make_binary_from_lol_html_str(ErlNifEnv *env,
                                                  lol_html_str_t str) {
  ERL_NIF_TERM bin;
  unsigned char *dest = NULL;

  if ((dest = enif_make_new_binary(env, str.len, &bin)) == NULL) {
    enif_raise_exception(env, atom_enomem);
    return 0;
  }

  memcpy(dest, str.data, str.len);

  return bin;
}

static ERL_NIF_TERM raise_last_lol_html_error(ErlNifEnv *env) {
  ERL_NIF_TERM reason;
  lol_html_str_t *err = lol_html_take_last_error();

  if (!(reason = make_binary_from_lol_html_str(env, *err)))
    return enif_raise_exception(env, atom_enomem);

  lol_html_str_free(*err);

  return enif_raise_exception(env, reason);
}

static ErlNifFunc nif_functions[] = {
    {"build", 0, laughter_build_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"stream_elements", 4, laughter_stream_elements_nif,
     ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"create", 3, laughter_create_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"parse", 2, laughter_parse_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"done", 1, laughter_done_nif, ERL_NIF_DIRTY_JOB_CPU_BOUND},
};

static int on_load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info) {
  laughter_builder_ctx_rtype =
      enif_open_resource_type(env, NULL, "laughter_builder",
                              (ErlNifResourceDtor *)laughter_builder_ctx_dtor,
                              ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER, NULL);

  laughter_rewriter_ctx_rtype =
      enif_open_resource_type(env, NULL, "laughter_rewriter",
                              (ErlNifResourceDtor *)laughter_rewriter_ctx_dtor,
                              ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER, NULL);

  laughter_handler_rtype =
      enif_open_resource_type(env, NULL, "laughter_handler", NULL,
                              ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER, NULL);

  atom_ok = enif_make_atom(env, "ok");
  atom_true = enif_make_atom(env, "true");
  atom_false = enif_make_atom(env, "false");
  atom_comment = enif_make_atom(env, "comment");
  atom_element = enif_make_atom(env, "element");
  atom_text = enif_make_atom(env, "text");
  atom_end = enif_make_atom(env, "end");
  atom_enomem = enif_make_atom(env, "enomem");

  return 0;
}

static int on_upgrade(ErlNifEnv *env, void **priv_data, void **old_priv_data,
                      ERL_NIF_TERM load_info) {
  return 0;
}

ERL_NIF_INIT(Elixir.Laughter.Nif, nif_functions, on_load, /* reload */ NULL,
             on_upgrade, /* unload */ NULL);

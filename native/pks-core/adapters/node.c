#include <node_api.h>
#include <stdlib.h>
#include "../include/pks_core.h"

typedef struct {
    napi_async_work work;
    napi_deferred deferred;
    char *path;
    char *request;
    char *result;
} SearchWork;

static char *string_arg(napi_env env, napi_value value) {
    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, NULL, 0, &length) != napi_ok) return NULL;
    char *buffer = malloc(length + 1);
    if (!buffer) return NULL;
    if (napi_get_value_string_utf8(env, value, buffer, length + 1, &length) != napi_ok) {
        free(buffer);
        return NULL;
    }
    return buffer;
}

static char *run_search(const char *path, const char *request) {
    PksHandle *handle = pks_open(path);
    char *result = handle ? pks_search_json(handle, request) : NULL;
    if (handle) pks_close(handle);
    return result;
}

static napi_value search(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_value output;

    if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc != 2) {
        napi_throw_type_error(env, NULL, "Expected database path and request JSON");
        return NULL;
    }

    char *path = string_arg(env, argv[0]);
    char *request = string_arg(env, argv[1]);
    if (!path || !request) {
        free(path);
        free(request);
        napi_throw_type_error(env, NULL, "Expected UTF-8 strings");
        return NULL;
    }

    char *result = run_search(path, request);
    free(path);
    free(request);

    if (!result) {
        napi_throw_error(env, NULL, "PKS search failed");
        return NULL;
    }

    napi_status status = napi_create_string_utf8(env, result, NAPI_AUTO_LENGTH, &output);
    pks_string_free(result);
    return status == napi_ok ? output : NULL;
}

static void execute_search(napi_env env, void *data) {
    (void)env;
    SearchWork *work = (SearchWork *)data;
    work->result = run_search(work->path, work->request);
}

static void complete_search(napi_env env, napi_status status, void *data) {
    SearchWork *work = (SearchWork *)data;
    napi_value value = NULL;

    if (status == napi_ok && work->result &&
        napi_create_string_utf8(env, work->result, NAPI_AUTO_LENGTH, &value) == napi_ok) {
        napi_resolve_deferred(env, work->deferred, value);
    } else {
        napi_value message;
        napi_value error;
        if (napi_create_string_utf8(env, "PKS search failed", NAPI_AUTO_LENGTH, &message) == napi_ok &&
            napi_create_error(env, NULL, message, &error) == napi_ok) {
            napi_reject_deferred(env, work->deferred, error);
        }
    }

    free(work->path);
    free(work->request);
    if (work->result) pks_string_free(work->result);
    napi_delete_async_work(env, work->work);
    free(work);
}

static napi_value search_async(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_value promise;
    napi_value resource_name;

    if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc != 2) {
        napi_throw_type_error(env, NULL, "Expected database path and request JSON");
        return NULL;
    }

    SearchWork *work = calloc(1, sizeof(SearchWork));
    if (!work) {
        napi_throw_error(env, NULL, "PKS search allocation failed");
        return NULL;
    }

    work->path = string_arg(env, argv[0]);
    work->request = string_arg(env, argv[1]);
    if (!work->path || !work->request) {
        free(work->path);
        free(work->request);
        free(work);
        napi_throw_type_error(env, NULL, "Expected UTF-8 strings");
        return NULL;
    }

    if (napi_create_promise(env, &work->deferred, &promise) != napi_ok ||
        napi_create_string_utf8(env, "pks.searchAsync", NAPI_AUTO_LENGTH, &resource_name) != napi_ok ||
        napi_create_async_work(env, NULL, resource_name, execute_search, complete_search, work, &work->work) != napi_ok ||
        napi_queue_async_work(env, work->work) != napi_ok) {
        if (work->work) napi_delete_async_work(env, work->work);
        free(work->path);
        free(work->request);
        free(work);
        napi_throw_error(env, NULL, "Unable to queue PKS search");
        return NULL;
    }

    return promise;
}

NAPI_MODULE_INIT() {
    napi_value fn;

    if (napi_create_function(env, "search", NAPI_AUTO_LENGTH, search, NULL, &fn) != napi_ok) return NULL;
    if (napi_set_named_property(env, exports, "search", fn) != napi_ok) return NULL;

    if (napi_create_function(env, "searchAsync", NAPI_AUTO_LENGTH, search_async, NULL, &fn) != napi_ok) return NULL;
    if (napi_set_named_property(env, exports, "searchAsync", fn) != napi_ok) return NULL;

    return exports;
}

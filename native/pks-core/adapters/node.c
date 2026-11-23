#include <node_api.h>
#include <stdlib.h>
#include "../include/pks_core.h"

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

    PksHandle *handle = pks_open(path);
    free(path);
    char *result = handle ? pks_search_json(handle, request) : NULL;
    free(request);
    if (handle) pks_close(handle);

    if (!result) {
        napi_throw_error(env, NULL, "PKS search failed");
        return NULL;
    }

    napi_status status = napi_create_string_utf8(env, result, NAPI_AUTO_LENGTH, &output);
    pks_string_free(result);
    return status == napi_ok ? output : NULL;
}

NAPI_MODULE_INIT() {
    napi_value fn;
    if (napi_create_function(env, "search", NAPI_AUTO_LENGTH, search, NULL, &fn) != napi_ok) return NULL;
    if (napi_set_named_property(env, exports, "search", fn) != napi_ok) return NULL;
    return exports;
}

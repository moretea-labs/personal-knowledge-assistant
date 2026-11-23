#include <node_api.h>
#include <pthread.h>
#include <stdlib.h>
#include "../include/pks_core.h"

typedef struct {
    PksHandle *handle;
    pthread_mutex_t mutex;
} NativeSearchHandle;

typedef struct {
    napi_async_work work;
    napi_deferred deferred;
    char *path;
    char *request;
    char *result;
    NativeSearchHandle *persistent;
    napi_ref persistent_ref;
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

static NativeSearchHandle *handle_arg(napi_env env, napi_value value) {
    void *data = NULL;
    if (napi_get_value_external(env, value, &data) != napi_ok) return NULL;
    return (NativeSearchHandle *)data;
}

static void finalize_handle(napi_env env, void *data, void *hint) {
    (void)env;
    (void)hint;
    NativeSearchHandle *native = (NativeSearchHandle *)data;
    if (!native) return;
    if (pthread_mutex_lock(&native->mutex) == 0) {
        if (native->handle) {
            pks_close(native->handle);
            native->handle = NULL;
        }
        pthread_mutex_unlock(&native->mutex);
    }
    pthread_mutex_destroy(&native->mutex);
    free(native);
}

static char *run_search(const char *path, const char *request) {
    PksHandle *handle = pks_open(path);
    char *result = handle ? pks_search_json(handle, request) : NULL;
    if (handle) pks_close(handle);
    return result;
}

static char *run_handle_search(NativeSearchHandle *native, const char *request) {
    if (!native || !native->handle) return NULL;
    if (pthread_mutex_lock(&native->mutex) != 0) return NULL;
    char *result = pks_search_json(native->handle, request);
    pthread_mutex_unlock(&native->mutex);
    return result;
}

static napi_value open_handle(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_value output;

    if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc != 1) {
        napi_throw_type_error(env, NULL, "Expected database path");
        return NULL;
    }

    char *path = string_arg(env, argv[0]);
    if (!path) {
        napi_throw_type_error(env, NULL, "Expected UTF-8 database path");
        return NULL;
    }

    PksHandle *handle = pks_open(path);
    free(path);
    if (!handle) {
        napi_throw_error(env, NULL, "PKS open failed");
        return NULL;
    }

    NativeSearchHandle *native = calloc(1, sizeof(NativeSearchHandle));
    if (!native) {
        pks_close(handle);
        napi_throw_error(env, NULL, "PKS handle allocation failed");
        return NULL;
    }
    native->handle = handle;
    if (pthread_mutex_init(&native->mutex, NULL) != 0) {
        pks_close(handle);
        free(native);
        napi_throw_error(env, NULL, "PKS handle mutex initialization failed");
        return NULL;
    }

    if (napi_create_external(env, native, finalize_handle, NULL, &output) != napi_ok) {
        finalize_handle(env, native, NULL);
        napi_throw_error(env, NULL, "Unable to create PKS native handle");
        return NULL;
    }
    return output;
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

static napi_value search_handle(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_value output;

    if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc != 2) {
        napi_throw_type_error(env, NULL, "Expected native handle and request JSON");
        return NULL;
    }

    NativeSearchHandle *native = handle_arg(env, argv[0]);
    char *request = string_arg(env, argv[1]);
    if (!native || !request) {
        free(request);
        napi_throw_type_error(env, NULL, "Expected PKS native handle and UTF-8 request");
        return NULL;
    }

    char *result = run_handle_search(native, request);
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
    work->result = work->persistent
        ? run_handle_search(work->persistent, work->request)
        : run_search(work->path, work->request);
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
    if (work->persistent_ref) napi_delete_reference(env, work->persistent_ref);
    napi_delete_async_work(env, work->work);
    free(work);
}

static napi_value queue_search_work(napi_env env, SearchWork *work, const char *name) {
    napi_value promise;
    napi_value resource_name;

    if (napi_create_promise(env, &work->deferred, &promise) != napi_ok ||
        napi_create_string_utf8(env, name, NAPI_AUTO_LENGTH, &resource_name) != napi_ok ||
        napi_create_async_work(env, NULL, resource_name, execute_search, complete_search, work, &work->work) != napi_ok ||
        napi_queue_async_work(env, work->work) != napi_ok) {
        if (work->work) napi_delete_async_work(env, work->work);
        if (work->persistent_ref) napi_delete_reference(env, work->persistent_ref);
        free(work->path);
        free(work->request);
        free(work);
        napi_throw_error(env, NULL, "Unable to queue PKS search");
        return NULL;
    }
    return promise;
}

static napi_value search_async(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];

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

    return queue_search_work(env, work, "pks.searchAsync");
}

static napi_value search_handle_async(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];

    if (napi_get_cb_info(env, info, &argc, argv, NULL, NULL) != napi_ok || argc != 2) {
        napi_throw_type_error(env, NULL, "Expected native handle and request JSON");
        return NULL;
    }

    NativeSearchHandle *native = handle_arg(env, argv[0]);
    if (!native) {
        napi_throw_type_error(env, NULL, "Expected PKS native handle");
        return NULL;
    }

    SearchWork *work = calloc(1, sizeof(SearchWork));
    if (!work) {
        napi_throw_error(env, NULL, "PKS search allocation failed");
        return NULL;
    }

    work->persistent = native;
    work->request = string_arg(env, argv[1]);
    if (!work->request || napi_create_reference(env, argv[0], 1, &work->persistent_ref) != napi_ok) {
        free(work->request);
        free(work);
        napi_throw_type_error(env, NULL, "Unable to retain PKS native handle");
        return NULL;
    }

    return queue_search_work(env, work, "pks.searchHandleAsync");
}

NAPI_MODULE_INIT() {
    napi_value fn;

    if (napi_create_function(env, "openHandle", NAPI_AUTO_LENGTH, open_handle, NULL, &fn) != napi_ok) return NULL;
    if (napi_set_named_property(env, exports, "openHandle", fn) != napi_ok) return NULL;

    if (napi_create_function(env, "searchHandle", NAPI_AUTO_LENGTH, search_handle, NULL, &fn) != napi_ok) return NULL;
    if (napi_set_named_property(env, exports, "searchHandle", fn) != napi_ok) return NULL;

    if (napi_create_function(env, "searchHandleAsync", NAPI_AUTO_LENGTH, search_handle_async, NULL, &fn) != napi_ok) return NULL;
    if (napi_set_named_property(env, exports, "searchHandleAsync", fn) != napi_ok) return NULL;

    if (napi_create_function(env, "search", NAPI_AUTO_LENGTH, search, NULL, &fn) != napi_ok) return NULL;
    if (napi_set_named_property(env, exports, "search", fn) != napi_ok) return NULL;

    if (napi_create_function(env, "searchAsync", NAPI_AUTO_LENGTH, search_async, NULL, &fn) != napi_ok) return NULL;
    if (napi_set_named_property(env, exports, "searchAsync", fn) != napi_ok) return NULL;

    return exports;
}

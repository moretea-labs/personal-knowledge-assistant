#ifndef PKS_CORE_H
#define PKS_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PksHandle PksHandle;

/* Open an existing PKS SQLite database read-only. Returns NULL on failure. */
PksHandle *pks_open(const char *database_path);

/* SearchRequest JSON in; versioned SearchResponse JSON out. Returned memory is
 * owned by PKS and must be released with pks_string_free. NULL means error.
 */
char *pks_search_json(PksHandle *handle, const char *request_json);
void pks_string_free(char *value);
void pks_close(PksHandle *handle);

#ifdef __cplusplus
}
#endif
#endif

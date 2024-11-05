#include <duckdb/duckdb.h>
#include <stdint.h>

typedef struct {
    duckdb_database db;
    duckdb_connection con;
    duckdb_appender docs_appender;
    uint32_t appended_docs;
    duckdb_appender failures_appender;
    uint32_t appended_failures;
    uint32_t failure_id;
} ducktrace_state;

typedef enum {
    DatabaseOpenFailed,
    DatabaseConnectionFailed,
    SchemaCreationFailed,
    AppenderCreateFailed,

    DocAppendDataFailed,
    FailureAppendDataFailed,

    AppenderFlushFailed,

    DucktraceOk,
} ducktrace_error;

ducktrace_error ducktrace_init(ducktrace_state* s, const char* db_path);
void ducktrace_deinit(ducktrace_state* s);
ducktrace_error insert_doc(ducktrace_state* s, int doc_id, bool parsing_failed, bool generation_failed);
ducktrace_error insert_failure(ducktrace_state* s, int doc_id, int err_code, const char* err_name, const char* err_ctx, size_t err_ctx_size);

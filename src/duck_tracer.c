#include "duck_tracer.h"
#include <assert.h>
#include <stdio.h>

static const char* create_table_sql = "DROP TABLE IF EXISTS docs;"
                                      "DROP TABLE IF EXISTS failures;"
                                      "CREATE TABLE docs (id INTEGER PRIMARY KEY, parsing_failed BOOL, generation_failed BOOL);"
                                      "CREATE TABLE failures (id INTEGER PRIMARY KEY, doc_id INTEGER, err_name VARCHAR NOT NULL, err_code INTEGER NOT NULL, err_ctx VARCHAR NOT NULL);";

ducktrace_error ducktrace_init(ducktrace_state* s, const char* db_path)
{
    assert(s);

    if (duckdb_open(db_path, &s->db) == DuckDBError)
        return DatabaseOpenFailed;
    if (duckdb_connect(s->db, &s->con) == DuckDBError)
        return DatabaseConnectionFailed;
    s->appended_docs = 0;
    s->appended_failures = 0;
    s->failure_id = 0;

    duckdb_result res;
    if (duckdb_query(s->con, create_table_sql, &res) == DuckDBError) {
        printf("[Ducktrace] create table failed: %s\n", duckdb_result_error(&res));
        return SchemaCreationFailed;
    }

    if (duckdb_appender_create(s->con, NULL, "docs", &s->docs_appender))
        return AppenderCreateFailed;
    if (duckdb_appender_create(s->con, NULL, "failures", &s->failures_appender))
        return AppenderCreateFailed;

    return DucktraceOk;
}

void ducktrace_deinit(ducktrace_state* s)
{
    assert(s);

    duckdb_state err = duckdb_appender_flush(s->docs_appender);
    if (err == DuckDBError) {
        printf("[Ducktrace] doc appender flush error: %s\n", duckdb_appender_error(s->docs_appender));
    }
    duckdb_appender_destroy(&s->docs_appender);

    err = duckdb_appender_flush(s->failures_appender);
    if (err == DuckDBError) {
        printf("[Ducktrace] doc appender flush error: %s\n", duckdb_appender_error(s->failures_appender));
    }
    duckdb_appender_destroy(&s->failures_appender);

    duckdb_disconnect(&s->con);
    duckdb_close(&s->db);
}

#define ROW_FLUSH_INTERVAL 10000

ducktrace_error insert_doc(ducktrace_state* s, int doc_id, bool parsing_failed, bool generation_failed)
{
    assert(s);

    if (duckdb_append_int32(s->docs_appender, doc_id))
        return DocAppendDataFailed;
    if (duckdb_append_bool(s->docs_appender, parsing_failed))
        return DocAppendDataFailed;
    if (duckdb_append_bool(s->docs_appender, generation_failed))
        return DocAppendDataFailed;
    if (duckdb_appender_end_row(s->docs_appender))
        return DocAppendDataFailed;

    s->appended_docs++;
    if (s->appended_docs > ROW_FLUSH_INTERVAL) {
        duckdb_state err = duckdb_appender_flush(s->docs_appender);
        if (err == DuckDBError) {
            printf("[Ducktrace] doc appender flush error: %s\n", duckdb_appender_error(s->docs_appender));
            return AppenderFlushFailed;
        }
        s->appended_docs = 0;
    }

    return DucktraceOk;
}

ducktrace_error insert_failure(ducktrace_state* s, int doc_id, int err_code, const char* err_name, const char* err_ctx, size_t err_ctx_size)
{
    assert(s);

    if (duckdb_append_int32(s->failures_appender, s->failure_id))
        return FailureAppendDataFailed;
    if (duckdb_append_int32(s->failures_appender, doc_id))
        return FailureAppendDataFailed;
    if (duckdb_append_varchar(s->failures_appender, err_name))
        return FailureAppendDataFailed;
    if (duckdb_append_int32(s->failures_appender, err_code))
        return FailureAppendDataFailed;
    if (duckdb_append_varchar_length(s->failures_appender, err_ctx, err_ctx_size))
        return FailureAppendDataFailed;
    if (duckdb_appender_end_row(s->failures_appender))
        return FailureAppendDataFailed;

    s->appended_failures++;
    s->failure_id++;
    if (s->appended_failures > ROW_FLUSH_INTERVAL) {
        duckdb_state err = duckdb_appender_flush(s->failures_appender);
        if (err == DuckDBError) {
            printf("[Ducktrace] doc appender flush error: %s\n", duckdb_appender_error(s->failures_appender));
            return AppenderFlushFailed;
        }
        s->appended_failures = 0;
    }

    return DucktraceOk;
}

#include <stdbool.h>

typedef struct {
    void* ptr;
} minisearch;

bool init_search(minisearch* state, const char* index_dir);

void deinit_search(minisearch* state);

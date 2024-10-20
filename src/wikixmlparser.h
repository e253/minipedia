#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    bool is_redirect;
    char* article_title;
    size_t article_title_size;
    char* article;
    size_t article_size;
} WikiParseResult;

WikiParseResult cParsePage(const char* rawXmlEntry);

#ifdef __cplusplus
}
#endif
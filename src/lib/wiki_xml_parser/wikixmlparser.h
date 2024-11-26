#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    bool is_redirect;
    uint8_t ns;
    char* article_title;
    size_t article_title_size;
    char* article;
    size_t article_size;
} WikiParseResult;

WikiParseResult parsePage(const char* rawXmlEntry);

#ifdef __cplusplus
}
#endif
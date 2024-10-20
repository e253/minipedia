# Minipedia

Wikipedia is a great source of information and I like to browse offline to avoid prying eyes.

*Minipedia* is an aggressively size optimizied dump of English wikipedia meant for offline consumption.

## Changes to enwiki dumps
1. Change [mediawiki](https://www.mediawiki.org/wiki/Help:Formatting) markup for Markdown that's smaller and more widely used
2. Dump all wikitags, like "See Main Article: \<article\>" under a section heading
3. (Until they can be pre-rendered efficiently) Remove all citiations and references
4. Remove all pictures
5. Separate articles with sentinel bytes instead of XML tags

***Remains a WIP!***
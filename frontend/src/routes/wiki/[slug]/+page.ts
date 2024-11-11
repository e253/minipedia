import { error } from '@sveltejs/kit';
import type { PageLoad } from './$types';

import rehypeSanitize from "rehype-sanitize";
import rehypeStringify from "rehype-stringify";
import remarkParse from "remark-parse";
import remarkRehype from "remark-rehype";
import wikiLinkPlugin from 'remark-wiki-link';
import { unified } from "unified";

export const load: PageLoad = async ({ params }) => {
    const resp = await fetch(`/api/article/${params.slug}`)
    if (!resp.ok) {
        error(resp.status, 'Error encountered fetching article data.');
    }

    const markdown = await resp.text();

    const articleHtml = await unified()
        .use(remarkParse)
        .use(wikiLinkPlugin, { aliasDivider: "|", hrefTemplate: (permalink: string) => `/wiki/${permalink}` })
        .use(remarkRehype)
        .use(rehypeSanitize)
        .use(rehypeStringify)
        .process(markdown);

    return { articleHtml }
};
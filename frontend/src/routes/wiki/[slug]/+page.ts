import { error } from '@sveltejs/kit';
import type { PageLoad } from './$types';

import rehypeSanitize from "rehype-sanitize";
import rehypeStringify from "rehype-stringify";
import remarkParse from "remark-parse";
import remarkRehype from "remark-rehype";
import wikiLinkPlugin from 'remark-wiki-link';
import { unified } from "unified";

export const load: PageLoad = async ({ params }) => {
    const resp = await fetch(`/api/article?title=${params.slug}`)
    if (!resp.ok) {
        error(resp.status, await resp.text());
    }

    const markdown = await resp.text();

    const hrefTemplate = (permalink: string) => {
        console.log("link running on '", permalink, "'")
        return `/wiki/${permalink.replaceAll(/ /g, "_")}`
    };

    const pageResolver = (name: string) => {
        console.log("page resolving '", name, "'");
        return [name]
    };

    const articleHtml = await unified()
        .use(remarkParse, { gfm: true })
        .use(wikiLinkPlugin, { aliasDivider: "|", hrefTemplate, pageResolver }) // syntax is not faithful MW standard
        .use(remarkRehype)
        .use(rehypeSanitize)
        .use(rehypeStringify)
        .process(markdown);

    return { articleHtml }
};
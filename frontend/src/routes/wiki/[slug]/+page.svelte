<script lang="ts">
    import type { PageData } from "./$types";

    let { data }: { data: PageData } = $props();

    if (window.history.replaceState) {
        window.history.replaceState(
            undefined,
            data.title,
            `/wiki/${data.title}`,
        );
    }
</script>

<svelte:head>
    <link rel="stylesheet" href="/article.css" />
    <title>{data.title} - Minipedia</title>
</svelte:head>

<div class="flex flex-col justify-center items-center w-screen">
    <div class="py-4 max-w-prose-xl">
        <div class="w-full article-root" data-sveltekit-preload-data="false">
            {@html data.articleHtml}
        </div>
    </div>
</div>

<style>
    .max-w-prose-xl {
        max-width: 80ch;
    }
</style>

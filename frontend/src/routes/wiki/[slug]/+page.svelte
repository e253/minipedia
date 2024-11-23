<script lang="ts">
    import type { PageData } from "./$types";

    let { data }: { data: PageData } = $props();
</script>

<svelte:head>
    <link rel="stylesheet" href="/article.css" />
</svelte:head>

<div class="flex justify-center w-full">
    <div
        class="max-w-prose-xl article-root"
        data-sveltekit-preload-data="false"
    >
        {@html data.articleHtml}
    </div>
</div>

<style>
    .max-w-prose-xl {
        max-width: 80ch;
    }
</style>

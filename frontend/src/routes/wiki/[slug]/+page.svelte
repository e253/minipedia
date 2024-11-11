<script lang="ts">
    import type { PageData } from "./$types";

    let { data }: { data: PageData } = $props();
</script>

<div class="w-full flex justify-center">
    <div class="max-w-prose">
        <div id="article-html-container">
            {@html data.articleHtml}
        </div>
    </div>
</div>

<style>
    #article-html-container {
        all: revert;
    }
</style>

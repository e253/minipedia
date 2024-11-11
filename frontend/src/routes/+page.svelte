<script lang="ts">
    import { on } from "svelte/events";

    const focus = (e: HTMLInputElement) => {
        e.focus();
    };

    let results: { title: string; id: number }[] = $state([]);
    let input = $state("");
    let awaiting_response = false;
    $effect(() => {
        if (!awaiting_response) {
            // So the compiler knows input is a dependency of this effect
            console.log("Sending request on query", input);
            awaiting_response = true;
            setTimeout(async () => {
                const res = await fetch(`/api/search?q=${input}&l=10`);
                if (!res.ok) {
                    console.log(
                        "Fetch for search results failed with code",
                        res.status,
                    );
                } else {
                    results = await res.json();
                }
                awaiting_response = false;
            }, 250);
        } else {
            console.log("Not sending request for ", input);
        }
    });
</script>

<div
    class="w-full h-full flex flex-col items-center justify-center space-y-10 py-10"
>
    <h1 class="w-96 text-center">Minipedia</h1>
    <input
        class="outline-none bg-gray-200 py-2 px-5 w-96 rounded"
        use:focus
        bind:value={input}
        type="text"
        placeholder="Search Articles"
        id="search-input"
    />
    <div class="w-96 flex flex-col space-y-3">
        {#each results as result}
            <a href="/wiki/{result.id}">
                <div class="bg-gray-300 hover:bg-gray-100 p-2 rounded">
                    {result.title}
                </div>
            </a>
        {/each}
    </div>
</div>

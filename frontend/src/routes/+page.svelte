<script lang="ts">
    import Search from "../Icons/Search.svelte";

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
                    // TODO: Fire error modal when search fails.
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

<svelte:head>
    <title>Minipedia - The Tiny Encyclopedia</title>
</svelte:head>

<!--Screen Wrapper Pushes Items in a center column-->
<div class="flex flex-col items-center py-80 space-y-10 w-full h-screen">
    <!--Logo and Title-->
    <div class="flex justify-center items-center">
        <img src="/logo.svg" alt="Logo" class="w-32 h-32" />
        <div class="text-start">
            <h1 class="text-3xl font-md">Minipedia</h1>
            <h3 class="text-sm font-md text-neutral-500">
                The Tiny Encyclopedia
            </h3>
        </div>
    </div>
    <!--End Logo and Title-->

    <!--Search Container-->
    <div
        class="rounded-xl border-gray-200 w-128 outline outline-1 outline-neutral-200"
    >
        <div class="grid grid-cols-8 px-1">
            <div class="col-span-1 justify-self-center self-center">
                <Search />
            </div>
            <div class="col-span-7">
                <input
                    class="w-full h-14 outline-none"
                    use:focus
                    bind:value={input}
                    type="text"
                    placeholder="Search From 7,000,000 Million Articles"
                    id="search-input"
                />
            </div>
        </div>

        <hr class="neutral-200" />

        {#each results as result}
            <a href="/wiki/{result.id}">
                <div
                    class="grid grid-cols-8 auto-rows-auto p-1 h-10 rounded-lg hover:bg-neutral-200"
                >
                    <div class="col-span-1 justify-self-center self-center">
                        <Search />
                    </div>
                    <div class="col-span-7 self-center">
                        <div class="w-full rounded-xl hover:bg-neutral-200">
                            {result.title}
                        </div>
                    </div>
                </div>
            </a>
        {/each}
    </div>
    <!--End Search Container-->
</div>

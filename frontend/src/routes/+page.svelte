<script lang="ts">
    import Search from "../Icons/Search.svelte";

    const focus = (e: HTMLInputElement) => {
        e.focus();
    };

    let results: { title: string; id: number }[] = $state([]);
    let input = $state("");
    let abort_controller: AbortController | null = null;
    $effect(() => {
        if (abort_controller != null) {
            abort_controller.abort();
        }

        abort_controller = new AbortController();
        const signal = abort_controller.signal;

        const query = input;
        fetch(`/api/search?q=${query}&l=10`, { signal })
            .then((res) => {
                abort_controller = null;
                if (!res.ok) {
                    console.log(
                        "Fetch for search results failed with code",
                        res.status,
                    );
                } else {
                    res.json()
                        .then((v) => (results = v))
                        .catch((reason) =>
                            console.log(
                                "JSON parse of search results failed:",
                                reason,
                            ),
                        );
                }
            })
            .catch((reason) => console.log("Fetch had exception", reason));
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
            <a href="/wiki/{result.id}" data-sveltekit-preload-data="false">
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

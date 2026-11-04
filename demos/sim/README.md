# sim: a live world of alph actors

A 32 by 20 grid of 640 cell actors, drawn live in a MythicUI window with MistPlot charts.

Each cell holds an energy value. Every 40 ms it hands a share to its four neighbours, grows logistically toward its own capacity, and publishes its energy to a shared array. A dynamic supervisor with permanent restart keeps the cells alive. Nothing crashes by default. Raise the chaos rate, or press Crash storm, and a chaos actor crashes random cells (a message that makes the cell divide by zero) and the supervisor restarts them. A restarted cell starts at zero, flashes red on the heatmap and regrows from its neighbours.

32 client actors load the cells with requests. Each keeps up to 16 requests in flight to random cells, with `alph_request` and a 200 ms timeout, paced by an alph timer so that together they send the rate on the slider (0 to 100 000 per second, default 0). A cell answers with `alph_reply`. A client counts each request as answered (with its latency), failed (DOWN, because the cell crashed or was gone, or the mailbox was full) or timed out. A cell that is restarted mid-request makes that request fail with DOWN.

The window shows the heatmap on the left and five live charts on the right: total energy, messages per second, requests per second (answered, failed, timed out), request latency p50 and p99 in microseconds, and crashes and restarts per second. Controls: a chaos rate slider (0 to 200 crashes per second, default 0), a request rate slider, Pause world and Crash storm, which crashes 100 cells at once. Pause stops the cell ticks, the chaos actor (storm presses are ignored) and the clients. Latency is kept in a log2 histogram of microseconds, so p50 and p99 are the middle of a power-of-two bucket.

The alph schedulers run on their own threads. The UI thread only reads shared atomics, sets the request rate in one, and sends the chaos actor messages with `alph_node_send`. The charts are fed from the UI thread alone.

## Build and run

From the alph directory, with the Mettle compiler at `../Mettle/bin/mettle` and the `mythic_ui` and `mistplot` repositories next to alph:

    bash demos/sim/build.sh
    ./demos/sim/build/sim

Headless, for a check without a display: run for 3 seconds, write the last frame to a PNG and print one line of counts, including the requests answered, failed and timed out and p50 and p99 over the whole run.

    ./demos/sim/build/sim --snapshot out.png --seconds 3 --requests 50000 --rate 100

Other flags: `--storm` fires a crash storm halfway through, `--rate N` sets the starting chaos rate (default 0), `--requests N` the starting request rate (default 0), and `--stderr` keeps stderr. The Mettle runtime prints a stack trace to stderr for every crash it recovers from, so stderr goes to /dev/null otherwise.

## Files

- `world.mettle`: the cells, the chaos actor, the clients, the world actor and the shared atomics.
- `sim.mettle`: the window, the heatmap, the charts, the controls and the snapshot mode.
- `mettle.deps`: maps `alph`, `mythic` and `mistplot`.

# sim: a live world of alph actors

A 32 by 20 grid of 640 cell actors, drawn live in a MythicUI window with MistPlot charts.

Each cell holds an energy value. Every 40 ms it hands a share to its four neighbours, grows logistically toward its own capacity, and publishes its energy to a shared array. A dynamic supervisor with permanent restart keeps the cells alive. A chaos actor crashes random cells at a rate you set (a message that makes the cell divide by zero), and the supervisor restarts them. A restarted cell starts at zero, flashes red on the heatmap and regrows from its neighbours.

The window shows the heatmap on the left and live charts on the right: total energy, messages per second, crashes and restarts per second, and live actors. Controls: a chaos rate slider (0 to 200 crashes per second), Pause world, and Crash storm, which crashes 100 cells at once.

The alph schedulers run on their own threads. The UI thread only reads shared atomics and sends the chaos actor messages with `alph_node_send`. The charts are fed from the UI thread alone.

## Build and run

From the alph directory, with the Mettle compiler at `../Mettle/bin/mettle` and the `mythic_ui` and `mistplot` repositories next to alph:

    bash demos/sim/build.sh
    ./demos/sim/build/sim

Headless, for a check without a display: run for 3 seconds, write the last frame to a PNG and print one line of counts.

    ./demos/sim/build/sim --snapshot out.png --seconds 3

Other flags: `--storm` fires a crash storm halfway through, `--rate N` sets the starting chaos rate (default 25), and `--stderr` keeps stderr. The Mettle runtime prints a stack trace to stderr for every crash it recovers from, so stderr goes to /dev/null otherwise.

## Files

- `world.mettle`: the cells, the chaos actor, the world actor and the shared atomics.
- `sim.mettle`: the window, the heatmap, the charts, the controls and the snapshot mode.
- `mettle.deps`: maps `alph`, `mythic` and `mistplot`.

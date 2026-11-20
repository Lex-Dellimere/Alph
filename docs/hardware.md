# First run on real hardware

Nothing in alph has run on a real board yet. Everything below has run in QEMU. On the compiler's model of the Pico 2's chip, step 1 runs, and so do steps 2 and 3 with the computer's side played from a script over the chip's UART at 115,200 baud. In step 2 fifty messages go in and fifty answers come out. In step 3 the board says who does each kind of work, reads six angles, counts four chunks of primes, and makes a move once though it is asked for twice. The model finds nothing wrong in how the chip is used. This page is the order to try things in on a real Pico 2, what each step proves, and what to look at when a step fails. Each step uses only what the steps before it proved.

## What you need

- A Raspberry Pi Pico 2 and a USB cable.
- A 3.3 V USB serial adapter, or a Raspberry Pi Debug Probe. Not a 5 V adapter: the Pico's pins take 3.3 V.
- Three wires: ground to ground, the Pico's GP0 (its TX) to the adapter's RX, and the Pico's GP1 (its RX) to the adapter's TX.

UART0 on GP0 and GP1 at 115200 baud is the board's line. The USB cable only powers the board and loads the program. On the computer the adapter is `/dev/ttyUSB0` for most adapters and `/dev/ttyACM0` for the Debug Probe. Your user must be allowed to open it (the `dialout` group on most Linux systems).

To load a program, hold BOOTSEL while plugging the board in and copy the `.uf2` file onto the `RP2350` drive.

## When a step fails: look at the line

```bash
mettle --build -s --release examples/mcu/line_watch.mettle -I ports/host -o line_watch
./line_watch /dev/ttyUSB0 8 10
```

`line_watch` opens the line as the computer's side, prints every message the board sends with its parts, and once a second asks the board who does kinds 0 to 2, which any board running `AlphBoard` answers. The two numbers after the device are the board's place (8 in the arm example, 1 in the tether example) and how many seconds to watch. If nothing comes, the board is not running or the wires are wrong. If bytes come that are not whole messages, it shows them: a wrong speed looks like that. If answers come, the line is good and the fault is further up.

## Step 1: the board runs alph

```bash
mettle --release examples/mcu/blink.mettle --target riscv32-none --board pico2 --emit-flat blink.uf2 -I ports/pico2 -I ports/mcu
```

A timer sends a message to an actor every millisecond, and a second actor prints the count, 1 to 5. Open the serial device in a terminal program at 115200 baud to see it. This proves the image starts, the clocks and the timer come up, a timer interrupt arrives, and alph's core and timers run.

If nothing happens: the board start (`pico2_init`) or the trap set-up is where to look, and that is the compiler's side. Nothing of alph's has run before the first print.

## Step 2: the line carries messages

```bash
mettle --release examples/mcu/tether.mettle --target riscv32-none --board pico2 --emit-flat tether.uf2 -I ports/pico2 -I ports/mcu
mettle --build -s --release examples/mcu/tether_host.mettle -I ports/host -o tether_host
./tether_host /dev/ttyUSB0
```

The computer sends 200 requests and the board answers each. This proves bytes cross the line both ways unchanged, and that an actor on each side reaches one on the other by pid.

If it stops short: count what arrived. No answers at all is wiring (TX and RX swapped, no common ground) or the wrong device. Some answers lost is the line dropping bytes, which a plain line does not repair: go on with a sure line (`AlphTether_sure`) and see `tests/mcu/sure_board.mettle`.

## Step 3: the board is a place

```bash
mettle --release examples/mcu/arm.mettle --target riscv32-none --board pico2 --emit-flat arm.uf2 -I ports/pico2 -I ports/mcu
mettle --build -s --release examples/mcu/arm_host.mettle -I ports/host -o arm_host
./arm_host /dev/ttyUSB0
```

The computer asks for six joint angles, five moves and 200 chunks of primes, and never says where any is done. The angles and the moves can only be done on the board. This proves the board is found, takes work, and does a move at most once.

The computer prints how many of each the board did. In QEMU the board counts about 7 of the 200 chunks of primes and the computer the rest. A real board at 115200 baud should get fewer or none: alph times both and the line is slow.

## Step 4: two boards as one

```bash
mettle --release examples/mcu/two_a.mettle --target riscv32-none --board pico2 --emit-flat two_a.uf2 -I ports/pico2 -I ports/mcu
mettle --release examples/mcu/two_b.mettle --target riscv32-none --board pico2 --emit-flat two_b.uf2 -I ports/pico2 -I ports/mcu
```

Join the two boards: ground to ground, each board's GP0 to the other's GP1. Load `two_a.uf2` on one and `two_b.uf2` on the other. Each does one kind of work for the other and asks for the kind it cannot do. No computer is in between, so to watch it, put the adapter's RX on one board's GP0 as well and read the bytes that pass.

## What is most likely to differ from the emulators

- Timing. QEMU's serial line is instant and loses nothing. A real UART at 115200 baud carries about 11 bytes a millisecond, and a message is 12 to 15 bytes, so a round trip is at least 2.5 ms. The examples' timers allow for that, but it is the first thing to check when answers come late.
- Lost bytes. The board takes each byte in an interrupt as it arrives, also while a job runs. But a plain line repairs nothing: a damaged frame is dropped, and so is a message for a mailbox that is full (a board's mailbox holds 8). A sure line sends again what was lost.
- The random bits a board uses to number work done at most once (`alph_board_fresh`) come from the chip's ring oscillator, which the model does not have.

When something fails, the smallest program that shows it is the most useful thing to keep.

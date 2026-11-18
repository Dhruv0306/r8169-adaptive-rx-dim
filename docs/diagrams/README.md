# Diagrams

Ten diagrams explain how the project works. The first is a single overview with six boxes; each box has its own detail diagram, so no single picture has to show everything. The diagrams are Mermaid flowcharts: GitHub draws them in the page, and every one is also exported as SVG and PNG in [`img/`](img/) for slides and reports.

| # | Diagram | Shows | Read with |
|---|---|---|---|
| 0 | [Overview](00-overview.md) | The whole system as six boxes (A to F) and what flows between them | [Project explained](../project-explained.md) |
| 1 | [Poll and sampling](01-poll-and-sampling.md) | Box B: from the interrupt to a sample for DIM, with the single-packet guard | [Project explained, 5](../project-explained.md) |
| 2 | [DIM decision](02-dim-decision.md) | Box C: what the kernel's DIM library does with a sample, and the level table | [Project explained, 6](../project-explained.md) |
| 3 | [Apply the level](03-apply-level.md) | Box D: from a level to the bits written in `IntrMitigate` | [Project explained, 7](../project-explained.md) |
| 4 | [ethtool control](04-ethtool-control.md) | Box A: turning the mode on and off and keeping the static settings | [Project explained, 8](../project-explained.md) |
| 5 | [Lifecycle](05-lifecycle.md) | Box E: restart, link change, idle decay and teardown | [Project explained, 9](../project-explained.md) |
| 6 | [Locking](06-locking.md) | Box F: contexts, locks and what may call what | [Project explained, 10](../project-explained.md), [locking notes](../locking.md) |
| 7 | [Measurement setup](07-measurement-setup.md) | The two machines, the scripts and the data flow | [Setup and testing](../setup-and-testing.md), [results explained](../results-explained.md) |
| 8 | [Patch series and build](08-series-and-build.md) | The six patches, and build, sign and load | [Kernel changes](../kernel-changes.md), [setup and testing](../setup-and-testing.md) |
| 9 | [Phases](09-phases.md) | How the project was built, phase by phase | [Phase results](../results/) |

## How to read them

Start with [diagram 0](00-overview.md). Each box in it is named by a letter, and the table under the diagram names the detail diagram of that box. In the detail diagrams, a green or blue shaded step is new code or library code, and a yellow one is a register access.

## Where the diagrams are used

| Document | Uses |
|---|---|
| [Project explained](../project-explained.md) | Every diagram, one per section |
| [Results explained](../results-explained.md) | Diagram 0 to 7 and 9, to say where each result comes from |
| [Report](../report.md) | Diagram 0 in the summary, the detail diagrams in sections 3 to 5 |
| [Setup and testing](../setup-and-testing.md) | Diagrams 7, 8 and 9 |
| [Demo and questions](../demo-and-questions.md) | Diagram 0, and the detail diagram named in each answer |
| [Kernel changes](../kernel-changes.md) | Diagrams 0 and 8 |

## Changing or regenerating a diagram

Edit the ```` ```mermaid ```` block in the diagram's `.md` file, then regenerate the images:

```bash
mkdir -p /tmp/mm && cd /tmp/mm && npm init -y && npm i mermaid@11     # once
cd <repository root>
python3 scripts/render_diagrams.py /tmp/mm/node_modules/mermaid/dist/mermaid.min.js
```

The script needs the python `playwright` package with its Chromium. It stops with the file name when a block has a syntax error, and it rewrites `img/NN-*.svg` and `img/NN-*.png`. Commit the `.md` and the images together.

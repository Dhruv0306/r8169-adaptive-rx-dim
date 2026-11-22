# Documentation map

Where to find what. Start with the first table; the second lists the working documents of the project.

## Explanatory documents

| You want to | Read |
|---|---|
| Understand the project in detail: problem, background, design, every part of the code, why | [Project explained](project-explained.md) |
| See how it works in pictures | [Diagrams](diagrams/README.md), starting with the [overview](diagrams/00-overview.md) |
| Understand what was measured and what each result means | [Results explained](results-explained.md) |
| Read the course report | [Report](report.md) |
| See which kernel files were changed or created, and why | [Kernel changes](kernel-changes.md) |
| Know the exact hardware this was made and tested for | [Hardware](hardware.md) |
| Remove the modification from the PC after the demo | [Uninstall](uninstall.md) |
| Set the project up and test every phase | [Setup and testing](setup-and-testing.md) |
| See every test of a phase with its commands and results | [Test guides](tests-guides/), one per phase (0 to 5) |
| Run the demo and prepare for questions | [Demo and questions](demo-and-questions.md), [run sheet](demo.md) |
| See how the private repository was merged into the shared one | [Merge to the shared repository](merge-to-shared-repo.md) |

## Working documents

| Document | Content |
|---|---|
| [`plan.md`](plan.md), [`plans/`](plans/) | The design and the detailed plan of each phase |
| [`phases.md`](phases.md) | The phase list with a tracker of dates and outcomes |
| [`results/`](results/) | One results file per phase, with the original tables |
| [`locking.md`](locking.md) | Locking notes: contexts, locks, order, remaining races |
| [`handoff.md`](handoff.md) | Context for moving the project to a new chat or reader |
| [`figures/`](figures/) | Figures of the Phase 4 results |

## Suggested reading orders

- **To grasp the idea quickly (10 minutes):** [results explained, sections 1 and 2](results-explained.md), then [diagram 0](diagrams/00-overview.md).
- **To understand the code:** [project explained](project-explained.md) with the diagrams, then [kernel changes](kernel-changes.md) and the patches in `patches/`.
- **To reproduce the work:** [setup and testing](setup-and-testing.md).
- **To present it:** [demo and questions](demo-and-questions.md).

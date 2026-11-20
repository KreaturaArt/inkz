# inkz architecture

Eight diagrams of the code as it is. `docs/ArchitectureAndDevOverview.md` walks through the
same ground in prose; `docs/DODMigrationPlan.md` §4 records why it is built this way. File
names are under `src/` unless they say otherwise.

## 1. Pipeline

Two producers make the same immutable `Program` through one `ProgramBuilder`; stories run
it. A `Program` can be written back as inklecate's JSON.

```mermaid
flowchart LR
    ink[".ink files"] --> space["source_space<br/>files end to end,<br/>comments removed"]
    space --> parse["grammar<br/>(explicit-stack parser)"]
    parse --> sema["sema<br/>object tree"]
    sema --> resolve["resolve<br/>names, targets"]
    resolve --> lower["lower<br/>runtime IR, flatten, layout"]
    lower --> builder

    json[".ink.json<br/>(inklecate)"] --> loader["ink_json.load<br/>streaming, no tree"]
    loader --> builder

    builder["core/program_builder"] --> program[("Program<br/>immutable, shareable")]
    program --> serialize["ink_json.serialize"] --> json_out[".ink.json"]

    program --> story1["Story A<br/>State + Continue loop"]
    program --> story2["Story B"]
    story1 <--> host["host via inkz.Story<br/>(runtime/api.zig)"]
    story1 <--> save["save format v10<br/>to_json / load_json"]
```

## 2. The program image

`core/program.zig`. Everything is struct-of-arrays data addressed by `u32` index newtypes;
nothing is a pointer, and every target is resolved when the program is built.

```mermaid
classDiagram
    class Program {
        strings: FrozenStringPool
        instructions: MultiArrayList~Instruction~
        containers: MultiArrayList~ContainerInfo~
        named: []NamedEntry
        globals: []GlobalInfo
        list_origins: []ListOrigin
        list_items: []ListItem
        externals: []ExternalInfo
        global_declaration: ContainerIndex
        count_slots_count: u32
        ink_version: u32
        check() Fault
        verify()
    }
    class Instruction {
        opcode: Opcode (u8)
        operand: u32
    }
    class ContainerInfo {
        instruction_first: InstructionIndex
        instruction_count: u32
        parent: ContainerIndex
        index_in_parent: u32
        depth: u16
        flags: visits, turns, count_start_only
        name, path: StringId
        path_hash: u32
        named_first, named_count: u32
        count_slot: u32
    }
    class NamedEntry {
        name: StringId
        child: ContainerIndex
    }
    class ListItem {
        origin: ListOriginIndex
        name, full_name: StringId
        value: i32
    }
    class ExternalInfo {
        name: StringId
        fallback: ContainerIndex
    }
    class Extra {
        words: []u32
        divert targets and flags, choice points
    }
    Program "1" *-- "n" Instruction : 5 B each, one per ink content item
    Program "1" *-- "n" ContainerInfo : container 0 is the root
    ContainerInfo ..> Instruction : contiguous range
    ContainerInfo ..> NamedEntry : knots, stitches, labels
    Instruction ..> ContainerInfo : enter_container, divert targets
    Instruction ..> Extra : wide operands are an index here
    Program "1" *-- "n" ListItem
    Program "1" *-- "n" ExternalInfo
    Program "1" *-- "1" Extra
```

Opcodes group as content (`text`, `newline`, `glue`, `integer`, `float`, `bool`, `void`,
`divert_target`, `variable_pointer`, `list`, `tag`), control (`eval_start`, `string_start`,
`choice_count`, `random`, `start_thread`, `done`, `end`, `tag_start`, ...), ink's native
operators (`add` ... `list_invert`) and structure (`enter_container`, `divert`,
`call_external`, `choice_point`, variable reads and writes, `read_count`).

## 3. Compiler stages and their data

`compiler/compile.zig`. Each stage's output is index-addressed arrays. The object tree, the
resolution and the syntax tree are freed once lowering is done, before layout and emission.

```mermaid
flowchart TD
    subgraph parse["Parse (core.zig, grammar*.zig)"]
        source["one source buffer<br/>+ file table"] --> tokens["tokens on demand<br/>{tag, start, end}"]
        tokens --> ast["syntax tree (ast.zig)<br/>tag u8 + word u32 per node,<br/>children contiguous"]
    end
    subgraph middle["Object tree and resolution"]
        ast --> objects["sema.Tree<br/>ink's ParsedHierarchy:<br/>flows, weaves, choices, gathers"]
        objects --> resolution["resolve.Resolution<br/>declarations, divert targets,<br/>naming collisions"]
    end
    subgraph back["Lowering (lower*.zig)"]
        resolution --> ir["lower_ir: runtime container tree<br/>(GenerateRuntimeObject)"]
        ir --> flatten["count flags, FlattenContainersIn,<br/>termination checks"]
        flatten --> layout["lower_layout: container paths"]
        layout --> emit["lower_emit: ProgramBuilder calls,<br/>in the order the JSON loader makes them"]
    end
    emit --> program[("Program")]
    parse -. "a parse error stops here" .-> failed["error.CompileFailed"]
    resolution -. "resolution errors" .-> failed
```

## 4. The parser machine

`compiler/core.zig`. ink's backtracking `StringParser` rules, run on an explicit frame stack
instead of the native one. A rule is a step function with phases; each step returns an
`Action`.

```mermaid
stateDiagram-v2
    [*] --> Step: push frame(rule, checkpoint)
    Step --> Call: .call / .peek(rule)
    Call --> Step: push callee frame
    Step --> Again: .again (phase changed)
    Again --> Step
    Step --> Succeed: .succeed
    Step --> Fail: .fail
    Succeed --> Resume: pop frame, keep nodes<br/>(peek undoes the input)
    Fail --> Resume: pop frame, restore checkpoint<br/>(input, tokens, nodes, scratch)
    Resume --> Step: caller's next phase reads machine.outcome
    Resume --> [*]: stack empty
```

A checkpoint holds the input position and the token, node and scratch counts, so a failed
rule undoes everything since its call; diagnostics survive, as ink's do. Finished nodes sit
on a scratch stack until `wrap` moves a parent's children into one contiguous run. Frames
are bounded by `parse_depth_max` and steps by a gas counter proportional to the input; both
end in a diagnostic, not a crash.

## 5. One VM step

`runtime/vm.zig`: ink's `Step`, `NextContent` and `PerformLogicAndFlowControl`. The pointer
is `{container, index}` in the current frame. `run` repeats `step` until the output changes,
a choice appears, the flow ends, or the step budget runs out.

```mermaid
flowchart TD
    start(["step"]) --> null{"pointer null?"}
    null -- yes --> ended(["ended"])
    null -- no --> enter["enter_containers:<br/>follow enter_container at index 0,<br/>count each visit"]
    enter --> fetch{"instruction at pointer?"}
    fetch -- "past the end" --> next
    fetch -- yes --> perform["perform: native op, content,<br/>divert, choice_point, variables,<br/>external call or control op (ops.zig)"]
    perform --> next["next_content"]
    next --> diverted{"diverted pointer set?"}
    diverted -- yes --> jump["jump; visit containers<br/>changed by the divert"]
    diverted -- no --> inc{"index + 1 in the container?"}
    inc -- yes --> done(["signal to run()"])
    inc -- no --> pop{"function or thread<br/>to pop?"}
    pop -- yes --> next
    pop -- no --> done
    jump --> done
```

## 6. The Continue loop and newline lookahead

`runtime/story.zig` and `runtime/lookahead.zig`: ink's `ContinueInternal`. `cont()` returns
one line, but runs past its newline to see whether glue or tags extend it.

```mermaid
stateDiagram-v2
    [*] --> Running: cont() — clear output, batch observers
    Running --> Check: vm.run returns (output changed, choice, ended)
    Check --> Running: in string evaluation, or nothing new
    Check --> Snapshot: output ends in newline<br/>and can continue
    Snapshot --> Lookahead: copy live-flow prefixes,<br/>start the undo log
    Lookahead --> Check2: vm.run returns
    Check2 --> Lookahead: only whitespace after the newline
    Check2 --> Restore: new text or tags,<br/>or an unsafe external function
    Check2 --> Discard: glue removed the newline
    Discard --> Running
    Restore --> Finish: copy buffers back, undo the log,<br/>truncate the heap
    Check --> Finish: can't continue (choices, DONE, END,<br/>or out of content)
    Finish --> [*]: the cleaned line, report errors,<br/>notify queued observers
```

Every check needs the current line's cleaned text: ink's `CleanOutputWhitespace` over the
whole output stream. `runtime/text_cache.zig` (P10.1) keeps it between checks, with the
cleaner's state and a copy of the items it came from. While the output only grows and no
heap string changes (`StringHeap.generation`), only new items are cleaned. Any other change
cleans from the start: glue, trimming, `/str`, a restore, a flow switch, a load, heap
truncation or compaction. Debug builds compare every cached line with a full clean. Before
the cache, cleaning took about half of play time; with it, play is 1.5–1.8× faster.

While a snapshot is active, writes to shared arrays (globals, visit counts, turn indices,
the random state) go through the undo log, so a restore needs no copy of them. When the
pointer runs out, an all-invisible default choice is followed automatically; otherwise ink's
end-of-content errors and warnings are raised.

## 7. Memory

`runtime/state.zig`, `runtime/heap.zig`, `runtime/flows.zig`. `Story.init` makes one
allocation of exactly `Limits.bytes_total()` bytes and carves every buffer from it; nothing
allocates afterwards. Views returned to the host point into this block and are valid until
the next mutating call.

```mermaid
flowchart TB
    subgraph block["one allocation: Limits.bytes_total(shape)"]
        subgraph live["live flow"]
            evaluation["evaluation stack<br/>Value, 12 B"]
            calls["call stack: threads,<br/>frames (24 B), temps (16 B)"]
            output["output items (12 B),<br/>string marks"]
            choices["choices, choice tags,<br/>thread snapshots"]
        end
        subgraph shared["shared by all flows"]
            globals["globals + defaults"]
            counts["visit counts, turn indices"]
            heap["string heap + list slab<br/>sliding mark-compact"]
            diagnostics["errors, warnings,<br/>observers, observer queue"]
            line["text cache: cleaned line (the cont() view)<br/>+ its items; line bytes (scratch)"]
        end
        lookahead["lookahead copy of the live flow<br/>+ undo log (patch entries)"]
        parking["flow parking region<br/>(inactive flows, set-aside output)"]
        scratch["load scratch (save tokens),<br/>ancestor scratch"]
    end
    live -- "take / restore" --> lookahead
    live -- "switch_flow packs / unpacks used prefixes" --> parking
    heap -. "compaction roots: values in every box above" .- live
```

The heap is compacted only when an allocation doesn't fit. Compaction keeps allocation
order, so heap marks recorded by the lookahead snapshot stay valid after relocation.
Running out of any buffer returns a named error (`error.HeapLimit`, `error.FlowLimit`, ...).

Every buffer records its peak (P10.2). `Story.usage()` reports them, and `Limits.fitted(usage,
margin)` sizes a story's limits from them. The default budget is about 2.2 MB per story.
Fitted limits need about 40–50 KB for the stories measured, at the same speed, because play
speed doesn't depend on the budget.

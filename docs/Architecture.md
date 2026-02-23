# inkz Architecture

High-level diagrams for the Zig ink runtime and compiler. All diagrams use [Mermaid](https://mermaid.js.org/) syntax.

---

## 1. Full Pipeline Overview

The ink toolchain has two distinct stages: a **compiler** (`.ink` → `.json`) and a **runtime** (`.json` → story output).

```mermaid
flowchart LR
    subgraph Compiler["Stage 1 — Compiler (inkz)"]
        direction TB
        ink[".ink source\nfiles"]
        Tokenizer["Tokenizer\n(labeled switch)"]
        Parser["Recursive Descent\nParser"]
        ParsedAST["Parsed AST\nParsed.Story"]
        CodeGen["Code Generator\ngenerateRuntimeObject()"]
        RefResolve["Reference Resolver\nresolveReferences()"]
        JSON[".ink.json"]

        ink --> Tokenizer --> Parser --> ParsedAST --> CodeGen --> RefResolve --> JSON
    end

    subgraph Runtime["Stage 2 — Runtime"]
        direction TB
        JSONIn[".ink.json"]
        Loader["JSON Loader\nStory.initFromJson()"]
        StoryObj["Runtime.Story"]
        Engine["Step Loop\ncont() / step()"]
        Output["Text Output\n+ Choices"]

        JSONIn --> Loader --> StoryObj --> Engine --> Output
    end

    JSON -->|embed or load| JSONIn

    subgraph Host["Host Application"]
        Game["Game Loop\nchooseChoiceIndex()"]
    end

    Output --> Game
    Game -->|next turn| Engine
```

---

## 2. Runtime Object Model

The runtime is built from a single general-purpose `Container` type and a tagged union `RuntimeObject` for all content.

```mermaid
classDiagram
    class RuntimeObject {
        <<tagged union>>
        string_value : []const u8
        int_value    : i64
        float_value  : f64
        bool_value   : bool
        divert_target  : DivertTargetValue
        variable_pointer : VariablePointerValue
        control_command  : ControlCommand
        native_function  : NativeFunction
        divert             : Divert
        choice_point       : ChoicePoint
        variable_assignment : VariableAssignment
        variable_reference  : VariableReference
        void_value : void
        container  : *Container
    }

    class Container {
        +content        : []RuntimeObject
        +named_content  : StringHashMap(*Container)
        +name           : ?[]const u8
        +flags          : ContainerFlags
    }

    class ContainerFlags {
        <<bit flags>>
        visits        : 0x1
        turns         : 0x2
        count_start_only : 0x4
    }

    class Divert {
        +target_path      : Path
        +pushes_to_stack  : bool
        +stack_push_type  : PushPopType
        +is_conditional   : bool
        +is_external      : bool
        +external_args    : u32
    }

    class ChoicePoint {
        +path_on_choice   : Path
        +flags            : ChoiceFlags
    }

    class ControlCommand {
        <<enum>>
        eval_start / eval_end
        eval_output
        duplicate
        pop_evaluated_value
        begin_string / end_string
        choice_count
        turn_index
        turns_since
        visit_count
        sequence_shuffle_index
        start_thread
        done / end
        nop
    }

    Container "1" *-- "0..*" RuntimeObject : content
    Container "1" *-- "0..*" Container : named_content
```

---

## 3. Runtime State Machine

All mutable story state is isolated in `StoryState`, enabling save/load by serialising this struct to JSON.

```mermaid
classDiagram
    class Story {
        +main_content_container : Container
        +list_definitions : ListDefinitionsOrigin
        +state : StoryState
        +on_error : ?ErrorHandler
        ---
        +initFromJson(alloc, json) !Story
        +cont() ![]const u8
        +continueMaximally() ![]const u8
        +canContinue() bool
        +currentChoices() []Choice
        +chooseChoiceIndex(i) !void
        +choosePathString(path) !void
        +evaluateFunction(name, out, args) !?Value
        +bindExternalFunction(name, fn, opts) !void
        +observeVariable(name, cb) !void
    }

    class StoryState {
        +call_stack      : CallStack
        +output_stream   : ArrayList(RuntimeObject)
        +evaluation_stack : ArrayList(RuntimeObject)
        +current_choices : ArrayList(Choice)
        +variables_state : VariablesState
        +visit_counts    : StringHashMap(u32)
        +turn_indices    : StringHashMap(u32)
        +current_turn    : u32
        +story_seed      : u32
        +did_safe_exit   : bool
        ---
        +toJson(alloc) ![]u8
        +loadJson(json) !void
    }

    class CallStack {
        +threads         : ArrayList(Thread)
        +thread_counter  : u32
        ---
        +currentElement() *Element
        +push(type) !void
        +pop(type) !void
        +canPop(type) bool
    }

    class Thread {
        +call_stack      : ArrayList(Element)
        +thread_index    : u32
        +previous_pointer : Pointer
    }

    class Element {
        +type              : PushPopType
        +current_pointer   : Pointer
        +in_expression_evaluation : bool
        +temporary_variables : VariablesState
    }

    class PushPopType {
        <<enum>>
        tunnel
        function
    }

    class VariablesState {
        +globals     : StringHashMap(RuntimeObject)
        +patch       : ?StatePatch
        +variable_changed_event : ?Callback
        ---
        +get(name) ?RuntimeObject
        +set(name, val) !void
    }

    class Choice {
        +text            : []const u8
        +source_path     : []const u8
        +target_path     : Path
        +tags            : [][]const u8
        +index           : u32
    }

    Story       *-- StoryState
    StoryState  *-- CallStack
    StoryState  *-- VariablesState
    StoryState  *-- "0..*" Choice
    CallStack   *-- "1..*" Thread
    Thread      *-- "0..*" Element
    Element      --> PushPopType
```

---

## 4. Parser Architecture

The parser is a hand-written recursive descent parser. The tokenizer uses Zig's labeled `switch` for zero-cost dispatch.

```mermaid
flowchart TD
    subgraph Tokenizer
        src["[]const u8\nsource bytes"]
        LSW["labeled switch\n(:tok switch token_type)"]
        Tokens["Token stream\nToken{ .tag, .loc }"]
        src --> LSW --> Tokens
    end

    subgraph StringParser["StringParser (base)"]
        SP["parseString / parseInt\nparseSingleCharacter\nsave() / restore()"]
        Combinators["Combinators\noneOrMore / interleave\nspaced / exclude / string"]
    end

    subgraph InkParser["InkParser (extends StringParser)"]
        TopLevel["parse() → Parsed.Story"]
        KnotRule["knotDefinition()"]
        StitchRule["stitchDefinition()"]
        ChoiceRule["choiceDefinition()"]
        ExprRule["expression()"]
        DivertRule["divert()"]
        TopLevel --> KnotRule
        TopLevel --> StitchRule
        KnotRule --> StitchRule
        KnotRule --> ChoiceRule
        StitchRule --> ChoiceRule
        StitchRule --> DivertRule
        ChoiceRule --> ExprRule
    end

    Tokens --> SP
    SP --> Combinators
    Combinators --> InkParser

    subgraph ParsedAST["Parsed AST"]
        PS["Parsed.Story"]
        PK["Parsed.Knot"]
        PSt["Parsed.Stitch"]
        PC["Parsed.Choice"]
        PD["Parsed.Divert"]
        PE["Parsed.Expression"]
        PS --> PK --> PSt --> PC
        PSt --> PD
        PC --> PE
    end

    TopLevel --> PS
```

---

## 5. Code Generation & Reference Resolution

Two-pass code generation converts the parsed AST into the flat, container-based runtime format.

```mermaid
sequenceDiagram
    participant P as Parsed.Story
    participant CG as generateRuntimeObject()
    participant RC as Runtime.Container
    participant RR as resolveReferences()
    participant RS as Runtime.Story

    P->>CG: exportRuntime(allocator)
    loop for each Parsed.Object
        CG->>RC: create Runtime.Object(s)
        Note over CG,RC: Knots/Stitches/Choices → nested Containers
    end
    CG->>RS: assemble root container

    P->>RR: resolveReferences(context)
    loop for each Parsed.Divert / Parsed.Choice
        RR->>RC: patch target_path from name → runtime Path
    end
    RR-->>RS: fully linked Runtime.Story
```

---

## 6. Step Loop & Evaluation Model

The runtime evaluation model: content flows to `output_stream`; logic flows through `evaluation_stack`.

```mermaid
flowchart TD
    cont["cont()"] --> loop{"canContinue?"}
    loop -->|yes| step["step()"]
    loop -->|no| tryDefault["tryFollowDefaultInvisibleChoice()"]
    tryDefault -->|found| step
    tryDefault -->|not found| done(["return output_stream text"])

    step --> advance["advance current_pointer\nget current_object"]
    advance --> classify{object type?}

    classify -->|StringValue| appendOut["append to output_stream"]
    classify -->|ControlCommand| handleCmd["performLogicAndFlowControl()"]
    classify -->|Divert| jump["update current_pointer\n(may push callstack)"]
    classify -->|ChoicePoint| addChoice["build Choice\nappend to current_choices"]
    classify -->|NativeFunction| evalFn["pop args from eval_stack\npush result"]
    classify -->|VariableAssignment| setVar["write to variables_state"]
    classify -->|VariableReference| pushVar["push value to eval_stack"]

    handleCmd --> evalMode{in eval mode?}
    evalMode -->|yes → eval_start| pushEval["push to evaluation_stack"]
    evalMode -->|no → eval_output| moveOut["pop eval_stack → output_stream"]
    evalMode -->|done/end| exitFlow["mark safe exit / end story"]

    appendOut --> loop
    jump --> loop
    addChoice --> loop
    evalFn --> loop
    setVar --> loop
    pushVar --> loop
    pushEval --> loop
    moveOut --> loop
```

---

## 7. Compiler Stage 2 — Tokenizer (Labeled Switch)

The compiler tokenizer uses Zig's labeled `switch` (`continue :tok`) for a tight, branch-prediction-friendly dispatch loop with no heap allocation.

```mermaid
flowchart LR
    subgraph LabeledSwitch[":tok labeled switch loop"]
        direction TB
        start(["pos = 0"])
        read["ch = source[pos]"]
        sw{"switch ch"}

        start --> read --> sw

        sw -->|'='| scanKnot["scan knot/stitch/function\n→ .knot_marker / .stitch_marker"]
        sw -->|'*' '+' '-'| scanBullet["scan choice/gather bullet\n→ .choice / .gather"]
        sw -->|'{'| scanBrace["scan inline logic\n→ .left_brace"]
        sw -->|'/'| scanComment["check // or /*\n→ .comment / skip"]
        sw -->|'"'| scanStr["scan string literal\n→ .string"]
        sw -->|'~'| scanLogic["scan logic line\n→ .tilde"]
        sw -->|'<' '>'| scanGlue["scan glue / comparison\n→ .glue / .lt / .gt"]
        sw -->|'a'..'z' 'A'..'Z'| scanIdent["scan identifier/keyword\n→ .identifier / .keyword_*"]
        sw -->|'0'..'9'| scanNum["scan integer/float\n→ .int / .float"]
        sw -->|'\\n'| scanNL["emit .newline\nadvance line counter"]
        sw -->|else| scanText["accumulate plain text\n→ .text"]

        scanKnot --> emit["emit Token{ .tag, .loc }"]
        scanBullet --> emit
        scanBrace --> emit
        scanComment --> emit
        scanStr --> emit
        scanLogic --> emit
        scanGlue --> emit
        scanIdent --> emit
        scanNum --> emit
        scanNL --> emit
        scanText --> emit

        emit -->|"continue :tok"| read
        emit -->|"pos >= source.len"| done(["→ .eof"])
    end
```

---

## 8. Memory Strategy

The runtime is designed to minimise heap allocation during story evaluation.

```mermaid
flowchart TD
    subgraph Arenas["Allocator Strategy"]
        GA["GeneralPurposeAllocator\nor ArenaAllocator"]
        StoryArena["Story Arena\n(freed on story.deinit)"]
        StateArena["State Arena\n(freed on state reset / save-load)"]
        TurnArena["Turn Arena\n(freed each cont() call)"]
    end

    GA --> StoryArena
    GA --> StateArena
    GA --> TurnArena

    subgraph Owned["Owned at each level"]
        StoryArena --> SC["Static content:\nContainers, Strings,\nList definitions"]
        StateArena --> SS["Mutable state:\nCallStack, VariablesState,\nVisit counts"]
        TurnArena --> SO["Per-turn output:\ntext lines, choice text,\ntag slices"]
    end

    note1["❌ No allocation inside step()\nfor hot-path string operations"]
    note2["✅ Output strings are slices\ninto the source JSON or intern pool"]
    TurnArena -.-> note1
    StoryArena -.-> note2
```

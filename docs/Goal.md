# 6.3.2026

We now want to perform a change to the architecture.

Reade through the following section and perform the change to the runtime first. The compiler is just explained to give a better understanding of the final architecture and goal. Update all docs to reflect the following change in architecture:

### Ink Compiler

From .ink we want to create an optimized Data Oriented Programming AST.

The AST should have a serialization function that generates the standardized .ink.json files, we have a full set of fixture types for both input and output.

### Ink Runtime

The runtime should deserialize the .ink.json file into the same Data Oriented Programming AST.

The runtime should not have any dynamic memory allocation at runtime, all memory allocation should happen at startup or during the parsing & processing of the input files.

# 23.2.2026

In this project we want to create a zig 0.16 rewrite of Ink is inkle's scripting language
for writing interactive narrative, both for text-centric games as well as more graphical
games that contain highly branching stories.

To start off we only want to focus on @docs/ create comprehensive documentation and plan the project.

In a first stage we want to create a plan for a Fully-featured and highly efficient Ink runtime that minimizes runtime memory allocation.
We want to break down this task in as many tasks as necesarry.
Even in the planning we want to keep a high emphasis on test driven development, an implementation task is only considered complete if one or more unit tests validate the success criteria.

In the second stage we want to create a plan for a compiler that replaces Inklecate and follows zig best practices (labeled switch tokenizer).

We have a fully featured test suite in @test/fixture/ folder.
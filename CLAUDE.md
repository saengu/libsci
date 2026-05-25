# Project Overview
This project is aim to build reusable shared library babashka/sci for different os and architecture.
It could be used as prebuilt dynamic library to embed into other host language, like zig, swift, rust
 and go, to provide extenstion ability.

# Tech Stack
1. babashka/sci
2. Java
3. GraalVM 23 Comminity Edition to build native image

# Project Structure
- `/sci`: babashka/sci project as submodule and also the working directory.
- `/patches`: Keep changes for sci submodule.
- `/.github`: Github Workflow for build and release action.
- `/tests`: integration test.
- `examples`: usage examples.

# Coding Conventions
**TEST-DRIVEN DEVELOPMENT IS NON-NEGOTIABLE**


# Common Commands
**Build**: `bb libsci:compile` 
**Generate patch**: `git diff > ../patches/changes.patch`
**Apply patch**: `git apply ../patches/changes.patch`
**Run integration test**: `./scripts/run-tests.sh`

# Rules

- DO NOT commit changes to sci submodule, save all changes to patch instead and apply the patch before build.
- DO NOT modify patch file directly, apply patch to sci submodule and make changes on sci submoule, then regerneate patch.
- **No Implementation First**: Do not write code to solve a problem before writing the corresponding failing test.
- **Over-Engineering**: Do not write code for hypothetical future requirements. Only write what satisfies the current test.
- **Fragile Tests**: Write tests that verify observable *behavior* and outputs, rather than internal implementation details. 


# Current Focus
- Add interfaces to sci to support load scripts from host lanage and call functions or use variables defined in loaded scripts.
- Support invoking functions defined in host language from loaded script.
    - Use one function in host lanaguage to dispatch calls from scripts.
    - Use JSON format as protocol to communicate between host language and script.

# The lab orc. The recipes live in the `lab` module (lab.just).
#   just lab rung N      print the instructions for rung N
#   just lab check N     run the check for rung N, or `all`
#   just lab report N    post the report for rung N
# `just --list --list-submodules` shows them.

mod lab

default:
    @just --list --list-submodules

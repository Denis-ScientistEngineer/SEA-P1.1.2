# bspec.jl
# ── Root module — include this single file to load the entire B-SPEC system ──
#
# Usage from REPL:
#   include("bspec.jl")
#   using .BSPEC
#
# Usage from another file:
#   include("bspec.jl")
#   using .BSPEC: parse_request, dispatch, validate_solver_entry
#
# Every sub-module uses `..` to reference siblings, which resolves to BSPEC —
# never to Main. This is why all includes must live inside this module block.

module BSPEC

# All includes are anchored to this file's own directory via @__DIR__, so
# `bspec.jl` loads correctly regardless of the working directory Julia was
# started from, and regardless of whether the project is organised flat or
# with sub-folders — as long as every file below lives next to bspec.jl.
const _DIR = @__DIR__

include(joinpath(_DIR, "command_parser.jl"))
include(joinpath(_DIR, "solver_registry.jl"))
include(joinpath(_DIR, "dispatcher.jl"))
include(joinpath(_DIR, "solver_contract.jl"))
include(joinpath(_DIR, "dispatch_contract.jl"))
include(joinpath(_DIR, "electric_field_solver.jl"))

# Re-export the public surface so callers can write:
#   using .BSPEC: parse_request, dispatch, ...
# without knowing which sub-module owns each name.
using .CommandParser:    parse_request, ParsedRequest, VarValue
using .SolverRegistry:   register_solver!, get_solver, list_solvers,
                         list_domain_solvers, SolverEntry, SolverVariant, REGISTRY
using .Dispatcher:       dispatch, DispatchResult, DispatchError,
                         RegistryLookupResult, VariantSelectionResult, SolverInvocationResult,
                         register_dispatch_type!, is_registered_dispatch_type, list_dispatch_types
using .SolverContract:   validate_solver_entry, ContractViolation
using .DispatchContract: validate_dispatch_type, DispatchContractViolation

export parse_request, ParsedRequest, VarValue,
       register_solver!, get_solver, list_solvers, list_domain_solvers,
       SolverEntry, SolverVariant, REGISTRY,
       dispatch, DispatchResult, DispatchError,
       RegistryLookupResult, VariantSelectionResult, SolverInvocationResult,
       register_dispatch_type!, is_registered_dispatch_type, list_dispatch_types,
       validate_solver_entry, ContractViolation,
       validate_dispatch_type, DispatchContractViolation

end # module BSPEC
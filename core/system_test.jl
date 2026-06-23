# system_test.jl
# ── Verifies CommandParser → Dispatcher → ElectricFieldSolver end-to-end ──
# ── Validates ElectricFieldSolver against the SolverContract                ──
# ── Validates every pipeline-stage type against the DispatchContract        ──
#
# Run from the B-SPEC root with:
#   julia --project system_test.jl
# or from the REPL:
#   include("system_test.jl")

include(joinpath(@__DIR__, "bspec.jl"))

using .BSPEC: parse_request, dispatch, DispatchResult, DispatchError,
              get_solver, list_solvers, validate_solver_entry,
              RegistryLookupResult, VariantSelectionResult, SolverInvocationResult,
              list_dispatch_types, validate_dispatch_type

# ── Helpers ──────────────────────────────────────────────────────────────────

function run_test(label::String, input::String)
    println("\n[$label]")
    println("  Input : $input")
    req = parse_request(input)
    if req === nothing
        println("  PARSE FAIL — parse_request returned nothing")
        return
    end
    result = dispatch(req)
    if result.success
        println("  Solved : $(result.solves_for) = $(result.value)")
        println("  Via    : $(result.description)")
    else
        println("  DISPATCH FAIL — $(result.error_msg)")
    end
end

# ── Contract Validation ───────────────────────────────────────────────────────

println("\n=== Contract validation ===")
let entry = get_solver(:Electromagnetism, :Electrostatics, :ElectricField)
    if entry === nothing
        println("  FAIL — ElectricField entry not found in registry")
    else
        violations = validate_solver_entry(entry)
        if isempty(violations)
            println("  PASS — ElectricFieldSolver satisfies all contract rules")
            println("  $(length(entry.variants)) variants registered")
        else
            println("  FAIL — $(length(violations)) contract violation(s):")
            for v in violations
                println("    • [$(v.variant)] $(v.rule)")
            end
        end
    end
end

# ── Dispatch Pipeline Contract Validation ────────────────────────────────────

println("\n=== Dispatch pipeline type validation ===")
println("  Registered pipeline types: $(join(nameof.(list_dispatch_types()), ", "))")

for T in (RegistryLookupResult, VariantSelectionResult, SolverInvocationResult, DispatchResult)
    violations = validate_dispatch_type(T)
    if isempty(violations)
        println("  PASS — $(nameof(T)) satisfies the dispatch contract")
    else
        println("  FAIL — $(nameof(T)) has $(length(violations)) violation(s):")
        for v in violations
            println("    • $(v.rule)")
        end
    end
end

# ── Registered Solvers ────────────────────────────────────────────────────────

println("\n=== Registered solvers ===")
for s in list_solvers()
    println("  $(s.regime) / $(s.domain) / $(s.field)")
end

# ── Smoke Tests ──────────────────────────────────────────────────────────────

# 1. Point-charge field — solve for E given q and r
run_test("E from q and r",
    "[Electromagnetism] [Electrostatics] [Electric Field] calculate : q=1.6e-19, r=1e-10")

# 2. Point-charge field — solve for r given E and q (inverse)
run_test("r from E and q",
    "[Electromagnetism] [Electrostatics] [Electric Field] calculate : E=1.44e10, q=1.6e-19")

# 3. Force on test charge — solve for E given F and q
run_test("E from F and q",
    "[Electromagnetism] [Electrostatics] [Electric Field] calculate : F=3.2e-9, q=2e-9")

# 4. Force on test charge — solve for F given E and q
run_test("F from E and q",
    "[Electromagnetism] [Electrostatics] [Electric Field] calculate : E=1000.0, q=1.6e-19")

# 5. Uniform field (parallel plates) — solve for E given V and d
run_test("E from V and d",
    "[Electromagnetism] [Electrostatics] [Electric Field] calculate : V=120.0, d=0.01")

# 6. Uniform field — solve for V given E and d
run_test("V from E and d",
    "[Electromagnetism] [Electrostatics] [Electric Field] calculate : E=12000.0, d=0.01")

# 7. Surface charge density — solve for E given sigma
run_test("E from sigma",
    "[Electromagnetism] [Electrostatics] [Electric Field] calculate : sigma=1e-6")

# 8. Deliberate failure — unregistered solver
run_test("Unknown solver (expected fail)",
    "[Electromagnetism] [Electrostatics] [Capacitance] calculate : C=1e-6, V=5.0")

# 9. Deliberate failure — no matching variant (missing variable)
run_test("No matching variant (expected fail)",
    "[Electromagnetism] [Electrostatics] [Electric Field] calculate : V=120.0")

# 10. Physics guard — r = 0 (field undefined at source location)
run_test("r=0 physics guard (expected fail)",
    "[Electromagnetism] [Electrostatics] [Electric Field] calculate : q=1.6e-19, r=0.0")

# 11. Dispatcher robustness — calling dispatch() on a totally unregistered
#     type must produce a typed DispatchError, never a raw Julia MethodError.
println("\n[Unregistered type fallback]")
struct _NotAPipelineStage
    junk :: Int
end
fallback_result = dispatch(_NotAPipelineStage(42))
println("  Result : $(fallback_result)")
@assert fallback_result isa DispatchError "Expected DispatchError, got $(typeof(fallback_result))"
println("  PASS — unregistered type handled without crashing")

println("\n=== Done ===")
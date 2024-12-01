module JiL
export debug_lisp_to_julia, install_jil_parser, restore_julia_parser, tojulia
include("List.jl")
include("ToJulia.jl")
include("JiLParser.jl")

__init__() = begin
  install_jil_parser() # Let's have the parser ready
  include(joinpath(@__DIR__, "Boot0.jil")) # Defines primitive operations (car, cdr, null?, defmacro, etc)
  include(joinpath(@__DIR__, "Boot1.jil")) # Defines useful macros that use the primitives (cond, macroexpand, etc)
end
end

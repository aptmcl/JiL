abstract type Scope end

struct GlobalScope <: Scope
  defs::Dict{Symbol, Any}
end

const global_scope = GlobalScope(Dict{Symbol, Any}())

print_scope_defs(defs) = begin
  for (k, v) in defs
      println("  [$k => $v]")
    end
end

Base.show(io::IO, scope::GlobalScope) =
  begin
    println(io, "Scope:")
    print_scope_defs(scope.defs)
  end

struct LocalScope <: Scope
  parent::Scope
  defs::Dict{Symbol, Any}
end

Base.show(io::IO, scope::LocalScope) =
  begin
    show(io, scope.parent)
    println(io, "  ------")
    print_scope_defs(scope.defs)
  end

new_scope(names, inits, parent) =
  LocalScope(parent, Dict{Symbol, Any}(name=>init for (name, init) in zip(names, inits)))

add_binding!(name, init, scope) =
  scope.defs[name] = init

get_binding(name, scope::GlobalScope) =
  get(scope.defs, name) do
    #This is used to detect JiL macros, so I'm not sure it makes sense to search 
    #for Julia bindings, as they might not even exist yet.
    nothing
    #=let token = string(name)
      '.' in token ?
        let (modname, name) = split(token, '.')
          getglobal(eval(Symbol(modname)), Symbol(name))
        end :
      getglobal(Main, name)
    end =#
  end

get_binding(name, scope::LocalScope) =
  get(scope.defs, name) do
    get_binding(name, scope.parent)
  end

# functions
struct JiLFunction
  scope
  parameters
  body
end

Base.show(io::IO, f::JiLFunction) =
  begin
    println(io, "(lambda $(f.parameters) -> $(f.body))")
  end

# Currying
tojulia(scope::Scope) = form -> tojulia(form, scope)

tojulia(form) = tojulia(form, global_scope)

tojulia(form::Any, scope) = form

tojulia(form::Symbol, scope) = 
  let token = String(form)
    '.' in token ?
      let (pkg, name) = split(token, '.')
        Expr(:., Symbol(pkg), QuoteNode(Symbol(name)))
      end :
      form
  end

tojulia(form::Nil, scope) = form

tojulia(form::Cons, scope) =
  let head = form.head,
      tail = form.tail
    if head isa Symbol
      tojulia(Val{head}(), tail, scope) # To dispatch on the operator
    elseif head isa Cons
      Expr(:call, tojulia(head, scope), tojulia_vector(tail, scope)...)
    else
      error("Unknown form  $form")
    end
  end

# Fallback: everything is treated as a function/macro call.
tojulia(::Val{op}, args, scope) where {op} =
  op isa Symbol && String(op)[1] == '@' ? #julia macro
    Expr(:macrocall, tojulia(op, scope), LineNumberNode(1, :JiL), tojulia_vector(args, scope)...) :
    let init = get_binding(op, scope)
      init isa JiLMacro ?
        tojulia(jil_macroexpand(init, args, scope), scope) :
        Expr(:call, tojulia(op, scope), tojulia_vector(args, scope)...)
    end

tojulia(::Val{:(...)}, (name,), scope) =
  Expr(:(...), tojulia(name, scope))

tojulia(::Val{:kw}, (name, init), scope) =
  Expr(:kw, tojulia(name, scope), tojulia(init, scope))

tojulia_vector(val, scope) =
  collect(Any, map(tojulia(scope), val))

tojulia_tuple(val, scope) =
  tuple(tojulia_vector(val, scope)...)

tojulia(::Val{:quote}, (expr,), scope) =
  QuoteNode(expr)

tojulia(::Val{:quasiquote}, (expr, ), scope) =
  tojulia(expand_quasiquote(list(:quasiquote, expr)), scope)

tojulia(::Val{:(=)}, args, scope) =
  :(==($(tojulia_vector(args, scope)...)))

# Parameters
# Given that parameters might refer to the previous ones, this needs to incrementally extend the scope
tojulia_parameters(parameters, scope) =
  isempty(parameters) ?
    ([], scope) :
    let (p, ps...) = parameters
      p isa Cons && p.head === :parameters ? # We need to process the rest first
        let (params, scope) = tojulia_parameters(ps, scope),
            (param, scope) = tojulia_parameter(p, scope)
          ([param, params...], scope)
        end :
        let (param, scope) = tojulia_parameter(p, scope),
            (params, scope) = tojulia_parameters(ps, scope)
          ([param, params...], scope)
        end
    end
      
tojulia_parameter(name::Symbol, scope) =
  tojulia(name, scope), 
  new_scope([name], [missing], scope)

tojulia_parameter(p::Cons, scope) =
  tojulia_parameter(Val{p.head}(), p.tail, scope)

tojulia_parameter(::Val{:(...)}, (name,), scope) =
  Expr(:(...), tojulia(name, scope)),
  new_scope([name], [missing], scope)

tojulia_parameter(::Val{:kw}, (name, init), scope) =
  Expr(:kw, tojulia(name, scope), tojulia(init, scope)),
  new_scope([name], [init], scope)

tojulia_parameter(::Val{:parameters}, parameters, scope) =
  let (params, scope) = tojulia_parameters(parameters, scope)
    Expr(:parameters, params...), scope
  end

tojulia(::Val{Symbol("&key")}, expr, scope) =
  let key_params = [p isa Cons && !(p.head === :(...)) ?
                      Expr(:kw, tojulia(p.head, scope), tojulia(p.tail.head, scope)) :
                      tojulia(p, scope)
                    for p in expr]
    Expr(:(parameters), key_params...)
  end

# Anonymous functions
tojulia(::Val{:λ}, (params, body), scope) = 
  tojulia(Val{:lambda}(), (params, body))

tojulia(::Val{:lambda}, (parameters, body), scope) =
  let (params, scope) = tojulia_parameters(parameters, scope)
    :(($(params...),) -> $(tojulia(body, scope)))
  end

# Definitions
tojulia(::Val{:def}, (sig, init), scope) =
  if sig isa Symbol
    let val = tojulia(init, scope)
      add_binding!(sig, val, scope)
      :($(tojulia(sig, scope)) = $val)
    end
  elseif sig isa Cons
    if sig.head isa Symbol # A named function definition
      let (name, parameters, body) = (sig.head, sig.tail, init),
          (params, body_scope) = tojulia_parameters(sig.tail, scope)
        add_binding!(name, JiLFunction(params, body, scope), scope)
        :($(tojulia(name, scope))($(params...),) = $(tojulia(body, body_scope)))
      end
    else
      tojulia(list(:def, head(sig), list(:lambda, tail(sig), init), scope))
    end
  else
    error("Unknown form $(list(:def, sig, init))")
  end

# Conditional expressions
tojulia(::Val{:if}, (cond, conseq, altern), scope) =
  :($(tojulia(cond, scope)) ? $(tojulia(conseq, scope)) : $(tojulia(altern, scope)))


# Macros
# For now, nothing fancy, no phases, no hygiene, just CL-like macros
struct JiLMacro
  scope
  parameters
  body
  expander
end

Base.show(io::IO, m::JiLMacro) =
  begin
    println(io, "(macro $(m.parameters) -> $(m.body))")
  end

maybe_adjust_to_varargs(params, body) =
  isempty(params) ?
    body :
    let param = last(params)
      param isa Cons && param.head === :(...) ?
        let name = param.tail.head
          list(:let, list(list(name, list(:convert, :List, name))), body)
        end :
        body
    end

tojulia(::Val{:macro}, (params, body), scope) =
  #The use of eval makes the macro belong to a different world => invokelatest
  let expander = :(($(tojulia_vector(params, scope)...),) -> $(tojulia(maybe_adjust_to_varargs(params, body), scope)))
    debug_lisp_to_julia && println(" => ", expander)
    JiLMacro(scope, params, body, eval(expander))
  end

isa_jil_macro(val) =
  val isa JiLMacro  

jil_macroexpand(jilmacro, args, scope) =
  Base.invokelatest(jilmacro.expander, args...) # The macro was compiled in an older world


# Globals
tojulia(::Val{:global}, (form, ), scope) = 
  :(global $(tojulia(form, scope)))

# Modules
tojulia(::Val{:using}, (form, ), scope) =
  :(using $(tojulia(form, scope)))

# Blocks
tojulia(::Val{:begin}, forms, scope) =
  :(begin $(tojulia_vector(forms, scope)...) end)

remove_macro_bindings(names, inits) =
  let names_inits = [(name, init) for (name, init) in zip(names, inits) if !isa_jil_macro(init)], 
      let_names = map(t->t[1], names_inits),
      let_inits = map(t->t[2], names_inits)
    (let_names, let_inits)
  end

# Local scopes
tojulia(::Val{:let}, (binds, body...), scope) =
  let names = tojulia_tuple(map(head, binds), scope),
      inits = tojulia_tuple(map(head ∘ tail, binds), scope),
      scope = new_scope(names, inits, scope),
      (let_names, let_inits) = remove_macro_bindings(names, inits) # We don't need the macros in the generated Julia code.
    :(let ($(let_names...),) = ($(let_inits...),)
      $(tojulia_vector(body, scope)...)
      end)
  end

tojulia(::Val{Symbol("let*")}, (binds, body...), scope) =
  let tojulia_binds(binds, scope) = 
        isempty(binds) ?
          ([], scope) :
          let bind = head(binds),
              name = tojulia(head(bind), scope),
              init = tojulia(head(tail(bind)), scope),
              scope = new_scope([name], [init], scope),
              (julia_binds, scope) = tojulia_binds(tail(binds), scope)
            isa_jil_macro(init) ? # We don't need the macros in the generated Julia code.
              (julia_binds, scope) :
              ([:($(name) = $(init)), julia_binds], scope)
          end
    let (julia_binds, scope) = tojulia_binds(binds, scope)
      :(let $(julia_binds)
         $(tojulia_vector(body, scope)...)
        end)
    end
  end

tojulia(::Val{:and}, exprs, scope) =
  Expr(:&&, tojulia_vector(exprs, scope)...)
  
tojulia(::Val{:or}, exprs, scope) =
  Expr(:||, tojulia_vector(exprs, scope)...)

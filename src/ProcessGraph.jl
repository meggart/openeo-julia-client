using OrderedCollections

function flatten!(g::AbstractProcessNode, root_id, nodes=OrderedSet{ProcessNode}())
    arguments_nodes = filter(((k, v),) -> v isa ProcessNode, g.arguments)

    # post order tree traversal
    for (key, child) in arguments_nodes
        flatten!(child, root_id, nodes)
        g.arguments[key] = ProcessNodeReference(child.id)
    end

    union!(nodes, OrderedSet([v for (k, v) in arguments_nodes]))

    if g.id == root_id
        push!(nodes, g)
        return nodes
    end
end

mutable struct ProcessGraph
    process_graph::OrderedSet{ProcessNode}
end

StructTypes.StructType(::Type{ProcessGraph}) = StructTypes.CustomStruct()
function StructTypes.lower(g::ProcessGraph)
    res = Dict()
    for s in g.process_graph
        res[s.id] = s
    end
    return Dict(:process_graph => res)
end
Base.getindex(g::ProcessGraph, i...) = g.process_graph[i...]

function Base.show(io::IO, ::MIME"text/plain", g::ProcessGraph)
    println(io, "openEO ProcessGraph with $(length(g)) steps:")
    for step in g.process_graph
        args = join(values(step.arguments), ", ")
        println(io, "   $(step.process_id)($(args))")
    end
end

function ProcessGraph(process_node::ProcessNode)
    g = deepcopy(process_node)
    g.result = true
    root_id = process_node.id
    processes = flatten!(g, root_id)
    return ProcessGraph(processes)
end

Base.getindex(g::ProcessGraph, i) = Base.getindex(g.process_graph, i)
Base.length(g::ProcessGraph) = Base.length(g.process_graph)

"""
Create a ProcessGraph to reduce dimesnions
"""
function ProcessGraph(process::String="mean")
    p = ProcessNode(process, Dict(:data => Dict(:from_parameter => "data")); result=true)
    return ProcessGraph(OrderedSet([p]))
end

function action(n::Union{Expr,Core.ReturnNode})
    typeof(n) == Core.ReturnNode && return :noop
    try
        # BUG: can not disinglush between array in function argument and new ones inside the function
        n.args[2].args[1].name == :getindex && return :create
    catch
    end
    n.head == :(=) && return :assign
    return :call
end

openeo_processes = Dict(
    :+ => "add",
    :- => "subtract",
    :* => "multiply",
    :/ => "divide"
)

"""
Create a ProcessGraph using a user-defined Function

This is useful e.g. to create reducers to combine values of different bands in a customized way.
"""
function ProcessGraph(func::Function, types::Tuple{DataType}=(Any,))
    lowered = code_lowered(func, types)[1]
    actions = action.(lowered.code)

    idx = 0 # openEO arrays starts with 0
    array_processes = Dict()
    for (step, action) in zip(lowered.code, actions)
        if action == :create
            p = ProcessNode("array_element", Dict(
                :data => Dict(:from_parameter => "data"),
                :index => idx
            ))
            idx += 1
            push!(array_processes, step.args[1].id => p)
        end
    end

    processes = Vector{ProcessNode}()
    for (step, action) in zip(lowered.code, actions)
        if action == :create
            push!(processes, array_processes[step.args[1].id])
        elseif action == :call
            process_id = openeo_processes[step.args[1].name]
            arguments = Dict(
                :x => array_processes[step.args[2].id],
                :y => array_processes[step.args[3].id]
            )
            process = ProcessNode(process_id, arguments)
            push!(processes, process)
        elseif action == :assign
            step = step.args[2].args
            process_id = openeo_processes[step[1].name]
            arguments = Dict(
                :x => processes[step[2].id],
                :y => processes[step[3].id]
            )
            process = ProcessNode(process_id, arguments)
            push!(processes, process)
        end
    end
    processes |> last |> ProcessGraph
end

"""
Process and download data synchronously
"""
function compute_result(connection::AuthorizedConnection, process_graph::ProcessGraph, filepath::String="", kw...)
    query = Dict(
        :process => process_graph
    )

    headers = [
        "Accept" => "*",
        "Content-Type" => "application/json"
    ]

    response = fetchApi(connection, "result"; method="POST", headers=headers, body=JSON3.write(query))
    response isa Exception ? throw(response) : true

    if isempty(filepath)
        file_extension = split(Dict(response.headers)["Content-Type"], "/")[2]
        filepath = "out." * file_extension
    end
    open(filepath, "w") do f
        write(f, response.body)
    end
    return filepath
end

function compute_result(connection::AuthorizedConnection, process_node::ProcessNode, kw...)
    process_graph = ProcessGraph(process_node)
    return compute_result(connection, process_graph, kw...)
end
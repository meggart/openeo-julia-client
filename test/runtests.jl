using OpenEOClient
using Test

host = ENV["OPENEO_HOST"]
version = ENV["OPENEO_VERSION"]
username = ENV["OPENEO_USERNAME"]
password = ENV["OPENEO_PASSWORD"]

@testset "OpenEOClient.jl" begin
    unauth_con = OpenEOClient.UnAuthorizedConnection(host, version)
    response = OpenEOClient.fetchApi(unauth_con, "/")
    @test "api_version" in keys(response)
    @test "backend_version" in keys(response)

    c1 = connect(host, version)
    c2 = connect(host, version, username, password)
    @test allequal([c1, c2] .|> x -> size(x.collections))
    @test allequal([c1, c2] .|> x -> names(x, all=true) |> length)

    step1 = c1.load_collection(
        "COPERNICUS/S2", (16.06, 48.06, 16.65, 48.35),
        ["2020-01-20", "2020-01-30"], ["B10"]
    )
    @test step1.id == "load_collection"
    @test Set(keys(step1.parameters)) == Set([:bands, :id, :spatial_extent, :temporal_extent])
    @test step1.parameters[:bands] == ["B10"]
end

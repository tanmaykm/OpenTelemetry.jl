module OpenTelemetryExporterPrometheus

export PrometheusExporter

using OpenTelemetrySDK
using HTTP
using Sockets

mutable struct PrometheusExporter <: AbstractExporter
    server::Sockets.TCPServer
    provider::Union{MeterProvider,Nothing}
    taskref::Ref{Task}
    function PrometheusExporter(; host = "127.0.0.1", port = 9966, kw...)
        server = Sockets.listen(Sockets.InetAddr(parse(IPAddr, host), port))
        exporter = new(server, nothing, Ref{Task}())
        exporter.taskref[] = @async HTTP.listen(host, port; server = server, kw...) do http
            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Type" => "text/plain")

            if isnothing(exporter.provider)
                write(http, "MeterProvider is not set yet!!!")
            else
                for ins in exporter.provider.async_instruments
                    ins()
                end
                text_based_format(http, exporter.provider)
            end
            return
        end
        exporter
    end
end

function (r::MetricReader{<:MeterProvider,<:PrometheusExporter})()
    if isnothing(r.exporter.provider)
        r.exporter.provider = r.provider
    else
        @info "The prometheus exporter is already properly set!"
    end
end

# TODO: support exemplars
function text_based_format(io, provider::MeterProvider)
    for m in values(provider.metrics)
        write(io, "# HELP $(m.name) $(m.description)\n")
        write(io, "# TYPE $(m.name) $(prometheus_type(m.aggregation))\n")
        for (attrs, point) in m
            if point.value isa OpenTelemetrySDK.HistogramValue
                val = point.value
                for (i, c) in enumerate(Iterators.accumulate(+, val.counts))
                    if i == length(val.counts)
                        write(io, "$(m.name)_bucket{le=\"+Inf\"} $c\n")
                        write(io, "$(m.name)_count $c\n")
                    else
                        write(io, "$(m.name)_bucket{le=\"$(point.boundaries[i])\"} $c\n")
                    end
                end
                # ???
                if !isnothing(point.sum)
                    write(io, "$(m.name)_sum $(point.sum)\n")
                end
            else
                write(io, "$(m.name){")
                # TODO: escape
                join(io, ("$k=\"$v\"" for (k, v) in pairs(attrs)), ",")
                write(io, "} $(point.value) $(point.time_unix_nano ÷ 10^6) \n")
            end
        end
        write(io, "\n")
    end
end

prometheus_type(::SumAgg) = "counter"
prometheus_type(::LastValueAgg) = "gauge"
prometheus_type(::HistogramAgg) = "histogram"

end # module

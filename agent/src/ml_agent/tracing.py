"""OpenTelemetry auto-instrumentation setup for Layer 3 runtime traces."""

import os


def setup_tracing():
    """
    Initialize OpenTelemetry auto-instrumentation if OTEL_ENABLED=true.

    Exports spans to OTLP endpoint (Jaeger/Tempo) and auto-instruments:
    - httpx (agent-to-agent calls)
    - Starlette (inbound A2A requests)

    Trace context (traceparent) is automatically propagated by instrumentation.
    """
    if os.getenv("OTEL_ENABLED", "false").lower() != "true":
        return

    from opentelemetry import trace
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
    from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
    from opentelemetry.instrumentation.starlette import StarletteInstrumentor

    # Create resource with service identity
    resource = Resource.create({
        "service.name": os.getenv("AGENT_NAME", "ml-agent"),
        "service.namespace": os.getenv("NAMESPACE", "agentic-ml"),
        "service.instance.id": os.getenv("HOSTNAME", "unknown"),
    })

    # Set up trace provider
    provider = TracerProvider(resource=resource)

    # Configure OTLP exporter (to Jaeger or Tempo)
    otlp_endpoint = os.getenv(
        "OTEL_EXPORTER_OTLP_ENDPOINT",
        "http://jaeger.observability.svc.cluster.local:4317"
    )
    otlp_exporter = OTLPSpanExporter(
        endpoint=otlp_endpoint,
        insecure=True,  # gRPC without TLS for in-cluster communication
    )

    # Batch processor for async export
    provider.add_span_processor(BatchSpanProcessor(otlp_exporter))
    trace.set_tracer_provider(provider)

    # Auto-instrument libraries
    HTTPXClientInstrumentor().instrument()
    StarletteInstrumentor().instrument()

    print(f"[tracing] OTel enabled: exporting to {otlp_endpoint}", flush=True)
    print(f"[tracing] Service: {resource.attributes.get('service.name')}", flush=True)

import os

import uvicorn
from a2a.server.request_handlers.default_request_handler import LegacyRequestHandler
from a2a.server.routes import create_rest_routes
from a2a.server.tasks.inmemory_task_store import InMemoryTaskStore
from a2a.types import AgentCapabilities, AgentCard, AgentSkill
from google.protobuf.json_format import MessageToDict
from starlette.applications import Starlette
from starlette.responses import JSONResponse
from starlette.routing import Route

from ml_agent.executor import MLAgentExecutor

AGENT_NAME = os.environ.get("AGENT_NAME", "ml-agent")
AGENT_DESCRIPTION = os.environ.get("AGENT_DESCRIPTION", f"ML Pipeline {AGENT_NAME}")
AGENT_SKILLS = os.environ.get("AGENT_SKILLS", "")
HOST = os.environ.get("HOST", "0.0.0.0")
PORT = int(os.environ.get("PORT", "8000"))


def build_agent_card() -> AgentCard:
    skills_raw = [s.strip() for s in AGENT_SKILLS.split(",") if s.strip()]
    skills = [
        AgentSkill(
            id=s.replace("-", "_"),
            name=s.replace("-", " ").title(),
            description=f"{AGENT_NAME} skill: {s}",
            tags=[s],
            examples=[f"Run {s}"],
        )
        for s in skills_raw
    ] or [
        AgentSkill(
            id=AGENT_NAME.replace("-", "_"),
            name=AGENT_NAME.replace("-", " ").title(),
            description=AGENT_DESCRIPTION,
            tags=["ml-pipeline"],
            examples=[f"Run {AGENT_NAME}"],
        )
    ]

    return AgentCard(
        name=AGENT_NAME,
        description=AGENT_DESCRIPTION,
        version="1.0.0",
        default_input_modes=["text"],
        default_output_modes=["text"],
        capabilities=AgentCapabilities(streaming=False),
        skills=skills,
    )


def main():
    card = build_agent_card()
    card_dict = MessageToDict(card, preserving_proto_field_name=True)
    executor = MLAgentExecutor()
    handler = LegacyRequestHandler(
        agent_executor=executor,
        task_store=InMemoryTaskStore(),
        agent_card=card,
    )

    async def agent_card_endpoint(request):
        return JSONResponse(card_dict)

    routes = [
        Route("/.well-known/agent-card.json", agent_card_endpoint),
        *create_rest_routes(request_handler=handler),
    ]
    app = Starlette(routes=routes)

    print(f"[{AGENT_NAME}] A2A agent on {HOST}:{PORT}", flush=True)
    print(f"[{AGENT_NAME}] skills: {AGENT_SKILLS or 'default'}", flush=True)

    uvicorn.run(app, host=HOST, port=PORT)


if __name__ == "__main__":
    main()

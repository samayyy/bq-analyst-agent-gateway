"""Smoke test against the DEPLOYED agent on Agent Engine.

Usage:
    PROJECT_ID=my-project LOCATION=asia-south1 \
        python scripts/remote_smoke_test.py <AGENT_ENGINE_ID> ["question..."]
"""

import asyncio
import os
import sys

import vertexai

PROJECT_ID = os.environ.get("PROJECT_ID", "wohlig")
LOCATION = os.environ.get("LOCATION", "asia-south1")

DEFAULT_QUESTION = (
    "Which datasets exist in this project? Pick one of them and tell me "
    "how many tables it has."
)


async def main() -> None:
    if len(sys.argv) < 2:
        sys.exit("Usage: python scripts/remote_smoke_test.py <AGENT_ENGINE_ID> [question]")
    engine_id = sys.argv[1]
    question = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_QUESTION

    client = vertexai.Client(project=PROJECT_ID, location=LOCATION)
    app = client.agent_engines.get(
        name=f"projects/{PROJECT_ID}/locations/{LOCATION}/reasoningEngines/{engine_id}"
    )

    session = await app.async_create_session(user_id="remote_smoke_tester")
    session_id = session["id"] if isinstance(session, dict) else session.id
    print(f"session: {session_id}\nUSER: {question}\n")

    async for event in app.async_stream_query(
        user_id="remote_smoke_tester",
        session_id=session_id,
        message=question,
    ):
        content = event.get("content") if isinstance(event, dict) else None
        if not content:
            continue
        for part in content.get("parts", []):
            if "function_call" in part:
                fc = part["function_call"]
                print(f"  -> tool call: {fc.get('name')}({fc.get('args')})")
            elif "function_response" in part:
                print(f"  <- tool result: {str(part['function_response'])[:200]}")
            elif part.get("text"):
                print(f"\nAGENT: {part['text']}")


if __name__ == "__main__":
    asyncio.run(main())

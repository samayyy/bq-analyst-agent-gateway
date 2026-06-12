"""Local end-to-end smoke test: drives the agent in-process with InMemoryRunner.

Uses your local ADC for both the Gemini call (Vertex global endpoint) and the
managed BigQuery MCP server. Run from the repo root:

    python scripts/local_smoke_test.py
"""

import asyncio
import sys
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parents[1] / "bq_analyst" / ".env")

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from google.genai import types  # noqa: E402

from bq_analyst.agent import root_agent  # noqa: E402

from google.adk.runners import InMemoryRunner  # noqa: E402

QUESTIONS = [
    "Which datasets exist in this project, and where does each live?",
    "Pick any one table you can find, describe its schema, and show me a "
    "small aggregated insight from it (not a raw dump).",
]


async def main() -> None:
    runner = InMemoryRunner(agent=root_agent, app_name="bq_analyst_smoke")
    session = await runner.session_service.create_session(
        app_name="bq_analyst_smoke", user_id="smoke_tester"
    )

    for question in QUESTIONS:
        print(f"\n{'=' * 80}\nUSER: {question}\n{'=' * 80}")
        async for event in runner.run_async(
            user_id="smoke_tester",
            session_id=session.id,
            new_message=types.Content(role="user", parts=[types.Part(text=question)]),
        ):
            if not event.content or not event.content.parts:
                continue
            for part in event.content.parts:
                if part.function_call:
                    print(f"  -> tool call: {part.function_call.name}"
                          f"({dict(part.function_call.args or {})})")
                elif part.function_response:
                    preview = str(part.function_response.response)[:300]
                    print(f"  <- tool result: {preview}")
                elif part.text:
                    print(f"\nAGENT: {part.text}")

    await runner.close()


if __name__ == "__main__":
    asyncio.run(main())

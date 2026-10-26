from __future__ import annotations

import json
from typing import Any, Callable

from backend.artifacts.filesystem import ArtifactRun
from backend.pipelines.authorship import add_author_credit
from backend.pipelines.common import (
    PipelineError,
    PipelineResult,
    extract_fenced_or_raw,
    format_citations,
    format_log,
)
from backend.pipelines.html_to_pdf import (
    A4_PAGE,
    ConvertError,
    HtmlToPdfConverter,
)
from backend.providers.base import (
    ModelProviderError,
    TextGenerationProvider,
    TextGenerationRequest,
)
from backend.timing import RunTimingRecorder, measure_stage


def run_essay_html_pipeline(
    *,
    artifact_run: ArtifactRun,
    model_profile: dict[str, Any],
    model_provider: TextGenerationProvider,
    pdf_converter: HtmlToPdfConverter,
    task_text: str,
    context_bundle: str,
    output_preference: str | None,
    options: dict[str, Any] | None,
    search: dict[str, Any],
    max_output_tokens: int,
    emit_event: Callable[[str, str], None] | None = None,
    timing: RunTimingRecorder | None = None,
) -> PipelineResult:
    log_lines = [
        "Pipeline: essay_html",
        f"Output preference: {output_preference or 'pdf'}",
        "Stage: generate_source",
    ]
    system_prompt, user_prompt = build_essay_html_prompt(
        task_text=task_text,
        context_bundle=context_bundle,
        options=options or {},
        search=search,
    )
    if emit_event:
        emit_event("generate_source", "Generating essay HTML source")

    try:
        with measure_stage(timing, "provider_generation"):
            raw_output = model_provider.generate_text(
                TextGenerationRequest(
                    profile=model_profile,
                    system_prompt=system_prompt,
                    user_prompt=user_prompt,
                    max_output_tokens=max_output_tokens,
                    temperature=0.2,
                )
            )
    except ModelProviderError as exc:
        raise PipelineError(
            exc.code,
            exc.message,
            stage="generate_source",
            log_lines=log_lines,
        ) from exc
    except Exception as exc:
        raise PipelineError(
            "provider_unavailable",
            "The model provider request failed.",
            stage="generate_source",
            log_lines=log_lines,
        ) from exc

    source = extract_fenced_or_raw(raw_output, accepted_languages={"html", "htm"})
    source = add_author_credit(source.strip()) + "\n"
    html_path = artifact_run.write_output(
        "main.html",
        source,
        kind="source",
        media_type="text/html",
    )
    log_lines.extend(["Output: output/main.html", "Stage: convert_pdf"])
    if emit_event:
        emit_event("convert_pdf", "Converting essay HTML to PDF")

    pdf_path = artifact_run.run_dir / "output" / "main.pdf"
    try:
        with measure_stage(timing, "convert_pdf"):
            convert_result = pdf_converter.convert(
                html_path=html_path,
                pdf_path=pdf_path,
                page_config=A4_PAGE,
            )
    except ConvertError as exc:
        artifact_run.write_log("convert.log", exc.log_text)
        raise PipelineError(
            "convert_failed",
            exc.message,
            stage="convert_pdf",
            log_lines=log_lines,
        ) from exc
    except Exception as exc:
        artifact_run.write_log(
            "convert.log",
            "HTML-to-PDF converter raised an unexpected error.\n",
        )
        raise PipelineError(
            "convert_failed",
            "HTML-to-PDF conversion failed.",
            stage="convert_pdf",
            log_lines=log_lines,
        ) from exc

    artifact_run.write_log("convert.log", convert_result.log_text)
    artifact_run.write_output(
        "main.pdf",
        convert_result.pdf_path.read_bytes(),
        kind="pdf",
        media_type="application/pdf",
    )
    log_lines.extend(["Convert: pdf_ok", "Output: output/main.pdf"])
    return PipelineResult(log_text=format_log(log_lines))


def build_essay_html_prompt(
    *,
    task_text: str,
    context_bundle: str,
    options: dict[str, Any],
    search: dict[str, Any],
) -> tuple[str, str]:
    system_prompt = (
        "You are a senior cloud engineer and technical writer producing a formal "
        "individual assignment report for a course titled \"From AI Agent to Cloud "
        "Service\". The report documents how a supplied AI Learning Assistant "
        "(FastAPI + browser UI + SQLite + Qwen-compatible API + Docker Compose) was "
        "deployed locally, pushed to Alibaba Cloud Container Registry (ACR), run on "
        "an Elastic Compute Service (ECS) instance, and published over HTTPS behind "
        "an Nginx reverse proxy with an access-control layer. Write in a clear, "
        "first-person academic style. Every technical claim must be specific: give "
        "actual commands, ports, image tags, file paths, and endpoints rather than "
        "generic descriptions. Explain WHY each step is needed, not only WHAT was "
        "typed. Return only the complete self-contained HTML document, with no "
        "surrounding explanation or Markdown fences."
    )
    output_instruction = (
        "Return one complete self-contained HTML document that starts with "
        "<!doctype html> and includes <html>, <head>, and <body>. Put all CSS "
        "inside a <style> element: use a clean, professional A4 print layout with "
        "a readable serif body, a sans-serif for headings, a clear numbered "
        "heading hierarchy, running page numbers via CSS counters, and "
        "@page { size: A4; margin: 20mm; }. The total report must fit within "
        "20 printed pages, so keep prose focused and avoid filler. "
        "Do not use external stylesheet links, remote images, or remote HTTP(S) "
        "assets. Use inline SVG or styled HTML/CSS boxes for architecture "
        "diagrams and flow charts; do not fetch any library from a CDN at render "
        "time. If a real screenshot cannot be embedded, insert a clearly labelled "
        "figure placeholder box that names the evidence (e.g. \"Figure 2: local "
        "workbench at 127.0.0.1:14242/ui/\"), and always describe what the "
        "screenshot demonstrates in a caption and surrounding text.\n\n"
        "Organise the report with the following sections, each as a numbered "
        "heading:\n"
        "1. Title page — course code BA3073, assignment title, student name, ID, "
        "date, and a one-paragraph abstract.\n"
        "2. Introduction and objectives — what the supplied application does, the "
        "three tasks, and the learning outcomes.\n"
        "3. System architecture — an inline SVG/text diagram of the full "
        "local-to-cloud pipeline, with the roles of Docker, ACR, ECS, Nginx, "
        "Certbot, and the Qwen API, and how data is persisted in mounted volumes.\n"
        "4. Task 1: local deployment — the exact compose commands, the health "
        "check, the local UI test, secrets management (model-secrets.env), and "
        "the local-ui-check evidence; include the figure placeholder for the "
        "local workbench screenshot.\n"
        "5. Task 2: ECS deployment via ACR — server preparation, the image "
        "build/tag/push/pull sequence, the docker-compose run on port 14242, "
        "security-group restriction to the student's own public IP, and the "
        "public-IP web test; include the figure placeholder for the ECS UI "
        "screenshot and describe the ecs-docker-check output.\n"
        "6. Task 3: domain and HTTPS — DNS A record, ports 80/443, the Nginx "
        "reverse-proxy configuration to 127.0.0.1:14242, the Certbot/Let's "
        "Encrypt certificate, the separate Basic Auth access-control layer, "
        "removal of the 14242 public rule, and the HTTPS evidence figure.\n"
        "7. Security analysis — transport encryption, defence in depth, "
        "least-privilege firewall rules, secret handling, and the limitations of "
        "the BNBU login and Basic Auth.\n"
        "8. Cost analysis — a table of estimated domain, ECS, ACR, and "
        "certificate costs, and how to stop or release resources after the "
        "assignment.\n"
        "9. Reflection and improvements — what went well, what was difficult, "
        "and concrete improvements (region choice, localhost-only port "
        "binding, automation scripts, stronger identity-aware proxy).\n"
        "10. References — any provided web sources listed in ordinary HTML, "
        "using the supplied citations.\n"
        "Keep code blocks short and correctly escaped; use tables for "
        "configuration, costs, and evidence lists."
    )
    user_prompt = "\n\n".join(
        [
            "[Assignment Task]\n" + task_text.strip(),
            "[Prepared Context]\n" + context_bundle.strip(),
            "[Search Citations]\n" + format_citations(search),
            "[Options]\n" + json.dumps(options, sort_keys=True),
            "[Output Contract]\n" + output_instruction,
        ]
    )
    return system_prompt, user_prompt

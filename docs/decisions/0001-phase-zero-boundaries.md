# ADR 0001: Phase 0 boundaries and replaceable adapters

Status: Accepted foundation decision. Date: 2026-11-09.

## Context

Three developers need independent starting points without waiting for a complete
AI pipeline. A mock that looks production-ready would hide missing durability and
authorization and could cause unsafe deployment.

## Decision

Use the specified Flutter/Kotlin, Next.js/TypeScript/Tailwind/shadcn, FastAPI/Pydantic,
Python worker, Supabase, PostgreSQL jobs and FCM architecture. Canonical OpenAPI and
synthetic fixtures let clients develop independently. Fixture mode is explicit and
disposable; real-mode adapters fail closed until implemented. Keep production
integrations, deployments and native behavior outside Phase 0.

## Consequences

Contract/mock tests demonstrate behavior but cannot establish production durability,
JWT security, DB concurrency, OS behavior, or push delivery. STATUS records those
limits. No Redis, Celery, vector database, custom training, or iOS is introduced.

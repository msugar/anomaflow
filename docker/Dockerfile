FROM python:3.12-slim-bookworm

WORKDIR /pipeline

# uv
COPY --from=ghcr.io/astral-sh/uv:0.7.8 /uv /uvx /bin/

# Set the entrypoint to Apache Beam SDK worker launcher
COPY --from=apache/beam_python3.12_sdk:2.65.0 /opt/apache/beam /opt/apache/beam
ENTRYPOINT [ "/opt/apache/beam/boot" ]

# Install the requirements
COPY pyproject.toml .
RUN uv sync

# Copy the source files
COPY anomaflow/ ./anomaflow/
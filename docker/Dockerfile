FROM python:3.12-slim-bookworm

WORKDIR /pipeline

# Set the entrypoint to Apache Beam SDK worker launcher.
COPY --from=apache/beam_python3.12_sdk:2.65.0 /opt/apache/beam /opt/apache/beam
ENTRYPOINT [ "/opt/apache/beam/boot" ]

# Install the requirements.
COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r requirements.txt \
    && pip check

# Copy the pipeline source files.
COPY . ./

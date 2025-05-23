# Use the official Apache Beam Python SDK base image
FROM apache/beam_python3.12_sdk:2.64.0

# Copy the pipeline code
COPY python/ /app/
WORKDIR /app

# Install dependencies using pip (you can use uv or pip here)
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir . \
    && pip check

# Set the entrypoint to your pipeline script (optional for interactive testing)
ENTRYPOINT ["python", "/app/anomaflow/pipeline.py"]
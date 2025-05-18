## Setup

1. [Set up ADC for a local development environment](https://cloud.google.com/docs/authentication/set-up-adc-local-dev-environment)
    ```bash
    # After installing the Google Cloud CLI, initialize it by running the following command:
    gcloud init
    # If you're using a local shell, then create local authentication credentials for your user account:
    gcloud auth application-default login
    ```

1. Make sure to run your commands from the `python` directory inside the project:
    ```bash
    cd python
    ```

1. If not done yet, create a virtual environment and install the dependencies declared in `pyproject.toml`
    ```bash
    uv venv --python 3.12
    uv sync
    ```

1. Activate the virtual environment
    source .venv/bin/activate  # On Linux/macOS/WSL
    # OR
    .venv\Scripts\activate     # On Windows
    ```

1. Install pip inside your uv environment.
    This is required to avoid errors when submitting the Apache Beam job to Dataflow
    ```bash
    uv pip install pip
    ```

## Run
Make sure you're in the `python` subdirectory and your virtual environment is activated, then:
```bash
python -m anomaflow.pipeline
```

## Run Tests
Make sure you're in the `python` subdirectory and your virtual environment is activated, then:
```bash
pytest
```
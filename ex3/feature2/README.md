# Archive Processing Demo

This archive demonstrates the system's ability to process compressed packages containing Dockerfile and related materials.

## Contents
- `Dockerfile` - Container definition
- `hello.py` - Python application
- `requirements.txt` - Dependencies
- `README.md` - This file

## Usage
1. Extract the archive
2. Build Docker image: `docker build -t demo .`
3. Run container: `docker run --rm demo`

This shows the system can extract archives and execute Dockerfiles with their dependencies.
